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
  size = "Unsloth_UD_Q4_K_XL";
  subdir = "UD-Q4_K_XL";
  modelName = "qwen3.8-flash-next-unsloth-ud-q4_k_xl";
  packName = "unsloth-ud-q4kxl";
  minEngine = "0.1.46";
  ram = "48";
  download = "111.3";
  memoryNote = "its experts want ~94 GB of RAM in total; below that, part is read from the SSD";

  shardFiles = [
    {
      name = "Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf";
      sha256 = "4448186216b3af4cc558bbce2c3213f01608f8f8b2e5267a9767971dd3ec8082";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf";
      sha256 = "3f342f1c1580473f1ee94ddd5b28206e8c07a70fa1a366f59d1d6c922919a6c9";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf";
      sha256 = "56758f40269cad5cd9b0d3d6fbae0f40f6d5be6de49e4ab392dbe83157d9cbd3";
    }
    {
      name = "Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf";
      sha256 = "753bda48b98ba4f1636134a90a967de1b2d3908a236c026e464777342e53510a";
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
