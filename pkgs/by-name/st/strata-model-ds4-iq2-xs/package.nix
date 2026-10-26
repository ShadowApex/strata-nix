# Strata's DeepSeek-V4.1-Flash IST-DAS 2.25 bpw (IQ2_XS) set: its pinned GGUF files and the pack the engine runs on them.
#
# The third engine path (setup.py's MULTI_FILE_FAMILIES, arch deepseek41, binary strata-dsv41). Its pack is
# not cut from one file: tools/dsv41/pack_gguf.py assembles it from the set's shards - and, for the IST-DAS
# sets, from two files those sets share with every other IST-DAS set - into the folder the engine reads. The
# pack's own tensor map names every file the engine needs, so unlike the Flash-Next families this model is
# given no --native, no --ple-gguf and no --mtp, and it has no image encoder of its own. The n-gram table
# (the Engram) is never copied into the pack: the pack's rows point at the file on disk, which is why the
# table is pinned as its own store path and shared between the sets that need it.
#
# The pack runs this package's own pin (strata-dsv41-tools), not the Flash-Next pack's tree: a file added to
# strata-tools would re-run the Flash-Next line's packing for every size, and nothing in that tree is used here.
#
# The output is two links, so the payload stays in its own store paths and the assembly can point at each:
#   shards/   every file under its published name, the shared ones beside the set's own (pack_gguf.py reads
#             them by path and resolves a split GGUF by the names beside shard 1)
#   pack/     the engine's pack folder itself: ds4.txt (the geometry), tensors.txt (every tensor with the
#             file it lives in), engram.bin (the hash tables) and tokenizer/ - and, for the sets that have
#             one, the hot-expert profile inside it, which the engine finds without a flag
#
# What the assembly needs is in passthru.strata: the size, the pack folder's name, the model_name the API
# reports, the memory the set wants, and the DSpark floor the official recipe measures with.

{
  lib,
  runCommand,
  linkFarm,
  fetchurl,
  python3,
  strataDsv41Tools,
}:
let
  # The two repositories setup.py pins for the family: IST-DAS's own for the 2-bit sets (a flat repository),
  # unsloth's for the 8-bit set and for the two files the 2-bit sets borrow from it.
  istaRepo = "ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF";
  istaRev = "cb02422c900df489cea5833e8a92171224059b3c"; # 2026-10-24 (the final 1.75 / 2.00 / 2.25 bpw sets)
  unslothRepo = "unsloth/DeepSeek-V4.1-Flash-1017-GGUF";
  unslothRev = "f924b94f19c1fea02c06a65c8475b0a45e2b88b1"; # 2026-10-20 (the port's reference)
  size = "DSV41_IQ2_XS";
  label = "IST-DAS 2.25 bpw"; # setup.py's models label for this set
  recipe = "ista"; # setup.py's md.recipe: "ista" or "ud"

  # The set's own files, under the names their repository publishes. The sha256s are the files' LFS oids.
  shards = [
    {
      name = "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00001-of-00004.gguf";
      url = "https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/resolve/cb02422c900df489cea5833e8a92171224059b3c/DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00001-of-00004.gguf";
      sha256 = "4c65307992ab586c527ca1f6f64062aa96a33b23c02b7fed103f45f75e854798";
      gb = 39.5;
    }
    {
      name = "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00002-of-00004.gguf";
      url = "https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/resolve/cb02422c900df489cea5833e8a92171224059b3c/DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00002-of-00004.gguf";
      sha256 = "933461a974fcccee741bf2f9798201e72ab4aa3f8a952be56f849896ca6ea30e";
      gb = 39.5;
    }
    {
      name = "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00003-of-00004.gguf";
      url = "https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/resolve/cb02422c900df489cea5833e8a92171224059b3c/DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00003-of-00004.gguf";
      sha256 = "bbf91fa346a85ebaf32dd4fd5c456b534d780d381e54f46ac90783a481373240";
      gb = 39.4;
    }
    {
      name = "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00004-of-00004.gguf";
      url = "https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/resolve/cb02422c900df489cea5833e8a92171224059b3c/DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XS-00004-of-00004.gguf";
      sha256 = "e5b2f8781fab688cd4bc3bc7a69651b5dbb90ed94965657c6bead8bb4774f3cf";
      gb = 36.8;
    }
  ];

  # The two files an IST-DAS set is packed with, shared by all three, so one store path serves them all:
  # llama.cpp's Engram sidecar (architecture deepseek41-engram) for the n-gram table, and the first shard of
  # unsloth's 8-bit set for the table's hash parameters, which the 2-bit shards name only in
  # deepseek41.engram_* keys - --engram-meta reads that file's metadata and none of its weights. Unsloth's
  # set carries the table in its own shard 8 and the parameters in its own shard 1, so it needs neither.
  # The DSpark drafter (8 GB, architecture dflash) is packed into the IST-DAS packs as mtp.0-2; setup.py
  # fetches it for unsloth's set too but its pack command never names it, so the 8-bit pack has no drafter.
  engramName = "DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf";
  metaName = "DeepSeek-V4.1-Flash-1017-UD-Q8_K_XL-00001-of-00009.gguf";
  dsparkName = "dspark-DeepSeek-V4.1-Flash-1017-Q8_0.gguf";
  ista = recipe == "ista";
  engram = fetchurl {
    url = "https://huggingface.co/${istaRepo}/resolve/${istaRev}/${engramName}";
    sha256 = "eb19f30d368d393784e1fc54fdfaffc427ebb2110bf3762fdf5a8fbb9a2d740a";
  };
  meta = fetchurl {
    url = "https://huggingface.co/${unslothRepo}/resolve/${unslothRev}/UD-Q8_K_XL/${metaName}";
    sha256 = "cc15d470afcb030558bbc4d8e2ccd840182e2e95de1a95198138efe63a5fd99f";
  };
  dspark = fetchurl {
    url = "https://huggingface.co/${unslothRepo}/resolve/${unslothRev}/${dsparkName}";
    sha256 = "6ba6ac1b331c540691a209e7fc97dec2a24e295acb1e755c84c7d24a4373927a";
  };

  # setup.py's models entry for this set: the RAM its experts want (dsv41_fit says what fits - 44 GB to run, 176 GB to keep the CPU's share of the experts in RAM),
  # the download in GB, and what a person has to know about the disk.
  ram = "44";
  download = "274.0";
  memoryNote = "the best quality of the IST-DAS sets (about 7.3% above the original model's perplexity): 155 GB of model files, a 110.6 GB n-gram table and an 8 GB drafter (~274 GB of disk, 17 GB more than 2.00 bpw)";

  # setup.py's pack folder: data/packs/<the family's tag plus the set's name>, lowercased - one folder per
  # set, and the engine's config names it. The derivation carries the set's name too, so the packs cache
  # apart and say which one is building.
  packName = "deepseek-v4.1-flash-ist-das-2.25bpw";
  packFile = "strata-pack-dsv41-iq2-xs";

  # The model_name the API reports is the family's, as setup.py's install_dsv41 writes it.
  modelName = "deepseek-v4.1-flash";
  # the first engine version setup.py accepts for this family
  minEngine = "0.1.49";
  # --dspark-conf, the drafts' confidence floor: setup.py writes 0.65 for the IST-DAS recipe only (the H100
  # replay's best, DSPARK-DEFAULTS.md) and leaves the engine's default alone for unsloth's set. The draft
  # block size is not a flag - the pack records what the drafter's GGUF states.
  dsparkConf = "0.65";
  # Which experts are used most: setup.py copies this profile out of the tools pin into the pack folder,
  # where the engine's RAM store starts from it without a flag. Unsloth's set ships none.
  expertProfile = "profile-2.25.bin";

  # stdenv `source`s every bare file in buildInputs (its "setup hook" mechanism), so the files enter as a
  # linkFarm directory, never as bare paths. The interpolation into linkFarm's script is what makes them
  # dependencies of this derivation; the build sandbox resolves the links through to them.
  shardFarm = linkFarm "strata-dsv41-shards-${size}" (
    (map (f: {
      name = f.name;
      path = fetchurl {
        url = f.url;
        sha256 = f.sha256;
      };
    }) shards)
    ++ lib.optionals ista [
      {
        name = engramName;
        path = engram;
      }
      {
        name = metaName;
        path = meta;
      }
      {
        name = dsparkName;
        path = dspark;
      }
    ]
  );
  shardNames = builtins.concatStringsSep " " (map (f: f.name) shards);
  # setup.py's dsv41_pack_cmd, this and nothing else: it warns that any other recipe for these sets packs
  # without an error and gives garbage text (P2003). The drafter's noise token and markov rank are named
  # because the IST-DAS GGUFs do not state them, and a pack with noise id 0 drafts deep less often (~10%
  # slower decode). Unsloth's set is packed from its folder alone - its shards carry everything.
  packFlags = lib.optionalString ista ''
    --shards ${shardNames} \
    --engram ${engram} --engram-meta ${meta} \
    --dspark-gguf ${dspark} --dspark-noise-token 128799 --dspark-markov-rank 256 \
  '';

  # The pack: this set's files and the pinned pack tool - nothing else. The tool is stdlib-only and reads the
  # GGUF metadata itself, so no python packages here; it must not leave a __pycache__ in the read-only store
  # path.
  pack =
    runCommand packFile
      {
        nativeBuildInputs = [ python3 ];
        buildInputs = [ shardFarm ];
        env.PYTHONDONTWRITEBYTECODE = "1";
      }
      ''
        # pack_gguf.py writes the engine's folder, and nothing outside it: ds4.txt (the geometry, under
        # config.json's names, with model_dir pointing at the shards' store path - the engine opens the
        # files there), tensors.txt (every tensor with the file and offset it lives in, so the Engram's rows
        # read the table file on the disk instead of a copy of it), engram.bin (the hash tables), and
        # tokenizer/ (vocab, merges, the chat template, pre deepseek3).
        ${python3}/bin/python3 ${strataDsv41Tools}/tools/dsv41/pack_gguf.py \
          --model ${shardFarm} --out $out \
          ${packFlags}
        ${lib.optionalString (expertProfile != null) ''
          # the profile of experts to keep resident, where setup.py puts it: in the pack folder, where the
          # engine finds it without a flag.
          cp ${strataDsv41Tools}/data/dsv41/${expertProfile} $out/expert-profile.bin
        ''}
      '';
in
runCommand "strata-model-${size}"
  {
    meta = {
      description = "Strata's DeepSeek-V4.1-Flash ${label}: its pinned GGUF files (~${download} GB) packed into the engine's folder";
      homepage =
        if ista then "https://huggingface.co/${istaRepo}" else "https://huggingface.co/${unslothRepo}";
      # DeepSeek's model license, as setup.py records it for the family
      license = lib.licenses.unfreeRedistributable;
      platforms = [ "x86_64-linux" ];
    };
    # the contract the Strata assembly reads: see the header
    passthru.strata = {
      key = "DeepSeek41_IQ2_XS";
      inherit
        size
        packName
        modelName
        minEngine
        ram
        download
        memoryNote
        ;
      inherit dsparkConf expertProfile;
      # the family decides the engine binary and the config's shape (setup.py's MULTI_FILE_FAMILIES)
      family = "deepseek41";
      # the engine has no --native for this family - the pack's tensor map names every file - so these are
      # here only so that a caller reading the contract still finds the set's first shard
      shard1 = (builtins.head shards).name;
      ple = (builtins.head shards).name;
      # no image encoder: setup.py ships none for this family (its vision_pack.py makes one from DeepSeek's
      # checkpoint, and the engine takes --images and --vision once one is there)
      mmprojName = null;
      mmprojDir = null;
      inherit shardFarm pack;
    };
  }
  ''
    mkdir -p $out
    ln -s ${pack} $out/pack
    ln -s ${shardFarm} $out/shards
  ''
