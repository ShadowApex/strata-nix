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
  size = "Unsloth_UD_Q6_K_XL";
  subdir = "UD-Q6_K_XL";
  modelName = "qwen3.8-flash-next-unsloth-ud-q6_k_xl";
  packName = "unsloth-ud-q6kxl";
  minEngine = "0.1.44";
  ram = "118";
  download = "169.2";
  memoryNote = "its experts want ~118 GB of RAM in total; below that, part is read from the SSD";

  shardFiles = [
    {
      name = "Qwen3.8-Flash-Next-UD-Q6_K_XL-00001-of-00006.gguf";
      sha256 = "8bdc6bad55b6699f46f60708829932ff4018d7ac9bd309c388534fa31753bdb7";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q6_K_XL-00002-of-00006.gguf";
      sha256 = "494ca4ed3dbf97bc28da88af3890b8877b9032f909812d00c0526a9ca5e91d2e";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q6_K_XL-00003-of-00006.gguf";
      sha256 = "34efd79a80a1ce540a517a5d56171924b66ce1c38b04c904f17ad6d8ef17cf20";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q6_K_XL-00004-of-00006.gguf";
      sha256 = "0ea4b599880a5a52fcd9c188ba1443f646c69c96571904ddbd6a79246a01a997";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q6_K_XL-00005-of-00006.gguf";
      sha256 = "9948e81ae8368144b135a7403d8c0f2cf9a6c2f9f692313865855b2832e696c9";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q6_K_XL-00006-of-00006.gguf";
      sha256 = "e4ae255234f42b18012f6d6eec5bf615b57479b7e0a0233c47436a321ffeec3f";
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
