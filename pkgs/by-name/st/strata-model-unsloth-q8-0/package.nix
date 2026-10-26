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
  repo = "unsloth/Qwen3.8-Flash-Next-GGUF";
  rev = "38bb39ee97821de2c9009abb7e93950eec396e66"; # 2026-09-30
  size = "Unsloth_Q8_0";
  subdir = "Q8_0";
  modelName = "qwen3.8-flash-next-unsloth-q8_0";
  packName = "unsloth-q80";
  minEngine = "0.1.38";
  ram = "136";
  download = "188.2";
  memoryNote = "its experts want ~136 GB of RAM in total; below that, part is read from the SSD";

  shardFiles = [
    {
      name = "Qwen3.8-Flash-Next-Q8_0-00001-of-00006.gguf";
      sha256 = "2dabcbb53ca537a7947bc7d20414fd464eeaf4d66d43021b5b2556cc87544ad2";
    }
    {
      name = "Qwen3.8-Flash-Next-Q8_0-00002-of-00006.gguf";
      sha256 = "494ca4ed3dbf97bc28da88af3890b8877b9032f909812d00c0526a9ca5e91d2e";
    }
    {
      name = "Qwen3.8-Flash-Next-Q8_0-00003-of-00006.gguf";
      sha256 = "34efd79a80a1ce540a517a5d56171924b66ce1c38b04c904f17ad6d8ef17cf20";
    }
    {
      name = "Qwen3.8-Flash-Next-Q8_0-00004-of-00006.gguf";
      sha256 = "bfa634025fabbd2658bf7694bc80b90e571699c768723f844c934c7ef06c691a";
    }
    {
      name = "Qwen3.8-Flash-Next-Q8_0-00005-of-00006.gguf";
      sha256 = "232a8f14cc0fa4262e7efe8593774b136fe40909e39c7a020342ddaa27259a97";
    }
    {
      name = "Qwen3.8-Flash-Next-Q8_0-00006-of-00006.gguf";
      sha256 = "538a93bca918064983409a41187ad4c68640f9aced6f29564da8f551bf86d7a5";
    }
  ];
  shard1 = (builtins.head shardFiles).name;
  packArgs = "--compat-bf16";

  hfShard =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/${repo}/resolve/${rev}/${subdir}/${name}";
      inherit sha256;
    };
  shards = linkFarm "strata-shards-${size}" (
    map (s: {
      name = s.name;
      path = hfShard s.name s.sha256;
    }) shardFiles
  );

  mmprojName = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
  mmproj = fetchurl {
    url = "https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/ed59f92082b1e93c0e96d60a8b11aab089b52f09/${mmprojName}";
    sha256 = "b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0";
  };
  mmprojDir = linkFarm "strata-mmproj" [
    {
      name = mmprojName;
      path = mmproj;
    }
  ];

  toolsPython = python3.withPackages (p: [
    p.numpy
    p.regex
    p.pyyaml
    p.requests
  ]);

  pack =
    runCommand "strata-pack-${packName}"
      {
        nativeBuildInputs = [ toolsPython ];
        buildInputs = [ shards ];
        env.STRATA_GGUF_PY = "${strataLlamaCpp}/gguf-py";
        env.PYTHONDONTWRITEBYTECODE = "1";
      }
      ''
        ${toolsPython}/bin/python3 ${strataTools}/tools/iq_pack.py \
          --gguf ${shards}/${shard1} --out $out --experts-bin ${packArgs}
      '';
in
runCommand "strata-model-${size}"
  {
    meta = {
      description = "The Strata ${size} model: its pinned GGUF shards (~${download} GB), the pack cut from them with its derived tokenizer, and the Flash-Next image encoder";
      homepage = "https://huggingface.co/${repo}";
      license = lib.licenses.unfreeRedistributable;
      platforms = [ "x86_64-linux" ];
    };
    passthru.strata = {
      key = size;
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
      ple = null;
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
