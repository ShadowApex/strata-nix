{
  description = "Strata: an OpenAI- and Anthropic-compatible model server on one AMD GPU plus system RAM (Linux, ROCm from nixpkgs); the engine package is assembled over a model package (22 AMD sizes across Qwen3.8-Flash-Next, Swift 1.5, Coder, Unsloth, Gyro, Qwen3.6-35B-A3B and DeepSeek-V4.1-Flash) and an MTP draft-layer package, every download a pinned fetchurl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # the project source is not an input: the packages fetch it themselves with pkgs.fetchFromGitHub,
    # pinned to the v0.2.4.2 tag (the `version` in the engine package; the separate tools pins in
    # pkgs/by-name/st/strata-tools/ and pkgs/by-name/st/strata-dsv41-tools/ move only when the files their
    # packs run change). To track main or bump the version, change those fetches.
  };

  outputs =
    { self, nixpkgs }:
    let
      # allowUnfree because most model packages carry unfree licenses: Qwen Community License for the
      # original, Coder, Unsloth and Gyro files, Swift Open License for Swift, and DeepSeek's model license
      # for the DeepSeek sets. Qwen3.6 is Apache 2.0. The engine, the image readers and the tools pin stay MIT.
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };

      # The two pins the by-name packages take as arguments rather than importing: the llama.cpp the engine
      # builds ggml from (and whose gguf-py the build-time tools import), and the Strata tools tree the packs
      # and the draft-layer extract run. The engine package imports the first itself; the model layer gets
      # both from here, which is what keeps its derivations free of the engine's source pin.
      strataLlamaCpp = import ./pkgs/by-name/st/strata/llama.cpp.nix {
        inherit (pkgs) fetchurl stdenvNoCC;
      };
      strataTools = pkgs.callPackage ./pkgs/by-name/st/strata-tools/package.nix { };
      # The DeepSeek-V4.1 pack tool, pinned apart from the Flash-Next tools tree for the same reason: one
      # release's change to tools/dsv41/ must not re-run the Flash-Next line's packing, and vice versa.
      strataDsv41Tools = pkgs.callPackage ./pkgs/by-name/st/strata-dsv41-tools/package.nix { };
      modelArgs = {
        inherit strataTools strataLlamaCpp;
      };
      # A by-name package may only be given the arguments its lambda declares, so the DeepSeek sizes get
      # their own argument set: their pack runs the dsv41 tool pin and needs no llama.cpp (pack_gguf.py is
      # stdlib-only and reads the GGUF metadata itself), and the Flash-Next sizes never see that pin.
      ds4ModelArgs = {
        inherit strataDsv41Tools;
      };

      # One package per model size, keyed by its canonical family-prefixed name. Existing package
      # directories keep their old path so their packs stay cached; the old flake output names remain as
      # aliases in legacyModels below.
      models = {
        strata-model-qwen-q2-0 = pkgs.callPackage ./pkgs/by-name/st/strata-model-q2-0/package.nix modelArgs;
        strata-model-qwen-iq2-xs = pkgs.callPackage ./pkgs/by-name/st/strata-model-iq2-xs/package.nix modelArgs;
        strata-model-qwen-iq3-xxs = pkgs.callPackage ./pkgs/by-name/st/strata-model-iq3-xxs/package.nix modelArgs;
        strata-model-qwen-iq3-s = pkgs.callPackage ./pkgs/by-name/st/strata-model-iq3-s/package.nix modelArgs;
        strata-model-swift-iq2-xs = pkgs.callPackage ./pkgs/by-name/st/strata-model-swift-iq2-xs/package.nix modelArgs;
        strata-model-swift-iq3-xxs = pkgs.callPackage ./pkgs/by-name/st/strata-model-swift-iq3-xxs/package.nix modelArgs;
        strata-model-swift-iq3-s = pkgs.callPackage ./pkgs/by-name/st/strata-model-swift-iq3-s/package.nix modelArgs;
        strata-model-coder-iq1-m = pkgs.callPackage ./pkgs/by-name/st/strata-model-coder-iq1-m/package.nix modelArgs;
        strata-model-unsloth-ud-iq4-xs = pkgs.callPackage ./pkgs/by-name/st/strata-model-unsloth-ud-iq4-xs/package.nix modelArgs;
        strata-model-unsloth-ud-q4-k-xl = pkgs.callPackage ./pkgs/by-name/st/strata-model-unsloth-ud-q4-k-xl/package.nix modelArgs;
        strata-model-unsloth-ud-q5-k-xl = pkgs.callPackage ./pkgs/by-name/st/strata-model-unsloth-ud-q5-k-xl/package.nix modelArgs;
        strata-model-unsloth-ud-q6-k-xl = pkgs.callPackage ./pkgs/by-name/st/strata-model-unsloth-ud-q6-k-xl/package.nix modelArgs;
        strata-model-unsloth-q8-0 = pkgs.callPackage ./pkgs/by-name/st/strata-model-unsloth-q8-0/package.nix modelArgs;
        strata-model-gyro-s = pkgs.callPackage ./pkgs/by-name/st/strata-model-gyro-s/package.nix modelArgs;
        strata-model-gyro-m = pkgs.callPackage ./pkgs/by-name/st/strata-model-gyro-m/package.nix modelArgs;
        strata-model-qwen36-ud-q4-k-xl = pkgs.callPackage ./pkgs/by-name/st/strata-model-qwen36-ud-q4-k-xl/package.nix modelArgs;
        strata-model-qwen36-ud-q6-k-xl = pkgs.callPackage ./pkgs/by-name/st/strata-model-qwen36-ud-q6-k-xl/package.nix modelArgs;
        strata-model-qwen36-q8-0 = pkgs.callPackage ./pkgs/by-name/st/strata-model-qwen36-q8-0/package.nix modelArgs;
        # The DeepSeek-V4.1-Flash sets (setup.py's MULTI_FILE_FAMILIES, engine strata-dsv41): four shards plus
        # the shared n-gram table and drafter, packed by tools/dsv41/pack_gguf.py into the folder the engine
        # reads. The three IST-DAS sets share the table and the drafter, so those store paths are built once.
        strata-model-deepseek41-iq1-m = pkgs.callPackage ./pkgs/by-name/st/strata-model-ds4-iq1-m/package.nix ds4ModelArgs;
        strata-model-deepseek41-iq2-xxs = pkgs.callPackage ./pkgs/by-name/st/strata-model-ds4-iq2-xxs/package.nix ds4ModelArgs;
        strata-model-deepseek41-iq2-xs = pkgs.callPackage ./pkgs/by-name/st/strata-model-ds4-iq2-xs/package.nix ds4ModelArgs;
        strata-model-deepseek41-ud-q8-k-xl = pkgs.callPackage ./pkgs/by-name/st/strata-model-ds4-ud-q8-k-xl/package.nix ds4ModelArgs;
      };

      # The pre-canonical flake output names. They build the same derivations, so existing commands keep
      # working without re-downloading anything.
      legacyModels = {
        strata-model-q2-0 = models.strata-model-qwen-q2-0;
        strata-model-iq2-xs = models.strata-model-qwen-iq2-xs;
        strata-model-iq3-xxs = models.strata-model-qwen-iq3-xxs;
        strata-model-iq3-s = models.strata-model-qwen-iq3-s;
        strata-model-ds4-iq1-m = models.strata-model-deepseek41-iq1-m;
        strata-model-ds4-iq2-xxs = models.strata-model-deepseek41-iq2-xxs;
        strata-model-ds4-iq2-xs = models.strata-model-deepseek41-iq2-xs;
        strata-model-ds4-ud-q8-k-xl = models.strata-model-deepseek41-ud-q8-k-xl;
      };

      # The MTP draft layer: size-independent, pinned to the original checkpoint's shards and the tools pin.
      mtp = pkgs.callPackage ./pkgs/by-name/st/strata-mtp/package.nix modelArgs;

      # The engine and its assembly (pkgs/by-name/st/strata/package.nix: the source pin, the build, the
      # config the server reads) over a model package. hipArchs and prefillMmq are its other parameters,
      # default [ "gfx1100" "gfx1151" "gfx1201" ] and true; for another card, callPackage it yourself:
      #   pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = strataPkgs.strata-model-qwen-iq3-s; inherit (strataPkgs) strata-mtp; }
      # In a NixOS configuration, services.strata.hipArchs, services.strata.prefillMmq and
      # services.strata.model (a canonical model name the module maps to the matching model package) do the same. The target list is validated by the source's own
      # hip_backend.cmake (gfx1100 + gfx1201 maintainer-validated, gfx1101 + gfx1200 community-validated,
      # the rest - gfx1151 included - build with a warning; docs/AMD_HIP.md), and is recorded in the
      # package's bin/BUILD.json.
      strataFor =
        model:
        pkgs.callPackage ./pkgs/by-name/st/strata/package.nix {
          inherit model mtp;
        };
      strata = strataFor models.strata-model-qwen-iq2-xs;
    in
    {
      # Packages exposed in this flake, each under its package name: the engine assembled over Qwen_IQ2_XS,
      # and the pieces it is assembled from. A model package builds its payload alone - downloads and the
      # pack - without the engine, and `nix build .#strata-model-qwen-iq3-s` is how to warm that cache before
      # switching a service to it. A configuration asks for one by size: services.strata.model = "Qwen_IQ3_S";
      packages.x86_64-linux = {
        strata = strata;
        default = strata;
        strata-tools = strataTools;
        strata-dsv41-tools = strataDsv41Tools;
        strata-mtp = mtp;
      }
      // models
      // legacyModels;

      # the service module (modules/services/strata.nix): import it in a NixOS configuration as
      # nixosModules.strata, then services.strata.enable = true
      nixosModules.strata = import ./modules/services/strata.nix;
    };
}
