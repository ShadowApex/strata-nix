# Strata: the inference engine (HIP) and its Python server, with the IQ2_XS model, its derived
# tokenizer and the MTP draft layer, every download a pinned fetchurl - one self-contained store path.
#
# This is the package definition; the flake callPackages it (flake.nix). The source is fetched here,
# not passed in: the only thing a package.nix cannot know on its own comes from a flake input:
#   hipArchs the HIP target list (input strata-config, default nix/config.json)
# Everything else - the source pin, the build, the config the server reads - lives here.

{
  lib,
  stdenv,
  cmake,
  ninja,
  fetchurl,
  fetchFromGitHub,
  linkFarm,
  runCommand,
  writeTextFile,
  stdenvNoCC,
  rocmPackages,
  python3,
  hipArchs,
}:
let
  rocm = rocmPackages;

  version = "0.1.37";   # setup.py's MIN_ENGINE: the engine this package builds
  archList = lib.splitString ";" hipArchs;

  # The source, fetched from GitHub at the tag matching this package's version. The hash is the
  # unpacked archive's, so a version bump (or a change to the tag) means re-pinning it - the first
  # build reports the mismatch, or: nix-prefetch-url --unpack <archive url>.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-0so8fFampbUIvWmYQPKr3MzHH0lB6kCtluxWe/erves=";
  };

  # The tagged v0.1.37 hip_backend.cmake only accepts gfx1100/gfx1101/gfx1200/gfx1201 (unvalidated:
  # gfx1102;gfx1030); the support for gfx1151 (Radeon 8060S) and gfx1150 (Radeon 890M) this package's
  # default config.json targets landed upstream after the tag. This repository therefore carries the
  # patched file (cmake/hip_backend.cmake - identical to the tag's apart from adding those two archs to
  # _strata_hip_unvalidated) and the source is the fetchFromGitHub archive with that one file replaced;
  # the hash pin on the tag keeps the rest of the source. When the patch is upstreamed, remove the
  # overlay and re-pin the fetchFromGitHub hash.
  strataPatched = runCommand "strata-src-with-hip-patch" {} ''
    # $src is a read-only store path, so copy writable, swap the one file in, and move the result
    cp -a ${src} $out.tmp
    find $out.tmp -type d -exec chmod u+w {} +
    rm $out.tmp/cmake/hip_backend.cmake
    cp ${../../../../cmake/hip_backend.cmake} $out.tmp/cmake/hip_backend.cmake
    mv $out.tmp $out
  '';

  # llama.cpp pinned at the commit CMakeLists.txt's FetchContent default uses (setup.py's
  # LLAMA_CPP_COMMIT and third_party/ggml/VERSION.txt record the same id). -DSTRATA_GGML_DIR points
  # CMake at the unpacked store path, so the sandbox needs no network at configure time. Its
  # gguf-py/ (the Python GGUF reader) is what the build-time tools below import through STRATA_GGUF_PY.
  # The repo's own module (nix/llama.cpp.nix); it would have to move into the package if this package
  # were upstreamed to nixpkgs.
  llamaCpp = import ../../../../nix/llama.cpp.nix { inherit fetchurl stdenvNoCC; };

  # The server's non-stdlib imports (serve/ and tools/strata_tokenizer.py): jinja2 (chat templates),
  # regex (the tokenizer), psutil (RAM telemetry), pillow (the image formats the engine's decoder
  # cannot read). No web framework - serve/server.py is the stdlib http.server.
  python = python3.withPackages (p: [ p.jinja2 p.regex p.psutil p.pillow ]);

  # Python for the build-time tools (tools/iq_pack.py, tools/strata_tokenizer.py, tools/mtp_pack.py,
  # tools/mtp_rt.py): numpy + the regex module, and the two third-party imports llama.cpp's gguf-py
  # (above) pulls in (pyyaml, requests); gguf-py itself is found through STRATA_GGUF_PY.
  toolsPython = python3.withPackages (p: [ p.numpy p.regex p.pyyaml p.requests ]);

  # ---- the IQ2_XS model: the package's payload -------------------------------------------
  # Two GGUF shards from Hugging Face, pinned to the repository's revision of 2026-10-02 (the current
  # `sha` of the repository; tools/mtp_fetch.py pins the same kind of revision for the checkpoint).
  #   shard 1 (36.6 GB): the model - dense tensors and the 35.5 GB of quantized experts. The engine
  #                      mmap's it (--native); the low-RAM resident mode reads its experts through
  #                      pack's experts.bin, which tools/iq_pack.py cuts from it at build time.
  #   shard 2 (26.8 GB): the per-layer token-embedding table alone (one tensor); it stays on disk,
  #                      read by the engine as needed (--ple-gguf).
  # The tokenizer is not a file in that repository: tools/strata_tokenizer.py derives it from shard 1's
  # GGUF metadata (vocab, merges, chat template) into pack/tokenizer/ at build time.
  hfRev = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
  s1 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf";
  s2 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf";
  iq2xs = name: sha256: fetchurl {
    url = "https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/${hfRev}/IQ2_XS/${name}";
    inherit sha256;
  };
  iq2xsS1 = iq2xs s1 "92cee27ae5bbadcd732416a0f7a7f0acc092399dbbe8f5a5efa707c2ec0a49d7";
  iq2xsS2 = iq2xs s2 "316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113";

  # ---- the MTP draft layer's source: 28 shards of the original BF16 checkpoint -----------------
  # The GGUF above ships no MTP head; the checkpoint (Qwen/Qwen3.8-Flash-Next, 360 GB in 131 shards)
  # does: 31 `mtp.*` tensors (~5 GB) scattered over 28 of the shards. Those 28 shards (55.17 GB) and
  # the checkpoint's index file are fetched as store paths, pinned to the repository's revision of
  # 2026-09-30 (the current `sha`) by their LFS sha256; the build then extracts only the MTP byte
  # ranges from the local files (mtpLocal, below) and checks every tensor against the SHA256 table
  # tools/mtp_fetch.py pins for that revision (#327) - the original range-fetching implementation,
  # whose table stays the single source of truth for the pins. No network in the build.
  qwenRev = "de4b8e4d43b917e7706784d8bb445c9af86a3540";
  qwen = name: sha256: fetchurl {
    url = "https://huggingface.co/Qwen/Qwen3.8-Flash-Next/resolve/${qwenRev}/${name}";
    inherit sha256;
  };
  qwenIndex = qwen "model.safetensors.index.json"
    "99e815241ef03325536b0aaa4441deea45174c17fae31e10f0bb456410c590de";
  mtpShards = [ (qwen "model-00037-of-00131.safetensors" "73b53c94d23589bdfde55b20538a515525f22fd37c7cdf24e85738ed771218e1")
    (qwen "model-00041-of-00131.safetensors" "0465251c296b1a6aa014480e54f0f23ce6899bca72ba2be4804cd9187095cc7c")
    (qwen "model-00043-of-00131.safetensors" "a88f0411382143c6eb5ddeed84280a80f18f18d94670bda54cee1c1cd47cd824")
    (qwen "model-00047-of-00131.safetensors" "eb79852b4266e63fc7050e79349ece1eb3160eedb13bdb5f39b4c768e0741a4f")
    (qwen "model-00049-of-00131.safetensors" "cbab68ff417bf8905ccfa1697deb5c6b42ae9ee9bf6cbb0ebe687e116e5e6da8")
    (qwen "model-00053-of-00131.safetensors" "1bf2bbe69b64fc9ac33c264490445a0b42a3488c6b87722d918c3d3abe6bbeab")
    (qwen "model-00057-of-00131.safetensors" "77ec2297055779ab6dc6e15e3a88837b888e13ce199543f12a40a5036e5b8a4a")
    (qwen "model-00060-of-00131.safetensors" "8fd21925cb11bc7cf68d7c5cab498f3c13f455aed32e8c5ac90cda92c6961487")
    (qwen "model-00062-of-00131.safetensors" "e62ba3c6e2e9e213b6aa0534498bb341e89b86ce388347a8421ccff0d5887f0a")
    (qwen "model-00066-of-00131.safetensors" "550a89f69aa7d57e58f344ac06e7ea0ef471813eb16a6adb95373339df895f6c")
    (qwen "model-00070-of-00131.safetensors" "9644884762cc198d27a2a4d1078702fa4744ad8ff272afc565568fc8e04c6f59")
    (qwen "model-00072-of-00131.safetensors" "2415f75c86da428daf68924f98f1bb159b0a589a9571f0d690f8a27ce4839689")
    (qwen "model-00076-of-00131.safetensors" "14860603fb56ceaf4748a819ca0e561c685ad1e2182d91cc32170a8b1cddcb9e")
    (qwen "model-00078-of-00131.safetensors" "e9ac55c3032056303f9f8cce6b0f486e0bfedad2258a384eff6531e973cd7220")
    (qwen "model-00082-of-00131.safetensors" "0fe8d836b886ac8942f74e835e17487f53454e96bf38263d45fb329006dde7a9")
    (qwen "model-00086-of-00131.safetensors" "757b82b98441356169d5030ac338d3a7d55fadc332c3f4c396fba795ac64d810")
    (qwen "model-00088-of-00131.safetensors" "2feec63478c327f8436222d0df2b1f1cdd65947704cc5bab0ae891122ed3656f")
    (qwen "model-00090-of-00131.safetensors" "af53d439e4e26865b7cfda192ef46a29762f3c49b1fe8e06b54adee132b80880")
    (qwen "model-00094-of-00131.safetensors" "c31221b8e6a5df3151c85e24fd1c8e0693af21fed7814d2804de032e8566e4b3")
    (qwen "model-00100-of-00131.safetensors" "78da7091e9a36803c4ccd1c10fa6dc0f61b65ad7e70c314722c0582a94c619f2")
    (qwen "model-00102-of-00131.safetensors" "6caf691248517c088adb462caef16a7c5bbcdad796ceb2fee4c3cb575a86e8e1")
    (qwen "model-00106-of-00131.safetensors" "2903f5b2c539142163c7157fd191d8799019dbfe3a5ab2560276546b9b0fa44e")
    (qwen "model-00108-of-00131.safetensors" "426251e0773e900de9a227db60fd8c05ee7f25b8d514458b7a8b37028f6d90ac")
    (qwen "model-00112-of-00131.safetensors" "90d2e46457dd629a0ebab7d3f4c36de7a0613518fcd3ba6e6a0143d9c24ae04f")
    (qwen "model-00114-of-00131.safetensors" "b8d004974b91dad16757c9ad6be6682756e17843c7026e441f2a075de33ab4f5")
    (qwen "model-00118-of-00131.safetensors" "ffe5cc04b3c2bdfeaba652267ecce7f9ded512646840effe6dd1908f65a299b4")
    (qwen "model-00120-of-00131.safetensors" "6a13f7374f7998ce5413fd1a94a2796f10a389ac4ba0da073e80fa91eca1b40e")
    (qwen "model-00124-of-00131.safetensors" "bf22358402faf83962759e05b13480151b138d03203d30f04524f8d53e498c7c")
  ];

  # stdenv `source`s every bare file in buildInputs (its "setup hook" mechanism), so the model and
  # MTP payloads enter the build as linkFarm directories of symlinks instead (directories are never
  # sourced). The interpolation into linkFarm's script is what makes the 123 GB of store paths
  # dependencies of this derivation, and the build sandbox resolves the links through to them.
  mtpData = linkFarm "mtp-data" (
    [ { name = "model.safetensors.index.json"; path = qwenIndex; } ]
    ++ lib.map (s: { name = s.name; path = s; }) mtpShards
  );
  modelData = linkFarm "iq2xs-model" [
    { name = s1; path = iq2xsS1; }
    { name = s2; path = iq2xsS2; }
  ];

  # The build-time extractor: the same layout tools/mtp_fetch.py fetch writes (tensors/<name>.bin
  # plus mtp-manifest.json), read from the local pinned shards instead of HTTP ranges, so
  # tools/mtp_pack.py and tools/mtp_rt.py run unchanged. Stdlib only.
  mtpLocal = writeTextFile {
    name = "mtp-local-extract";
    text = ''
      import hashlib, json, os, struct, sys
      index_path, out, shard_paths, tools_dir = sys.argv[1:5]
      sys.path.insert(0, tools_dir)
      import mtp_fetch                                   # for its pinned SHA256 table (#327)
      weight_map = json.load(open(index_path, encoding="utf-8"))["weight_map"]
      want = {k: v for k, v in weight_map.items() if k.startswith("mtp.")}
      by_name = {os.path.basename(p): p for p in shard_paths.split()}
      os.makedirs(os.path.join(out, "tensors"), exist_ok=True)
      manifest = []
      for name in sorted(want):
          shard = want[name]
          path = by_name.get(shard)
          if path is None:
              sys.exit("tensor %s: its shard %s is not among the pinned fetchurl inputs" % (name, shard))
          f = open(path, "rb")
          n = struct.unpack("<Q", f.read(8))[0]
          meta = json.loads(f.read(n))[name]
          a, b = meta["data_offsets"]
          f.seek(8 + n + a)
          data = f.read(b - a)
          f.close()
          digest = hashlib.sha256(data).hexdigest()
          want_hash = mtp_fetch.SHA256.get(name)
          if want_hash is not None and digest != want_hash:
              sys.exit("%s: sha256 %s is not the pinned %s" % (name, digest, want_hash))
          rel = "tensors/%s.bin" % name
          with open(os.path.join(out, rel), "wb") as o:
              o.write(data)
          manifest.append(dict(name=name, shard=shard, dtype=meta["dtype"], shape=meta["shape"],
                               start=8 + n + a, end=8 + n + b - 1, bytes=b - a,
                               file=rel, sha256=digest))
          print(name, b - a, flush=True)
      with open(os.path.join(out, "mtp-manifest.json"), "w", encoding="utf-8") as o:
          json.dump(manifest, o, indent=1)
      print("%d MTP tensors, %.3f GB" % (len(manifest), sum(r["bytes"] for r in manifest) / 1e9))
      '';
  };

  # nixpkgs has no single /opt/rocm prefix: each package is its own store path, and CMake's
  # find_package(... CONFIG) finds the configs against them through CMAKE_PREFIX_PATH. What each is for:
  #   clr         the hipcc driver + hip-lang/hip CMake configs (enable_language(HIP), hip::host, libamdhip64)
  #   hipblas     roc::hipblas (the dense matrix path)
  #   hipblaslt   roc::hipblaslt (the optional fast prefill GEMMs; its GPU kernels cover nixpkgs' full
  #               target list, which includes every supported gfx* above)
  #   rocm-core   hsa-runtime64 / hsakmt, the HSA runtime the engine loads at start
  #   rocm-comgr  libamdcomgr (LLVM bitcode compilation at load time)
  #   rocm-runtime the remaining runtime libraries
  #   hip-common  the HIP headers hipcc includes
  rocmLibs = [
    rocm.clr rocm.hipblas rocm.hipblaslt rocm.rocm-core
    rocm.rocm-comgr rocm.rocm-runtime rocm.hip-common
  ];

  # the engine loads libamdhip64 / hsa-runtime64 / the hipBLAS libraries at run time; stdenv patches
  # their store paths into the binaries' RPATH, so nothing ROCm lives outside this package's closure
  cmakeFlags = builtins.concatStringsSep " " [
    "-DSTRATA_ENABLE_HIP=ON"
    "-DSTRATA_ENABLE_CUDA=OFF"
    "-DSTRATA_BUILD_TESTS=OFF"
    "-DSTRATA_NATIVE_EXPERTS=ON"
    # this machine is not the target PC: ggml-cpu at the AVX2 baseline instead of host-native
    # (CMakeLists.txt's STRATA_PORTABLE); the AVX-512 expert kernels keep their runtime CPU dispatch
    "-DSTRATA_PORTABLE=ON"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_PREFIX_PATH=${lib.makeSearchPath ":" rocmLibs}"
    # the HIP driver (ROCm clang with the ROCm environment wired up) for the .cu sources
    # cmake/hip_backend.cmake relabels to the HIP language
    "-DCMAKE_HIP_COMPILER=${rocm.clr}/bin/amdclang++"
    # the target list from the flake input; shell-quoted because the ";" list separator is a bash command
    # separator in buildPhase
    "-DCMAKE_HIP_ARCHITECTURES='${hipArchs}'"
    # llama.cpp from the store instead of a FetchContent network fetch
    "-DSTRATA_GGML_DIR=${llamaCpp}"
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "strata";
  inherit version;
  src = strataPatched;   # the GitHub fetch with the post-tag gfx1151/gfx1150 HIP patch applied

  nativeBuildInputs = [ cmake ninja ];
  # stdenv skips its default configure (it would run cmake with no flags and hit the network
  # FetchContent): everything happens in buildPhase
  configurePhase = "true";
  dontFixupPhase = false;
  # the engine loads libamdhip64 / hsa-runtime64 / the hipBLAS libraries at run time; stdenv patches
  # their store paths into the binaries' RPATH, so nothing ROCm lives outside this package's closure
  propagatedBuildInputs = rocmLibs ++ [ python ];

  # ---- the payloads, as linkFarm directories (see mtpData / modelData, above): the IQ2_XS model
  # (67 GB), plus the MTP draft layer's source, the checkpoint index + the 28 shards holding its
  # 31 mtp.* tensors (55.17 GB; buildPhase extracts only the ~5 GB of MTP byte ranges, mtpLocal)
  buildInputs = [ mtpData modelData ];

  env.HIP_PLATFORM = "amd";
  env.ROCM_PATH = rocm.clr;
  # llama.cpp's gguf-py (tools/_paths.py finds it through this variable)
  env.STRATA_GGUF_PY = "${llamaCpp}/gguf-py";

  buildPhase = ''
    cmake -S $src -B build -G Ninja ${cmakeFlags}
    ninja -C build strata strata-device

    # ---- the IQ2_XS pack. tools/iq_pack.py reads every shard beside --gguf (the shards keep their
    # original names), derives the tokenizer from the GGUF metadata (tools/strata_tokenizer.py:
    # vocab, merges, the chat template into pack/tokenizer/), and writes:
    #   index.txt / dense.bin      the dense tensors as the GGUF stores them (engine: --native)
    #   native_experts.txt         one line per layer: where each expert blob lives (written last:
    #                              a pack without it is not finished)
    #   experts.bin                all 35.5 GB of quantized experts in one file: what
    #                              --resident-experts (and --mmap-experts) read at run time
    mkdir -p $out/models/IQ2_XS
    cp ${modelData}/* $out/models/IQ2_XS/
    ${toolsPython}/bin/python3 $src/tools/iq_pack.py \
      --gguf "$out/models/IQ2_XS/${s1}" --out $out/pack/iq2xs --experts-bin

    # ---- the MTP draft layer (speculative decoding; strata --serve needs it): the ~5 GB of MTP
    # tensors out of the 28 pinned checkpoint shards (mtpData, above), every tensor checked
    # against tools/mtp_fetch.py's pinned SHA256 table, then packed Q2_0, relaid out for the engine
    mkdir -p $TMPDIR/mtp
    ${toolsPython}/bin/python3 ${mtpLocal} \
      ${mtpData}/model.safetensors.index.json $TMPDIR/mtp \
      "$(ls ${mtpData}/model-00*.safetensors)" $src/tools
    ${toolsPython}/bin/python3 $src/tools/mtp_pack.py --src $TMPDIR/mtp --experts q2_0 \
      --out $TMPDIR/mtp/mtp-q2_0.gguf
    ${toolsPython}/bin/python3 $src/tools/mtp_rt.py --gguf $TMPDIR/mtp/mtp-q2_0.gguf --out $out/mtp/rt

    # ---- the data files the config points at
    mkdir -p $out/data
    cp $src/data/draft_vocab.bin $out/mtp/rt/draft_vocab.bin
    cp $src/data/expert-profile.bin $out/data/
  '';

  installPhase = ''
    mkdir -p $out/bin $out/etc/strata
    # the server runs from the stored tree: serve/server.py's ROOT is the directory holding serve/
    cp -a $src/serve $src/tools $src/chat.py $src/requirements.txt $out/
    for exe in strata strata-device; do
      install -m 755 build/$exe $out/bin/$exe
    done
    # the config shape setup.py writes (exe, args, cwd, tokenizer, model_name), filled for this
    # machine: 32 GB of RAM + 32 GB of VRAM (gfx1151) runs IQ2_XS in the low-RAM resident mode -
    # the experts the GPU does not hold live in RAM, the 26.8 GB PLE table stays on disk. The KV
    # cache is int8 at the full 131072-token context.
    cat > $out/etc/strata/strata.json <<'EOF'
    {
      "exe": "@OUT@/bin/strata",
      "args": [
        "--pack", "@OUT@/pack/iq2xs",
        "--native", "@OUT@/models/IQ2_XS/@S1@",
        "--ple-gguf", "@OUT@/models/IQ2_XS/@S2@",
        "--expert-profile", "@OUT@/data/expert-profile.bin",
        "--expert-cache", "auto",
        "--prefill", "auto",
        "--spec", "4",
        "--spec-min-p", "0.5",
        "--mtp", "@OUT@/mtp/rt",
        "--max-context", "131072",
        "--kv", "int8",
        "--resident-experts"
      ],
      "cwd": "@OUT@",
      "tokenizer": "@OUT@/pack/iq2xs/tokenizer",
      "model_name": "qwen3.8-flash-next-iq2_xs",
      "backend": "hip",
      "env": { "STRATA_RESIDENT_PIN": "0" }
    }
    EOF
    sed -i -e "s|@OUT@|$out|" -e "s|@S1@|${s1}|" -e "s|@S2@|${s2}|" $out/etc/strata/strata.json
    # the metadata setup.py's installer records and the server reads from beside the engine
    cat > $out/bin/BUILD.json <<'EOF'
    {
      "version": "${version}",
      "backend": "hip",
      "archs": [${lib.concatStringsSep ", " (map (a: "\"${a}\"") archList)}]
    }
    EOF
    # strata-server: the Python server over the stored engine
    cat > $out/bin/strata-server <<'EOF'
    #!/bin/sh
    export STRATA_ROOT="@OUT@"
    export PYTHONNOUSERSITE=1
    cd "$STRATA_ROOT"
    exec "@PY@/bin/python3" -m serve.server --engine strata --config "$STRATA_ROOT/etc/strata/strata.json" "$@"
    EOF
    sed -i -e "s|@OUT@|$out|" -e "s|@PY@|${python}|" $out/bin/strata-server
    chmod +x $out/bin/strata-server
  '';

  meta = with lib; {
    description = "The Strata inference engine (HIP for ${hipArchs}) and its Python server, with the IQ2_XS model (~67 GB), its derived tokenizer and the MTP draft layer (28 pinned checkpoint shards, ~55 GB): one self-contained store path to serve";
    homepage = "https://github.com/Niko1221/Strata";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    # `nix run .#strata -- --help`: the engine's own --help, which prints the usage without a GPU
    mainProgram = "strata";
  };
})
