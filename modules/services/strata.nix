# The Strata service: the engine and its Python server as a systemd unit.
#
# The package is self-contained - engine, model, tokenizer, MTP draft layer, image encoder, ROCm runtime
# - so the service needs nothing outside its closure except the GPU device nodes (/dev/kfd and /dev/dri)
# and a writable directory for the engine's cwd. The engine config the server reads is the package's own
# etc/strata/strata.json, merged here with the service's settings: the pins stay in the package, the
# module only adds what a service has to know.
#
# Import it from the flake (nixosModules.strata), then:
#
#   services.strata.enable = true;
#   services.strata.apiKey = "a long random secret";   # or environment.STRATA_API_KEY
#   services.strata.host = "0.0.0.0";                  # only if other devices should reach it
#
# The model size is the package's choice: services.strata.model builds the default package with one of the
# sizes the pinned repository carries (IQ2_XS by default, IQ3_XXS, IQ3_S, Q2_0), and services.strata.package
# takes any package instead, such as the flake's packages.strata-iq3-s.
#
# The API key is a secret: putting it in the Nix config puts it in the store. A machine that keeps the
# key out of its configuration sets environment.STRATA_API_KEY some other way and leaves
# services.strata.apiKey null - the server reads the variable when there is no --api-key.
#
# Without a key the server answers only requests whose Host is a loopback name (v0.1.38's DNS-rebinding
# protection), so a keyless service reached under another name needs extraConfig.allowed_hosts =
# [ "that.name" ]; with a key the check is off.
#
# Images are on because the package's config has a "vision" entry (and "--vision" in its args, which is what
# lets the engine accept the encoder's requests): the server spawns the package's
# strata-vision (the CPU image encoder for this backend) once and keeps it resident. extraConfig =
# { vision = null; } turns that off for this machine, and --lazy must stay out of extraArgs - the server
# refuses lazy loading while vision is configured. The encoder writes the pictures it encodes to a temp
# directory, so the unit gets a private writable /tmp: ProtectSystem=strict makes everything else
# read-only, and the store path the server runs from is no substitute.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.strata;
  types = lib.types;

  # The config is written at build time, from the package's own file: the package is an input of this
  # derivation, so the store paths inside the config are real dependencies rather than text. (A
  # string read from the store at eval time carries no context and cannot be written back out.)
  confFile =
    pkgs.runCommand "strata-service-config.json"
      {
        srcs = [ cfg.package ];
      }
      ''
        ${pkgs.jq}/bin/jq -n \
          --slurpfile base ${cfg.package}/etc/strata/strata.json \
          --arg cwd "${cfg.stateDir}" \
          --argjson env '${builtins.toJSON cfg.env}' \
          --argjson extra '${builtins.toJSON cfg.extraConfig}' \
          --argjson args '${builtins.toJSON cfg.engineArgs}' \
          --argjson model '${builtins.toJSON cfg.modelName}' \
          '$base[0]
            + { cwd: $cwd, env: (($base[0].env // {}) + $env) }
            + (if $args != null then { args: $args } else {} end)
            + (if $model != null then { model_name: $model } else {} end)
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
        inherit (cfg) hipArchs model;
      };
      description = "The Strata package to serve (the engine, the model, the server). Set this to a
        package built for the card in the machine, or to the flake's own package.";
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
      description = "The HIP target list the default package is compiled for, one architecture per
        entry; only used to build the default package, so override services.strata.package instead when
        the machine's card is a different one.";
    };

    model = lib.mkOption {
      type = types.str;
      default = "IQ2_XS";
      example = "IQ3_S";
      description = "The model size the default package is built with, one of the sizes the pinned
        repository carries (IQ2_XS, IQ3_XXS, IQ3_S, Q2_0). Only used to build the default package, so
        override services.strata.package instead when you want a package that is already built. The size
        decides which pins the package carries and which pack it runs, and its experts want RAM (setup.py:
        IQ2_XS 48 GB, IQ3_XXS 60, IQ3_S 62), so the machine must have that much.";
    };

    port = lib.mkOption {
      type = types.port;
      default = 8080;
      description = "The port the API listens on.";
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
      description = "The GPU (or the layer split across several, as \"0,1\") the engine runs on. Null:
        the engine's own choice.";
    };

    stateDir = lib.mkOption {
      type = types.str;
      default = "/var/lib/strata";
      description = "The engine's working directory: the only place it can write, since the package
        itself is a read-only store path. Created by StateDirectory.";
    };

    engineArgs = lib.mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = [
        "--pack"
        "/var/lib/strata/pack"
        "--resident-experts"
        "--max-context"
        "32768"
      ];
      description = "The engine's arguments. Null: the package's own, unchanged.";
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
      description = "Engine environment, added to what the package's config carries.";
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
        cors_origins, allowed_hosts, engine_silence_s, ...), merged into the generated config. The
        package's config has a `vision` entry for the image encoder, so setting it to null here turns
        image support off for this machine.";
    };

    extraArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--lazy"
        "--fit-max-tokens"
      ];
      description = "Extra flags for serve.server (--lazy, --api-monitor, --idle-unload ...).";
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
        Restart = "on-failure";
        RestartSec = 10;
        # the card is reached through the kernel driver: /dev/kfd and /dev/dri have to stay visible,
        # so no PrivateDevices, and the service needs the render/video groups
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
        # strict makes the whole hierarchy read-only, so the service needs its own writable /tmp: the
        # image encoder creates its cache directory with tempfile.mkdtemp(), which falls back to the
        # process's cwd - the read-only store path - when /tmp is not writable.
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [ cfg.port ];
  };
}
