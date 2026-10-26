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
  repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
  rev = "5bc3e238d916f48a861bac2f8a1990a0e9b7e98d"; # 2026-10-12
  size = "Qwen36_UD_Q6_K_XL";
  gguf = "Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf";
  ggufSha = "35fce994cd36104a7dc1bd8a4bdf13778145664c00fdef6773aebc9246e5019c";
  minEngine = "0.1.46";
  ram = "44";
  download = "32.6";
  memoryNote = "the engine keeps a copy of every expert in RAM when they do not all fit in VRAM; ~44 GB total";
  modelName = "qwen3.6-35b-a3b-ud-q6_k_xl";
  packName = "qwen36-ud-q6kxl";
  arch = "qwen35moe";

  shards = linkFarm "strata-shards-${size}" [
    {
      name = gguf;
      path = fetchurl {
        url = "https://huggingface.co/${repo}/resolve/${rev}/${gguf}";
        sha256 = ggufSha;
      };
    }
  ];

  mmprojName = "mmproj-F16.gguf";
  mmproj = fetchurl {
    url = "https://huggingface.co/${repo}/resolve/${rev}/${mmprojName}";
    sha256 = "71f3cbc1f7cc0f30d09d41cfa924c0060827ebc33bf15ace7e86661e856f0160";
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
        ${toolsPython}/bin/python3 ${strataTools}/tools/strata_tokenizer.py \
          --gguf ${shards}/${gguf} --out $out
      '';
in
runCommand "strata-model-${size}"
  {
    meta = {
      description = "The Strata ${size} model: its pinned GGUF, the tokenizer derived from it, and the Qwen3.6 image encoder";
      homepage = "https://huggingface.co/${repo}";
      license = lib.licenses.asl20;
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
      family = "qwen36";
      inherit arch;
      ownPath = true;
      mtpCount = 2;
      shard1 = gguf;
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
