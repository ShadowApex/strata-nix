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
  repo = "ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
  rev = "99bb8f7f95c7aa7b24a36a7786a4f657b30f5d3d"; # 2026-10-07
  size = "Swift_IQ2_XS";
  shard1 = "Swift-Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf";
  shard1Sha = "ca3b302d3d1eb6eddce3ea4acc79854e6cc5fdc0583e374a6a8b6bb67327743b";
  shard2 = "Swift-Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf";
  shard2Sha = "e4996a6de18fd49c58d9a0040fcfd73787db6407c51973f29884bee7b14c9dbb";
  path = "";
  packArgs = "";
  minEngine = "0.1.46";
  ram = "48";
  download = "68.0";
  memoryNote = "its experts want ~48 GB of RAM";
  modelName = "swift-1.5-iq2_xs";
  packName = "swift-iq2xs";

  hfShard =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/${repo}/resolve/${rev}/${path}${name}";
      inherit sha256;
    };
  s1 = hfShard shard1 shard1Sha;
  s2 = hfShard shard2 shard2Sha;
  # Swift's shard 1 holds the PLE table; shard 2 holds the later layers.
  ple = s1;
  pleName = shard1;

  mmprojName = "mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf";
  mmproj = fetchurl {
    url = "https://huggingface.co/${repo}/resolve/${rev}/${mmprojName}";
    sha256 = "cd1140f4abba943ce8d9fa92fed8407e389954d26907efde7b72153c75bd8a60";
  };

  toolsPython = python3.withPackages (p: [
    p.numpy
    p.regex
    p.pyyaml
    p.requests
  ]);

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
        path = s2;
      }
    ]
  );
  mmprojDir = linkFarm "strata-mmproj" [
    {
      name = mmprojName;
      path = mmproj;
    }
  ];

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
      description = "The Strata ${size} model: its pinned GGUF shards (~${download} GB), the pack cut from them with its derived tokenizer, and the Swift image encoder";
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
