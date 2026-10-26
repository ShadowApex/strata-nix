# Strata's Gyro-S model: its pinned GGUF shards, the pack cut from shard 1 with the tokenizer derived from
# its metadata, and the image encoder the Flash-Next line shares.
#
# One by-name package per size, so a size is a package: services.strata.model takes one, and switching size
# costs the engine, the image readers and the MTP draft layer nothing. It reads nothing from the engine
# package - the pack runs the pinned tools tree (strata-tools), so a Strata release that leaves
# tools/iq_pack.py alone costs this package nothing.
#
# The output is three links, so the payload stays in its own store paths and the assembly can point at each:
#   shards/   the GGUF files under their published names (the engine mmaps shard 1, reads the n-gram table
#             from the same file, and llama.cpp resolves a split GGUF by the names beside it)
#   pack/     tools/iq_pack.py's output: index.txt, dense.bin, native_experts.txt, experts.bin, tokenizer/
#   mmproj/   the image encoder the family shares
#
# What the assembly needs is in passthru.strata: the size, the pack name, the published file names, the
# model_name the API reports, the memory the size wants, and the first engine version that can read this
# pack. The assembly refuses an engine older than that.

{
  lib,
  runCommand,
  linkFarm,
  fetchurl,
  python3,
  strataTools,
  strataLlamaCpp,
}:
let
  # The Hugging Face repository and the revision setup.py's HF_REVISIONS names for this family (the current
  # `sha`), the same pin as the image encoder below.
  repo = "agentionai/Qwen3.8-Flash-Next-Gyro-GGUF";
  rev = "1ada08422e404aca51ab9df665f089f34c419c6b"; # 2026-10-13
  size = "Gyro-S";
  # One GGUF that carries the n-gram table inside it, hence the smaller memory for a similar download. Its
  # experts are Hadamard-folded, so its pack is marked v5 beside a hadamard.txt, which an engine that cannot
  # rotate them refuses. The sha256 is the file's LFS oid.
  shard1 = "Qwen3.8-Flash-Next-Gyro-S-TQ1_0.gguf";
  shard1Sha = "c6ea1b08ca312f99095b27588ba35976b53f948268e7f91e7761926aa01d9c87";
  # the file sits at the repository root, and it is also the n-gram table the engine reads (--ple-gguf)
  shard2 = null;
  shard2Sha = null;
  path = "";
  # its small projections are quantized too, so its pack is marked v5 with BF16-compatible dense tensors,
  # which is what setup.py passes for the family
  packArgs = "--compat-bf16";
  # the first engine version setup.py accepts for the trellis quants (its GYRO_ENGINE)
  minEngine = "0.1.45.1";
  # setup.py's MODELS: the memory this size wants (GPU and system RAM together, per setup.py's MODELS) and the download in GB
  ram = "27.6";
  download = "58.5";
  memoryNote = "its experts and n-gram table together want ~27.6 GB of GPU plus system RAM";
  # the model_name the API reports, and the pack directory's name: the size lowercased without underscores
  # (gyro-s), so each size caches its own pack
  modelName = "qwen3.8-flash-next-gyro-gyro-s";
  packName = "gyro-s";

  hfShard =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/${repo}/resolve/${rev}/${path}${name}";
      inherit sha256;
    };
  s1 = hfShard shard1 shard1Sha;
  # the file the engine reads the n-gram table from: shard 2 for the split files, the one file for a Gyro file
  ple = if shard2 == null then s1 else hfShard shard2 shard2Sha;
  pleName = if shard2 == null then shard1 else shard2;

  # The image encoder (vision tower + projector, 0.9 GB) the whole Flash-Next line shares: setup.py's
  # FAMILIES names this file for both families, and strata-vision reads it with llama.cpp's mtmd while the
  # engine places the rows it produces at the prompt's image pad tokens.
  mmprojName = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
  mmproj = fetchurl {
    url = "https://huggingface.co/${repo}/resolve/${rev}/${mmprojName}";
    sha256 = "b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0";
  };

  # Python for the pack: numpy + the regex module, and the two third-party imports llama.cpp's gguf-py pulls
  # in (pyyaml, requests); gguf-py itself is found through STRATA_GGUF_PY.
  toolsPython = python3.withPackages (p: [
    p.numpy
    p.regex
    p.pyyaml
    p.requests
  ]);

  # stdenv `source`s every bare file in buildInputs (its "setup hook" mechanism), so the shards enter as a
  # linkFarm directory, never as bare paths. The interpolation into linkFarm's script is what makes them
  # dependencies of this derivation; the build sandbox resolves the links through to them.
  shards = linkFarm "strata-shards-${size}" (
    [
      {
        name = shard1;
        path = s1;
      }
    ]
    ++ lib.optionals (shard2 != null) [
      {
        name = shard2;
        path = ple;
      }
    ]
  );
  mmprojDir = linkFarm "strata-mmproj" [
    {
      name = mmprojName;
      path = mmproj;
    }
  ];

  # The pack: the pinned shards and the pinned tools, nothing else. The tools run from a read-only store
  # path, so they must not leave a __pycache__ there. gguf-py comes from the pinned llama.cpp, which is also
  # what the engine builds ggml from.
  pack =
    runCommand "strata-pack-${packName}"
      {
        nativeBuildInputs = [ toolsPython ];
        buildInputs = [ shards ];
        env.STRATA_GGUF_PY = "${strataLlamaCpp}/gguf-py";
        env.PYTHONDONTWRITEBYTECODE = "1";
      }
      ''
        # tools/iq_pack.py reads every shard beside --gguf (the shards keep their published names), derives
        # the tokenizer from the GGUF metadata (tools/strata_tokenizer.py: vocab, merges, the chat template
        # into tokenizer/), and writes index.txt / dense.bin / native_experts.txt / experts.bin (the quantized
        # experts the low-RAM resident mode reads at run time).
        ${toolsPython}/bin/python3 ${strataTools}/tools/iq_pack.py \
          --gguf ${shards}/${shard1} --out $out --experts-bin ${packArgs}
      '';
in
runCommand "strata-model-${size}"
  {
    meta = {
      description = "The Strata ${size} model: its pinned GGUF shards (~${download} GB), the pack cut from them with its derived tokenizer, and the Flash-Next image encoder";
      homepage = "https://huggingface.co/${repo}";
      # the base model's Qwen Community License, as setup.py records it for the model files
      license = lib.licenses.unfreeRedistributable;
      platforms = [ "x86_64-linux" ];
    };
    # the contract the Strata assembly reads: see the header
    passthru.strata = {
      key = "Gyro_S";
      inherit
        size
        packName
        modelName
        minEngine
        ram
        download
        memoryNote
        ;
      shard1 = shard1;
      ple = pleName;
      inherit mmprojName mmprojDir;
      inherit shards pack;
    };
  }
  ''
    mkdir -p $out
    ln -s ${pack} $out/pack
    ln -s ${shards} $out/shards
    ln -s ${mmprojDir} $out/mmproj
  ''
