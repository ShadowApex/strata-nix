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
  repo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF";
  rev = "5348543e0147355ac9cbcb031184a3546350988e"; # 2026-09-29
  size = "Coder_IQ1_M";
  shard1 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf";
  shard1Sha = "e11083ba855e7666b48ea3f2db6a9c3a20c18751a012cc24f948de91b7087fad";
  shard2 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf";
  shard2Sha = "316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113";
  path = "IQ1_M/";
  packArgs = "";
  minEngine = "0.1.46";
  ram = "32";
  download = "58.4";
  memoryNote = "half the experts, for a 32 GB PC; weaker outside code";
  modelName = "qwen3.8-flash-next-coder-iq1_m";
  packName = "coder-iq1m";
  expertProfile = "expert-profile-coder.bin";

  hfShard =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/${repo}/resolve/${rev}/${path}${name}";
      inherit sha256;
    };
  s1 = hfShard shard1 shard1Sha;
  ple = if shard2 == null then s1 else hfShard shard2 shard2Sha;
  pleName = if shard2 == null then shard1 else shard2;

  mmprojName = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
  mmproj = fetchurl {
    url = "https://huggingface.co/${repo}/resolve/${rev}/${mmprojName}";
    sha256 = "b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0";
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
        expertProfile
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
