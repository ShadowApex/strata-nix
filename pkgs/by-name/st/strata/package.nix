# Strata: the HIP inference engines, their Python server and the image encoders, assembled over a model
# package and an MTP draft-layer package. One derivation per stage so the expensive ones cache on their own,
# and the model and the draft layer are separate packages passed in: an engine release never re-runs the
# model packing, and a model change rebuilds nothing compiled.
#
# One build carries both engines - `strata` for the Flash-Next line (original, Swift, Coder, Unsloth, Gyro)
# and Qwen3.6, `strata-dsv41` for DeepSeek-V4.1-Flash - and the model package's family decides which one the
# config starts.
#
#   pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = pkgs.strata-model-qwen-iq3-s; mtp = pkgs.strata-mtp; prefillMmq = false; }
#
# hipArchs and prefillMmq reach the compiled stages, model and mtp the config and the closure. Pass
# mtp = null for a family that drafts from its own pack.

{
  lib,
  stdenv,
  stdenvNoCC,
  runCommand,
  cmake,
  ninja,
  fetchurl,
  fetchFromGitHub,
  rocmPackages,
  python3,
  hipArchs ? [
    "gfx1100"
    "gfx1151"
    "gfx1201"
  ],
  model,
  mtp ? null,
  prefillMmq ? true,
}:
let
  rocm = rocmPackages;

  # The repository tag. The engine's own version is a separate number, read out of CMakeLists.txt below and
  # carried in BUILD.json, because that is what the server compares against a model's minimum.
  version = "0.2.4.2";

  # A ";"-joined string is accepted too, the form CMake and the source's scripts take. The list is validated
  # by the source's own cmake/hip_backend.cmake: an arch it does not name - gfx1151, the default here,
  # included - builds with a warning.
  archList = if builtins.typeOf hipArchs == "string" then lib.splitString ";" hipArchs else hipArchs;
  archString = lib.concatStringsSep ";" archList;

  # Pinned to the tag matching version. A tag change means re-pinning the unpacked archive's hash: the first
  # build reports the mismatch, or use nix-prefetch-url --unpack <archive url>.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-rjkHoWjzXoJQoJ4ArTodNhCmPG2edYo1QeRpI5O3fGk=";
  };

  # llama.cpp pinned to the commit CMakeLists.txt's FetchContent default names. -DSTRATA_GGML_DIR points
  # CMake at the unpacked store path so the sandbox needs no network at configure time, and its gguf-py/ is
  # what the build-time tools import through STRATA_GGUF_PY.
  llamaCpp = import ./llama.cpp.nix {
    inherit fetchurl stdenvNoCC;
  };

  # What the server imports outside the stdlib: jinja2 (chat templates), regex (the tokenizer), psutil (RAM
  # telemetry), pillow (formats its own decoder cannot read, converted to PNG), jsonschema (request
  # response_format) and truststore (the host CA store for HTTPS fetches). rich and textual are absent on
  # purpose - only the terminal's dashboards import them.
  python = python3.withPackages (p: [
    p.jinja2
    p.regex
    p.psutil
    p.pillow
    p.jsonschema
    p.truststore
  ]);

  # ---- the payload: the model package and the MTP draft layer --------------------------------
  m =
    model.passthru.strata
      or (throw "the model passed to the Strata package must be one of the strata-model-* packages: it carries no passthru.strata, so the assembly cannot name its shards, its pack or its image encoder");

  # Decides the engine binary, the config's shape and its flags. A model package with no `family` is a
  # Flash-Next one; Qwen3.6 has its own engine path inside the same `strata` binary.
  dsv41 = (m.family or "qwen35_ista") == "deepseek41";
  qwen36 = (m.family or "qwen35_ista") == "qwen36";
  modelKey = m.key or m.size;

  # Refused rather than quietly dropped, so a caller who pairs a draft layer with the wrong family finds out.
  mtpLink =
    if mtp == null then
      ""
    else if dsv41 then
      throw "${modelKey} is DeepSeek-V4.1-Flash: it drafts from the DSpark layer its pack already holds, so pass mtp = null to the Strata package"
    else if qwen36 then
      throw "${modelKey} is Qwen3.6-35B-A3B: it drafts from the MTP block inside its GGUF, so pass mtp = null to the Strata package"
    else
      ''
        mkdir -p $out/mtp
        ln -s ${mtp} $out/mtp/rt
      '';

  # Both are the family's numbers as setup.py writes them: it checks DeepSeek-V4.1 at a shorter context, and
  # Qwen3.6's own path starts at 32K because the package cannot see the card's VRAM.
  maxContext =
    if dsv41 then
      8192
    else if qwen36 then
      32768
    else
      131072;
  engineReady = if dsv41 then 3600 else 900;

  # The substitutions below run for every config shape, and a DeepSeek or Qwen3.6 model package carries none
  # of these names, so they have to resolve to empty strings rather than nulls.
  orEmpty = v: if v == null then "" else v;
  shard1 = orEmpty (m.shard1 or null);
  plePath = orEmpty (m.ple or null);
  mmprojName = orEmpty (m.mmprojName or null);
  profileName = m.expertProfile or "expert-profile.bin";

  # The payload links and the staged profile, per family. Nix builds the script text rather than bash testing
  # it: a `${null}` inside a branch bash would skip is still interpolated. The expert profile is copied out
  # rather than left in the pack folder, because $out/pack is a symlink into the read-only model package and
  # the config can only name it with --expert-profile.
  payloadLinks =
    (lib.optionalString ((m.mmprojDir or null) != null) ''
      ln -s ${m.mmprojDir} $out/vision
    '')
    + mtpLink
    + (lib.optionalString (!dsv41 && !qwen36) ''
      mkdir -p $out/data
      cp ${src}/data/${profileName} $out/data/
    '');

  # BUILD.json's picture-reader section: the keys setup.py writes for a HIP engine with a GPU reader, and the
  # server reads vision_archs to decide whether that reader covers the card it found.
  buildJsonVision = lib.optionalString (!dsv41) ''
    "vision": "gpu",
    "vision_archs": [${lib.concatStringsSep ", " (map (a: "\"${a}\"") archList)}],
    "vision_gpu": "strata-vision-hip",
    "vision_cpu": "strata-vision",
  '';

  # nixpkgs has no single /opt/rocm prefix: each package is its own store path, found by CMake's
  # find_package(... CONFIG) through CMAKE_PREFIX_PATH. rocBLAS is absent on purpose: CMakeLists.txt finds it
  # only for the gfx103x solution table and treats "not found" as a status, not an error.
  rocmLibs = [
    rocm.clr
    rocm.hipblas
    rocm.hipblaslt
    rocm.rocm-core
    rocm.rocm-comgr
    rocm.rocm-runtime
    rocm.hip-common
  ];
  # The GPU picture reader is the one stage that cannot do without rocBLAS: it links llama.cpp's ggml-hip,
  # which does find_package(rocblas REQUIRED).
  visionHipLibs = rocmLibs ++ [ rocm.rocblas ];

  # CMakeLists.txt force-includes include/strata/dsv41/hip_extra.h into every strata-dsv41 source, HIP and
  # C++ alike, and that header pulls in hipblas.h - whose own header nixpkgs splits into hipblas-common.
  # Neither arrives through a linked target, so the compiler has to be pointed at both.
  dsv41Includes = lib.concatMapStringsSep " " (p: "-I${p}/include") [
    rocm.hipblas
    rocm.hipblas-common
  ];

  cmakeFlags = builtins.concatStringsSep " " [
    "-DSTRATA_ENABLE_HIP=ON"
    "-DSTRATA_ENABLE_CUDA=OFF"
    "-DSTRATA_BUILD_TESTS=OFF"
    "-DSTRATA_NATIVE_EXPERTS=ON"
    # always on: one build then serves either family, and switching families rebuilds the assembly only
    "-DSTRATA_BUILD_DSV41=ON"
    # off upstream; needs HIP, and compiles the fused prompt-expert kernels
    "-DSTRATA_PREFILL_MMQ=${if prefillMmq then "ON" else "OFF"}"
    # the build machine is not the target PC, so no -march=native baked into the store path
    "-DSTRATA_PORTABLE=ON"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_PREFIX_PATH=${lib.makeSearchPath ":" rocmLibs}"
    # the HIP driver, for the .cu sources hip_backend.cmake relabels to the HIP language
    "-DCMAKE_HIP_COMPILER=${rocm.clr}/bin/amdclang++"
    "-DCMAKE_HIP_FLAGS='${dsv41Includes}'"
    "-DCMAKE_CXX_FLAGS='${dsv41Includes}'"
    # quoted: the ";" list separator is a bash command separator in buildPhase
    "-DCMAKE_HIP_ARCHITECTURES='${archString}'"
    # llama.cpp from the store instead of a FetchContent network fetch
    "-DSTRATA_GGML_DIR=${llamaCpp}"
    # STRATA_PORTABLE decides ggml-cpu's feature flags, and since v0.2.4.2 CMakeLists.txt additionally forces
    # GGML_BMI2 off for the dsv41 targets: Zen 1/2 run the PDEP that ggml's IQ1_S/IQ1_M dots use in microcode,
    # and src/dsv41/ds4_gg_cpu.cpp covers those types with its own rows. Nothing here passes -march/-mcpu:
    # the AVX-512 and AVX2 kernels carry per-file flags and dispatch at runtime.
  ];

  # tools/vision is its own CMake project, and its two readers are separate programs so that a PC where the
  # HIP runtime will not load still has the CPU one to fall back on. MTMD_VIDEO is off: the server sends
  # still images only, so it needs no ffmpeg. CMake refuses STRATA_VISION_CUDA and STRATA_VISION_HIP in one
  # build, which is what keeps the CPU reader non-HIP.
  visionFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DLLAMA_DIR=${llamaCpp}"
    "-DSTRATA_VISION_CUDA=OFF"
    "-DSTRATA_PORTABLE=ON"
    "-DMTMD_VIDEO=OFF"
  ];
  visionCmakeFlags = builtins.concatStringsSep " " visionFlags;
  # the GPU reader: ggml-hip at the pinned commit, for the engine's target list
  visionHipCmakeFlags = builtins.concatStringsSep " " (
    visionFlags
    ++ [
      "-DSTRATA_VISION_HIP=ON"
      "-DSTRATA_VISION_HIP_ARCHS='${archString}'"
      "-DCMAKE_PREFIX_PATH=${lib.makeSearchPath ":" visionHipLibs}"
      "-DCMAKE_HIP_COMPILER=${rocm.clr}/bin/amdclang++"
    ]
  );

  # ---- the engine: what the HIP target list reaches, together with the GPU picture reader ---------
  engine = stdenv.mkDerivation {
    pname = "strata-engine";
    inherit version src;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    # deliberate: stdenv's default configure would run cmake with no flags and hit the network FetchContent,
    # so everything happens in buildPhase
    configurePhase = "true";
    buildPhase = ''
      cmake -S . -B build -G Ninja ${cmakeFlags}
      ninja -C build strata strata-device strata-dsv41
    '';
    installPhase = ''
      mkdir -p $out/bin
      for exe in strata strata-device strata-dsv41; do
        install -m 755 build/$exe $out/bin/$exe
      done
    '';
    # stdenv patches the ROCm store paths into the RPATH here, which is what the engine needs at run time
    propagatedBuildInputs = rocmLibs;
  };

  # ---- the image encoders: built without a HIP target list, so hipArchs does not rebuild them ------
  visionBin = stdenv.mkDerivation {
    pname = "strata-vision-engine";
    inherit version src;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    configurePhase = "true";
    buildPhase = ''
      cmake -S tools/vision -B build-vision -G Ninja ${visionCmakeFlags}
      ninja -C build-vision strata-vision
    '';
    installPhase = ''
      mkdir -p $out/bin
      install -m 755 build-vision/bin/strata-vision $out/bin/strata-vision
    '';
  };

  # The GPU picture reader. Its CMake project forces RUNPATH "$ORIGIN", which stdenv's patching replaces with
  # the store paths of what it links - propagatedBuildInputs is what puts ROCm in that set.
  visionHipBin = stdenv.mkDerivation {
    pname = "strata-vision-hip";
    inherit version src;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    configurePhase = "true";
    buildPhase = ''
      cmake -S tools/vision -B build-vision -G Ninja ${visionHipCmakeFlags}
      # the target is still named strata-vision; only its OUTPUT_NAME becomes strata-vision-hip
      ninja -C build-vision strata-vision
    '';
    installPhase = ''
      mkdir -p $out/bin
      install -m 755 build-vision/bin/strata-vision-hip $out/bin/strata-vision-hip
    '';
    propagatedBuildInputs = visionHipLibs;
  };

  # The config the server reads. The @...@ tokens are substituted with sed below so the store paths inside
  # the file are dependencies of this derivation rather than text.
  dsv41Args = [
    "--pack"
    "@OUT@/pack/@PACK@"
    "--max-context"
    "@MAXCTX@"
    "--eos"
    "1"
    "--dspark"
    "auto"
  ]
  ++ lib.optionals (m.dsparkConf != null) [
    "--dspark-conf"
    m.dsparkConf
  ];
  jsonList =
    items: "[\n        " + lib.concatStringsSep ",\n        " (map (a: "\"${a}\"") items) + "\n      ]";

  configJson =
    if dsv41 then
      # setup.py's install_dsv41: no --native and no --ple-gguf (the pack's own tensor map names every file,
      # including the Engram table that stays on disk), no --vision (this family has no picture reader) and no
      # --mtp (the drafter is packed into the pack, and --dspark auto loads it only when the card can hold it).
      # --dspark-conf is the drafts' confidence floor the official sets are measured with.
      ''
        {
          "exe": "@OUT@/bin/strata-dsv41",
          "args": ${jsonList dsv41Args},
          "cwd": "@OUT@",
          "tokenizer": "@OUT@/pack/@PACK@/tokenizer",
          "model_name": "@MODEL_NAME@",
          "arch": "deepseek41",
          "backend": "hip",
          "engine_ready_s": @READY@
        }
      ''
    else if qwen36 then
      # setup.py's install_own_path for Qwen3.6: the engine reads the GGUF itself, drafts from its own MTP
      # block, and keeps only the tokenizer in the pack folder. No --pack, --expert-profile, --ple-gguf or
      # separate MTP draft layer.
      ''
        {
          "exe": "@OUT@/bin/strata",
          "args": [
            "--native", "@OUT@/models/@MODEL@/@S1@",
            "--max-context", "@MAXCTX@",
            "--prefill", "auto",
            "--mtp", "2",
            "--vision"
          ],
          "cwd": "@OUT@",
          "tokenizer": "@OUT@/pack/@PACK@/tokenizer",
          "model_name": "@MODEL_NAME@",
          "arch": "qwen35moe",
          "backend": "hip",
          "engine_ready_s": @READY@,
          "vision": {
            "exe": "@OUT@/bin/strata-vision-hip",
            "cpu_exe": "@OUT@/bin/strata-vision",
            "mmproj": "@OUT@/vision/@MMPROJ@",
            "model": "@OUT@/models/@MODEL@/@S1@",
            "gpu": true,
            "max_tokens": 1024
          }
        }
      ''
    else
      # setup.py's config shape for the low-RAM resident mode: the experts the GPU does not hold live in RAM,
      # the PLE n-gram table stays on disk, and the KV cache is int8 at the full context.
      # Images need both halves: the "vision" section makes the server spawn the encoder, and "--vision" in
      # args is what makes the engine accept the requests it sends. "exe" is the GPU reader and "cpu_exe" the
      # fallback the server takes over when it cannot start or the card is outside its target list.
      # "model" is shard 1, with the other shards beside it under their published names - how llama.cpp
      # resolves a split GGUF. No "threads": the encoder takes half the cores, and the target PC's core count
      # is unknown here. JSON, so nothing in it may be commented.
      ''
        {
          "exe": "@OUT@/bin/strata",
          "args": [
            "--pack", "@OUT@/pack/@PACK@",
            "--native", "@OUT@/models/@MODEL@/@S1@",
            ${lib.optionalString (m.ple != null) ''
              "--ple-gguf", "@OUT@/models/@MODEL@/@PLE@",
            ''}
            "--expert-profile", "@OUT@/data/@PROFILE@",
            "--expert-cache", "auto",
            "--prefill", "auto",
            "--spec", "4",
            "--spec-min-p", "0.5",
            "--mtp", "@OUT@/mtp/rt",
            "--max-context", "@MAXCTX@",
            "--kv", "int8",
            "--resident-experts",
            "--vision"
          ],
          "cwd": "@OUT@",
          "tokenizer": "@OUT@/pack/@PACK@/tokenizer",
          "model_name": "@MODEL_NAME@",
          "backend": "hip",
          "env": { "STRATA_RESIDENT_PIN": "0" },
          "vision": {
            "exe": "@OUT@/bin/strata-vision-hip",
            "cpu_exe": "@OUT@/bin/strata-vision",
            "mmproj": "@OUT@/vision/@MMPROJ@",
            "model": "@OUT@/models/@MODEL@/@S1@",
            "gpu": true,
            "max_tokens": 1024
          }
        }
      '';
in
runCommand "strata-${modelKey}-${version}"
  {
    meta = with lib; {
      description = "The Strata inference engines (HIP for ${archString}), their Python server and the image encoders, with the ${modelKey} model (~${m.download} GB) and its derived tokenizer${
        if dsv41 then
          ", whose pack holds the DSpark draft layer and the Engram n-gram table on disk"
        else if qwen36 then
          ", whose MTP block and experts are read from the GGUF itself"
        else
          ", the MTP draft layer (28 pinned checkpoint shards, ~55 GB) and the mmproj vision encoder (~0.9 GB)"
      }: the assembly of the stage derivations above and the model and draft-layer packages, whose closure is the whole package";
      homepage = "https://github.com/Niko1221/Strata";
      license = licenses.mit;
      platforms = [ "x86_64-linux" ];
      # `nix run .#strata -- --help` prints the engine's usage without a GPU; which binary that is follows the
      # model's family.
      mainProgram = if dsv41 then "strata-dsv41" else "strata";
    };
    # the compile stages on their own, so a version bump can be checked without the model downloads
    # (nix build .#strata.passthru.engine)
    passthru = {
      engine = engine;
      vision = visionBin;
      visionHip = visionHipBin;
      inherit model mtp;
    };
  }
  ''
    # serve/server.py resolves symlinks for its ROOT (Path(__file__).resolve().parents[1]), so the Python
    # tree it runs from is real content here; only the payloads are links into their own store paths.
    mkdir -p $out/bin $out/etc/strata $out/models $out/pack
    cp -a ${src}/serve ${src}/tools ${src}/chat.py ${src}/requirements.txt $out/
    # serve/ imports these two packages, so they belong to the tree the server runs from
    cp -a ${src}/strata_control ${src}/strata_cli $out/
    ln -s ${model}/shards $out/models/${modelKey}
    ln -s ${model}/pack $out/pack/${m.packName}
    ${payloadLinks}
    ln -s ${engine}/bin/strata $out/bin/strata
    ln -s ${engine}/bin/strata-device $out/bin/strata-device
    ln -s ${engine}/bin/strata-dsv41 $out/bin/strata-dsv41
    # only the families with an mmproj have a picture reader to link: a DeepSeek config names none, and the
    # GPU reader's rocBLAS would ride along in a package that can never start it.
    ${lib.optionalString (!dsv41) ''
      ln -s ${visionBin}/bin/strata-vision $out/bin/strata-vision
      ln -s ${visionHipBin}/bin/strata-vision-hip $out/bin/strata-vision-hip
    ''}

    cat > $out/etc/strata/strata.json <<'EOF'
    ${configJson}
    EOF
    sed -i -e "s|@OUT@|$out|" -e "s|@MODEL@|${modelKey}|" -e "s|@PACK@|${m.packName}|" -e "s|@MODEL_NAME@|${m.modelName}|" -e "s|@S1@|${shard1}|" -e "s|@PLE@|${plePath}|" -e "s|@PROFILE@|${profileName}|" -e "s|@MMPROJ@|${mmprojName}|" -e "s|@MAXCTX@|${toString maxContext}|" -e "s|@READY@|${toString engineReady}|" $out/etc/strata/strata.json
    # "version" is the engine's own number, read out of the source it was built from rather than this
    # package's version, because the two move apart. setup.py compares it against a model's minimum and reads
    # up to four components.
    engineVersion=$(sed -n 's/^[[:space:]]*project(strata VERSION \([0-9.]*\).*/\1/p' ${src}/CMakeLists.txt | head -1)
    # the same check setup.py makes before writing a config: fail the build rather than ship an engine that
    # reads a newer pack as noise.
    if [ "$(printf '%s\n%s\n' "$engineVersion" "${m.minEngine}" | sort -V | head -1)" != "${m.minEngine}" ]; then
      echo "the engine is $engineVersion but the ${modelKey} pack needs at least ${m.minEngine}" >&2
      exit 1
    fi
    cat > $out/bin/BUILD.json <<'EOF'
    {
      "version": "@ENGINE_VERSION@",
      "backend": "hip",
      "archs": [${lib.concatStringsSep ", " (map (a: "\"${a}\"") archList)}],
      "model": "${modelKey}",
      "family": "${m.family or "qwen35_ista"}",
      "engine": "${if dsv41 then "strata-dsv41" else "strata"}",
      ${buildJsonVision}
      "prefill_mmq": ${lib.boolToString prefillMmq}
    }
    EOF
    sed -i "s|@ENGINE_VERSION@|$engineVersion|" $out/bin/BUILD.json
    # A table's solution ids are valid for one architecture family and one hipBLASLt version, so upstream's
    # own staging script reads the version from the headers built against and copies only matching tables.
    # Keep them out of the engine derivation: bin/strata is a symlink, so the engine's search beside the
    # executable it was started as resolves into the engine stage's bin, and tables there would silently turn
    # one on.
    PYTHONDONTWRITEBYTECODE=1 ${python}/bin/python3 ${src}/packaging/stage_tuning.py --stage $out/bin --archs "${archString}" --rocm ${rocm.hipblaslt}
    # The card is only known at start, so the wrapper asks the server's own chooser which shipped table fits.
    # Opt-in: STRATA_HIPBLASLT_TABLE=on, or "hipblaslt_table": true in the config.
    cat > $out/bin/strata-server <<'EOF'
    #!/bin/sh
    export STRATA_ROOT="@OUT@"
    export PYTHONNOUSERSITE=1
    cd "$STRATA_ROOT"
    CONF="$STRATA_ROOT/etc/strata/strata.json"
    prev=
    for a in "$@"; do
      case "$a" in
        --config=*) CONF="''${a#--config=}" ;;
        *) [ "$prev" = "--config" ] && CONF="$a" ;;
      esac
      prev=$a
    done
    export STRATA_CONFIG="$CONF"
    TABLE=$("@PY@/bin/python3" -c 'import json,os,sys; r=os.environ["STRATA_ROOT"]; cfg=json.load(open(os.environ["STRATA_CONFIG"])); sys.path.insert(0,r); from strata_control import hipblaslt_tuning as ht; d=ht.resolve(r+"/bin", ht.present_archs(cfg), cfg=cfg); d.message and print(d.message, file=sys.stderr); print(d.path or "")')
    [ -n "$TABLE" ] && export STRATA_HIPBLASLT_TUNING="$TABLE"
    exec "@PY@/bin/python3" -m serve.server --engine strata --config "$CONF" "$@"
    EOF
    sed -i -e "s|@OUT@|$out|" -e "s|@PY@|${python}|" $out/bin/strata-server
    chmod +x $out/bin/strata-server
  ''
