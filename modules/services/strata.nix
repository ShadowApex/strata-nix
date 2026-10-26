# The Strata service: the engine and its Python server as a systemd unit.
#
# The package is self-contained, so the service adds only what a service has to know: the GPU device nodes,
# a writable stateDir, and its own settings merged into the package's etc/strata/strata.json. Import it from
# the flake (nixosModules.strata), then:
#
#   services.strata.enable = true;
#   services.strata.apiKey = "a long random secret";   # or environment.STRATA_API_KEY
#   services.strata.host = "0.0.0.0";                  # only if other devices should reach it
#
# A keyless server answers only requests whose Host is a loopback name (DNS-rebinding protection), so one
# reached under another name needs extraConfig.allowed_hosts = [ "that.name" ]. A key in the Nix config lands
# in the store, which is why apiKey defaults to null and the server reads $STRATA_API_KEY.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.strata;
  types = lib.types;

  # The by-name packages take their pins as arguments rather than importing them, so building the default
  # package here means passing them in. Each model line reads only its own tools pin, which is why there are
  # two: moving one must not re-run the other line's packs.
  strataLlamaCpp = import ../../pkgs/by-name/st/strata/llama.cpp.nix {
    inherit (pkgs) fetchurl stdenvNoCC;
  };
  strataTools = pkgs.callPackage ../../pkgs/by-name/st/strata-tools/package.nix { };
  strataDsv41Tools = pkgs.callPackage ../../pkgs/by-name/st/strata-dsv41-tools/package.nix { };
  strataModelArgs = {
    inherit strataTools strataLlamaCpp;
  };
  strataDs4ModelArgs = {
    inherit strataDsv41Tools;
  };

  # services.strata.model names a size and this picks the by-name package carrying it and its family. The
  # engine package takes a model package rather than a string - a by-name package may only use its arguments -
  # so the choice lands here, and the family decides whether services.strata.mtp is used at all.
  modelPackages = {
    Qwen_Q2_0 = {
      package = "strata-model-q2-0";
      family = "qwen35_ista";
    };
    Qwen_IQ2_XS = {
      package = "strata-model-iq2-xs";
      family = "qwen35_ista";
    };
    Qwen_IQ3_XXS = {
      package = "strata-model-iq3-xxs";
      family = "qwen35_ista";
    };
    Qwen_IQ3_S = {
      package = "strata-model-iq3-s";
      family = "qwen35_ista";
    };
    Swift_IQ2_XS = {
      package = "strata-model-swift-iq2-xs";
      family = "qwen35_ista";
    };
    Swift_IQ3_XXS = {
      package = "strata-model-swift-iq3-xxs";
      family = "qwen35_ista";
    };
    Swift_IQ3_S = {
      package = "strata-model-swift-iq3-s";
      family = "qwen35_ista";
    };
    Coder_IQ1_M = {
      package = "strata-model-coder-iq1-m";
      family = "qwen35_ista";
    };
    Unsloth_UD_IQ4_XS = {
      package = "strata-model-unsloth-ud-iq4-xs";
      family = "qwen35_ista";
    };
    Unsloth_UD_Q4_K_XL = {
      package = "strata-model-unsloth-ud-q4-k-xl";
      family = "qwen35_ista";
    };
    Unsloth_UD_Q5_K_XL = {
      package = "strata-model-unsloth-ud-q5-k-xl";
      family = "qwen35_ista";
    };
    Unsloth_UD_Q6_K_XL = {
      package = "strata-model-unsloth-ud-q6-k-xl";
      family = "qwen35_ista";
    };
    Unsloth_Q8_0 = {
      package = "strata-model-unsloth-q8-0";
      family = "qwen35_ista";
    };
    Gyro_S = {
      package = "strata-model-gyro-s";
      family = "qwen35moe";
    };
    Gyro_M = {
      package = "strata-model-gyro-m";
      family = "qwen35moe";
    };
    Qwen36_UD_Q4_K_XL = {
      package = "strata-model-qwen36-ud-q4-k-xl";
      family = "qwen36";
    };
    Qwen36_UD_Q6_K_XL = {
      package = "strata-model-qwen36-ud-q6-k-xl";
      family = "qwen36";
    };
    Qwen36_Q8_0 = {
      package = "strata-model-qwen36-q8-0";
      family = "qwen36";
    };
    DeepSeek41_IQ1_M = {
      package = "strata-model-ds4-iq1-m";
      family = "deepseek41";
    };
    DeepSeek41_IQ2_XXS = {
      package = "strata-model-ds4-iq2-xxs";
      family = "deepseek41";
    };
    DeepSeek41_IQ2_XS = {
      package = "strata-model-ds4-iq2-xs";
      family = "deepseek41";
    };
    DeepSeek41_UD_Q8_K_XL = {
      package = "strata-model-ds4-ud-q8-k-xl";
      family = "deepseek41";
    };
  };
  modelAliases = {
    Q2_0 = "Qwen_Q2_0";
    IQ2_XS = "Qwen_IQ2_XS";
    IQ3_XXS = "Qwen_IQ3_XXS";
    IQ3_S = "Qwen_IQ3_S";
    Gyro-S = "Gyro_S";
    Gyro-M = "Gyro_M";
    DSV41_IQ1_M = "DeepSeek41_IQ1_M";
    DSV41_IQ2_XXS = "DeepSeek41_IQ2_XXS";
    DSV41_IQ2_XS = "DeepSeek41_IQ2_XS";
    DSV41_UD_Q8_K_XL = "DeepSeek41_UD_Q8_K_XL";
  };
  deepseek = modelPackages.${cfg.model}.family == "deepseek41";
  qwen36 = modelPackages.${cfg.model}.family == "qwen36";

  # The longest context the model was trained on. Past it the rotary angles have to be rescaled, and
  # setup.py's answer is yarn at the final-over-trained factor.
  trainedContext = 262144;

  # The engine's performance switches as typed options. They reach the config as engine environment
  # variables, and services.strata.env is applied after them, so setting the same variable there wins. A null
  # option leaves the key out rather than writing an empty value: the engine reads an unset one as its
  # default for the architecture.
  perfEnv =
    (lib.optionalAttrs (cfg.hipWmma != null) { STRATA_HIP_WMMA = if cfg.hipWmma then "1" else "0"; })
    // (lib.optionalAttrs (cfg.coldOverlap != null) { STRATA_COLD_OVERLAP = toString cfg.coldOverlap; })
    // (lib.optionalAttrs (cfg.ioPrefetch != null) {
      STRATA_IO_PREFETCH = if cfg.ioPrefetch then "1" else "0";
    })
    # read by the server rather than the engine: +5 on an APU since v0.2.2 so the desktop keeps its CPU share
    // (lib.optionalAttrs (cfg.engineNice != null) {
      STRATA_ENGINE_NICE = toString cfg.engineNice;
    })
    # DeepSeek only: a conversation displaced by another request is set aside at its checkpoints and taken
    # back, so returning to one does not repay its prompt. This package has to name the folder: the engine's
    # default is <pack>/slots, and $out/pack is a read-only symlink.
    // (lib.optionalAttrs deepseek {
      STRATA_DS4_SLOT_DIR = "${cfg.stateDir}/ds4-slots";
    })
    // (lib.optionalAttrs (cfg.keepConversations != null) {
      STRATA_DS4_SLOT_KEEP = if cfg.keepConversations then "1" else "0";
    })
    // (lib.optionalAttrs (cfg.conversationSlotsGb != null) {
      STRATA_DS4_SLOT_GB = toString cfg.conversationSlotsGb;
    });

  # A server-side switch rather than engine environment: strata_control/hipblaslt_tuning.py reads this config
  # key when bin/strata-server picks the table for the card it finds.
  tuningCfg = lib.optionalAttrs (cfg.hipblasltTable != null) {
    hipblaslt_table = cfg.hipblasltTable;
  };

  # The config is written at build time, with the package as an input, so the store paths inside it are real
  # dependencies rather than text read out of the store at eval time and written back out.
  confFile =
    pkgs.runCommand "strata-service-config.json"
      {
        srcs = [ cfg.package ];
      }
      ''
        ${pkgs.jq}/bin/jq -n \
          --slurpfile base ${cfg.package}/etc/strata/strata.json \
          --arg cwd "${cfg.stateDir}" \
          --argjson env '${builtins.toJSON (perfEnv // cfg.env)}' \
          --argjson extra '${builtins.toJSON (tuningCfg // cfg.extraConfig)}' \
          --argjson args '${builtins.toJSON cfg.engineArgs}' \
          --argjson engine_extra '${builtins.toJSON cfg.extraEngineArgs}' \
          --argjson model '${builtins.toJSON cfg.modelName}' \
          --argjson roles '${builtins.toJSON cfg.gpuRoles}' \
          --argjson ctx '${builtins.toJSON cfg.maxContext}' \
          --argjson rope '${if deepseek || qwen36 then "false" else "true"}' \
          --argjson trained '${toString trainedContext}' \
          --argjson ready '${builtins.toJSON cfg.engineReady}' \
          '# rewrite one flag: drop every occurrence of it and the value that follows it, then append
           # ours, so a flag repeated in engineArgs cannot win (the engine keeps the last one it sees)
           def set_arg($name; $val):
             . as $a
             | [ range(0; $a | length) as $i
                 | select($a[$i] != $name and ($i == 0 or $a[$i - 1] != $name))
                 | $a[$i] ]
               + [ $name, $val ];
           # the context flags: --max-context, plus the yarn scaling setup.py adds past the trained length
           # unless the args already choose a rope method. $rope is false for DeepSeek-V4.1, whose engine has
           # no rope flag at all.
           def context_args($tokens; $trained; $rope):
             [ [ "--max-context", ($tokens | tostring) ] ]
             + (if $rope and $tokens > $trained and (any(.[]; . == "--rope-scaling") | not)
                then [ [ "--rope-scaling", "yarn" ], [ "--rope-scale", ($tokens / $trained | tostring) ] ]
                else []
                end);
           def engine_args($base):
             ((if $args != null then $args else ($base.args // []) end) + $engine_extra)
             | (if $ctx == null then [] else context_args($ctx; $trained; $rope) end) as $set
             | reduce $set[] as $kv (.; set_arg($kv[0]; $kv[1]));
           $base[0]
             + { cwd: $cwd,
                 env: (($base[0].env // {}) + $env),
                 args: engine_args($base[0]) }
             + (if $model != null then { model_name: $model } else {} end)
             + (if $roles != null then { gpu_roles: $roles } else {} end)
             + (if $ready != null then { engine_ready_s: $ready } else {} end)
             + $extra' > $out
      '';

  # strata-server passes its own --config first; argparse takes the last one, so this one wins
  serverArgs = [
    "--config"
    confFile
  ]
  ++ lib.optionals (cfg.host != null) [
    "--host"
    cfg.host
  ]
  ++ [
    "--port"
    (toString cfg.port)
  ]
  ++ lib.optionals (cfg.apiKey != null) [
    "--api-key"
    cfg.apiKey
  ]
  ++ lib.optionals (cfg.gpu != null) [
    "--gpu"
    (toString cfg.gpu)
  ]
  ++ cfg.extraArgs;
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "the Strata model server (OpenAI- and Anthropic-compatible APIs)";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.callPackage ../../pkgs/by-name/st/strata/package.nix {
        inherit (cfg)
          hipArchs
          mtp
          prefillMmq
          ;
        model = pkgs.callPackage ../../pkgs/by-name/st/${modelPackages.${cfg.model}.package}/package.nix (
          if deepseek then strataDs4ModelArgs else strataModelArgs
        );
      };
      description = "The Strata package to serve: the engine, the two picture readers and the server, assembled
        over the model package services.strata.model selects and services.strata.mtp. Set this to a package built
        for the card in the machine, or to the flake's own package.";
    };

    hipArchs = lib.mkOption {
      type = types.listOf types.str;
      default = [
        "gfx1100"
        "gfx1151"
        "gfx1201"
      ]; # the package's own default
      example = [
        "gfx1100"
        "gfx1201"
      ];
      description = "The HIP target list the default package is compiled for, one architecture per entry. Only
        used to build the default package, so override services.strata.package when the machine's card is a
        different one.";
    };

    model = lib.mkOption {
      type = types.enum (lib.attrNames modelPackages ++ lib.attrNames modelAliases);
      default = "Qwen_IQ2_XS";
      example = "Qwen_IQ3_S";
      apply =
        value:
        if builtins.hasAttr value modelAliases then
          lib.warn "services.strata.model = \"${value}\" is deprecated; use \"${modelAliases.${value}}\"."
            modelAliases.${value}
        else
          value;
      description = "Which model to serve. It picks the model package the default package is assembled over,
        carrying that size's pinned GGUF shards, the pack and tokenizer cut from them, and the image encoder -
        so switching size keeps the engine, both picture readers and the draft layer cached. See the README's
        model table for the memory and download of each size. The canonical names are family-prefixed
        (Qwen_*, Swift_*, Coder_*, Unsloth_*, Gyro_*, Qwen36_*, DeepSeek41_*); the old names
        (IQ2_XS, Gyro-S, DSV41_*, ...) still work but evaluate with a deprecation warning. A DeepSeek41_* size is
        DeepSeek-V4.1-Flash: a different engine binary, four shards plus a 110 GB n-gram table that stays on disk,
        and the drafter inside that pack instead of services.strata.mtp. A Qwen36_* size is Qwen3.6-35B-A3B: the
        engine reads the GGUF itself and drafts from the MTP block inside it. To serve a model package the flake
        does not carry, set services.strata.package to one assembled over it.";
    };

    mtp = lib.mkOption {
      type = types.nullOr types.package;
      default =
        if deepseek || qwen36 then
          null
        else
          pkgs.callPackage ../../pkgs/by-name/st/strata-mtp/package.nix strataModelArgs;
      description = "The MTP draft layer the engine speculates with (pkgs/by-name/st/strata-mtp/). It is
        size-independent, so switching services.strata.model keeps it cached, and it is used for the Flash-Next
        and Gyro sizes only. DeepSeek-V4.1-Flash drafts from the DSpark layer its own pack already holds, and
        Qwen3.6 drafts from the MTP block inside its GGUF, so the default is null for a DeepSeek41_* or Qwen36_*
        model rather than fetching ~55 GB the engine never reads.";
    };

    prefillMmq = lib.mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = "Whether the default package builds the GGML MMQ prompt path, the engine's fused
        prompt-expert kernels for the prefill. It reaches the engine stage alone, so changing it rebuilds the
        engine, not the pack.";
    };

    port = lib.mkOption {
      type = types.port;
      default = 8080;
      description = "The port the API listens on.";
    };

    hipWmma = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = "Whether the prompt path's attention runs on the GPU's matrix cores (STRATA_HIP_WMMA). Null:
        the engine's choice for the card, on for RDNA4 (gfx1200/gfx1201) and off for RDNA3. True forces it on,
        which is how a gfx11 card gets it at all; the matrix cores accumulate differently, so the text changes
        slightly, which is why the engine leaves it off there. For the per-prompt choice set STRATA_HIP_WMMA=auto
        in services.strata.env instead.";
    };

    coldOverlap = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      example = 0;
      description = "How many layers' experts the engine computes straight out of the page cache instead of
        copying them first (STRATA_COLD_OVERLAP): 4 is its default, 0 turns it off. Null: the engine's default. It
        only applies to experts read in place from the model file, so with this package's resident mode - whose
        experts come from pack/experts.bin - it changes nothing until services.strata.engineArgs replaces
        --resident-experts with --mmap-experts.";
    };

    ioPrefetch = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = "Whether the engine reads the experts it will need next on separate I/O threads while the
        current layer computes (STRATA_IO_PREFETCH). Null: on for a model read in place from the file on Linux,
        off for a pack's experts.bin. Like services.strata.coldOverlap it is about the file, so this package's
        resident-experts config makes it a no-op until services.strata.engineArgs replaces --resident-experts
        with --mmap-experts.";
    };

    hipblasltTable = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = true;
      description = "Whether the prompt's dense matrix products run on one of the measured hipBLASLt solution
        tables the package ships in bin/tuning (the server's hipblaslt_table, which bin/strata-server applies at
        start). Null: automatic, which upstream enables on gfx1151 only - and nixpkgs' hipBLASLt has no gfx1151
        table, so nothing is used until this is true. True: the table for the card. False: never. A table changes
        which hipBLASLt solution runs, so answers can differ in the last digits; the engine checks the table's
        architecture and hipBLASLt version against the card and falls back to plain hipBLAS for anything it does
        not cover. The tables sit in the assembly's bin and bin/strata is a symlink into an engine store path with
        none beside it, so only this option reaches them. To use a table of your own, set STRATA_HIPBLASLT_TUNING
        to its path in services.strata.env.";
    };

    host = lib.mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = "The address to listen on. 127.0.0.1 is this machine only; 0.0.0.0 also serves
        other devices on the network, and then an API key is required.";
    };

    apiKey = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "a long random secret";
      description = "The key required on /v1/* (Authorization: Bearer or x-api-key). Null: the server
        uses $STRATA_API_KEY from the service environment instead, which is how to keep the key out of
        the Nix configuration.";
    };

    gpu = lib.mkOption {
      type = types.nullOr (
        types.oneOf [
          types.int
          types.str
        ]
      );
      default = null;
      example = "0,1";
      description = "The GPU (or the layer split across several, as \"0,1\") the engine runs on. Null: the
        engine's own choice. With several cards the server puts the faster one last - the Main card, which holds
        the last layers - and never puts built-in graphics last. This flag wins over services.strata.gpuRoles.";
    };

    gpuRoles = lib.mkOption {
      type = types.nullOr (
        types.attrsOf (
          types.enum [
            "main"
            "helper"
            "off"
          ]
        )
      );
      default = null;
      example = lib.literalExpression ''
        { "1" = "main"; "0" = "helper"; }
      '';
      description = "What each graphics card is for on a machine with more than one: Main holds the last layers,
        the draft layer and the final check of every window, a Helper holds a share of the layers and of the expert
        cache, and an Off card gets no process at all. The keys are the card numbers the engine reports. This
        replaces services.strata.gpu rather than adding to it - the server reads a card list it did not write as a
        hand-edited order and ignores the roles. Null: the server's recommendation, which starts the fastest card
        as Main and a card of 8 GB or less as Off.";
    };

    engineNice = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      example = 0;
      description = "The nice value the server starts the engine process with (STRATA_ENGINE_NICE). Null: +5 on a
        PC whose graphics is part of the CPU, because the engine's CPU pool would otherwise compete with the
        desktop. 0 turns that off, which is what a headless machine wants.";
    };

    stateDir = lib.mkOption {
      type = types.str;
      default = "/var/lib/strata";
      description = "The engine's working directory: the only place it can write, since the package
        itself is a read-only store path. Created by StateDirectory.";
    };

    maxContext = lib.mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 32768;
      description = "The context window in tokens: how much one request can hold (the conversation, the files,
        the tool output). Null: the package's own - 131072 for the Flash-Next-line and Gyro sizes, 32768 for a
        Qwen36_* size, and 8192 for a DeepSeek41_* size. It rewrites --max-context inside the package's own
        argument list and leaves the rest as they are, so it composes with services.strata.engineArgs, which it
        is applied after. The sizes setup.py offers are 8192, 32768, 65536, 131072, 204800, 262144, 393216 and
        524288: the KV cache grows with the context and takes VRAM the resident experts would otherwise hold, and
        past 131072 the experts plus the cache want more RAM than a 64 GB PC has. Past the 262144 positions the
        model was trained on this also gets yarn rope scaling, as setup.py writes it; an explicit --rope-scaling in
        engineArgs is left alone. DeepSeek41_* and Qwen36_* sizes get no rope scaling: neither engine path has
        the flag.";
    };

    engineReady = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      example = 7200;
      description = "How long the server waits for the engine to say READY before it stops waiting (the config's
        `engine_ready_s`). Null: the family's number - 3600 for DeepSeek-V4.1-Flash, whose experts and n-gram table
        are read from the files before the first answer, and the server's 900 for the Flash-Next, Gyro and Qwen3.6
        sizes. Raise it on a slow disk; STRATA_ENGINE_READY_S in services.strata.env does the same thing, and 0
        there waits for ever. The wait only delays the first request - it never cancels the load.";
    };

    keepConversations = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = true;
      description = "Whether strata-dsv41 keeps the conversations it has set aside across requests and across runs
        (STRATA_DS4_SLOT_KEEP). When another request takes the model the displaced conversation's checkpoint goes
        into the slot folder under services.strata.stateDir and comes back when that conversation returns, so an
        agent that revisits a prompt does not pay for reading it again. Null: on since v0.2.4.2. Only strata-dsv41
        reads it, and the folder is named here because the engine's own default, `<pack>/slots`, is a read-only
        symlink in this package - STRATA_DS4_SLOT_DIR in services.strata.env puts the slots elsewhere. The engine
        drops slots older than a week and slots belonging to another model.";
    };

    conversationSlotsGb = lib.mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 16;
      description = "How much of the slot folder under services.strata.stateDir the kept conversations may take, in
        GB (STRATA_DS4_SLOT_GB). Null: the 2 GB the server writes, a few dozen conversations; the engine alone would
        allow 16. A full folder refuses a new slot rather than evicting an old one, so raise this with
        services.strata.keepConversations on a busy machine.";
    };

    autoPinSystemPrompt = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = true;
      description = "Whether the server pins the leading system messages of every request (STRATA_DS4_AUTO_PIN). An
        agent and the sub-agents behind the same system prompt and tools ask the identical start of the prompt, so
        the next request goes back to a checkpoint there instead of reading it again. Null: on since v0.2.4.2 - it
        only helps when many requests share one prefix, and a pin costs the engine a little memory. Read by the
        server process, so it reaches the unit as Environment= rather than through the config's env, and only the
        DeepSeek engine acts on it.";
    };

    engineArgs = lib.mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = lib.literalExpression ''
        # start from the package's own args and swap the resident mode for the file tier
        (lib.remove "--resident-experts" (builtins.fromJSON (builtins.readFile "''${cfg.package}/etc/strata/strata.json").args))
        ++ [ "--mmap-experts" ]
      '';
      description = "The engine's arguments, replacing the package's list entirely: write out every flag the run
        needs, not only the ones you change, and read --pack, --native and --ple-gguf out of the package's
        etc/strata/strata.json rather than retyping them. services.strata.maxContext is the cheaper way to move one
        flag; services.strata.extraEngineArgs appends flags without replacing the list. Null: the package's own,
        unchanged.";
    };

    extraEngineArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--vram-reserve-mib"
        "2048"
      ];
      description = "Extra engine arguments appended after the package's args (or after engineArgs, when set). The
        engine keeps the last value of a repeated flag, so these win over the package's own. services.strata.maxContext
        is applied after this and still owns --max-context. Use it for VRAM and KV controls the module does not model:
        --vram-reserve-mib N for Flash-Next, Swift, Coder, Unsloth and Gyro; --expert-vram GiB or --expert-slots N for
        Qwen3.6; and --reserve-mib N or --vram-experts F for DeepSeek-V4.1-Flash.";
    };

    modelName = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The model name the API reports. Null: the package's.";
    };

    env = lib.mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        STRATA_RESIDENT_PIN = "1";
      };
      description = "Engine environment, added to what the package's config carries. Applied after the
        typed switches above, so a variable set here wins over them.";
    };

    extraConfig = lib.mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = {
        api_monitor = true;
        idle_unload_s = 300;
        allowed_hosts = [ "that.name" ];
        vision = null;
      };
      description = "Anything else the server's config accepts (sampling, aliases, mcp_servers,
        cors_origins, allowed_hosts, engine_silence_s, ...), merged into the generated config. The package's
        config has a `vision` entry for the image encoder, so setting it to null turns image support off for this
        machine. Its `exe` is the GPU reader and `cpu_exe` the fallback the server switches to by itself when the GPU
        reader does not start, so a smaller card needs nothing here - to ask for the CPU reader outright, point exe
        at bin/strata-vision and set gpu false. Since v0.2.3 `drafting` picks the alternative DFlash2 drafter, which
        wants a pack this package does not ship: the server says so and starts with the MTP layer.";
    };

    extraArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--api-monitor"
        "--fit-max-tokens"
      ];
      description = "Extra flags for serve.server (--api-monitor, --idle-unload ...). --lazy is
        refused while the config has a vision entry, so turn images off with extraConfig first.";
    };

    user = lib.mkOption {
      type = types.str;
      default = "strata";
      description = "The user the service runs as.";
    };

    group = lib.mkOption {
      type = types.str;
      default = "strata";
      description = "The group the service runs as.";
    };

    openFirewall = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Open the port in the firewall. Only meaningful when host is not 127.0.0.1.";
    };

    startTimeout = lib.mkOption {
      type = types.str;
      default = "infinity";
      description = "systemd's start timeout. Loading the model takes minutes on the first start, so
        the default does not cut the service off in the middle of it.";
    };

    generatedConfigFile = lib.mkOption {
      type = types.path;
      internal = true;
      default = confFile;
      description = "The engine config the service runs with: the package's, with the service's
        settings merged in. Internal, so a test or a debug shell can read it.";
    };
  };

  config = lib.mkIf cfg.enable {
    # a gpu_roles the server cannot read is ignored rather than refused, so the shape is checked here
    assertions = lib.optionals (cfg.gpuRoles != null) [
      {
        assertion = cfg.gpu == null;
        message = "services.strata.gpu and services.strata.gpuRoles both choose cards, and --gpu wins: the server reads a card list it did not write as the person's order and ignores the roles. Keep one of the two.";
      }
      {
        assertion = lib.all (k: builtins.match "[0-9]+" k != null) (builtins.attrNames cfg.gpuRoles);
        message = "services.strata.gpuRoles keys are card numbers as strings, as { \"1\" = \"main\"; \"0\" = \"helper\"; }.";
      }
      {
        assertion = lib.any (r: r != "off") (builtins.attrValues cfg.gpuRoles);
        message = "services.strata.gpuRoles sets every card to off, which the server ignores (it falls back to the engine's own choice), and this engine cannot start without a card. Name one card main or helper.";
      }
      {
        assertion =
          builtins.length (builtins.attrValues (lib.filterAttrs (_: r: r == "main") cfg.gpuRoles)) <= 1;
        message = "services.strata.gpuRoles names one Main card at most; the others are helper or off.";
      }
    ];

    users.users.${cfg.user} = {
      group = cfg.group;
      isSystemUser = true;
    };
    users.groups.${cfg.group} = { };

    systemd.services.strata = {
      description = "Strata model server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "strata";
        ExecStart = lib.escapeShellArgs ([ "${cfg.package}/bin/strata-server" ] ++ serverArgs);
        # the server reads this from its own process environment, not from the config it hands the engine
        Environment = lib.optionals (cfg.autoPinSystemPrompt != null) [
          "STRATA_DS4_AUTO_PIN=${if cfg.autoPinSystemPrompt then "1" else "0"}"
        ];
        Restart = "on-failure";
        RestartSec = 10;
        # the card is reached through the kernel driver, so /dev/kfd and /dev/dri stay visible (no
        # PrivateDevices) and the unit needs these groups
        SupplementaryGroups = [
          "render"
          "video"
        ];
        # the resident experts pin memory, and ROCm wants an unlimited memlock for that
        LimitMEMLOCK = "infinity";
        TimeoutStartSec = cfg.startTimeout;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        # ProtectSystem=strict makes the hierarchy read-only, and the image encoder's tempfile.mkdtemp()
        # falls back to the process's cwd - a read-only store path - when /tmp is not writable
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [ cfg.port ];
  };
}
