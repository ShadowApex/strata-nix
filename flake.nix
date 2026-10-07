{
  description = "Strata: an OpenAI- and Anthropic-compatible model server on one AMD GPU plus system RAM (Linux, ROCm from nixpkgs); the package also carries the model (IQ2_XS by default, IQ3_XXS or IQ3_S with the model parameter), its derived tokenizer, the MTP draft layer and the image encoder, every download a pinned fetchurl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # the project source is not an input: the package fetches it itself with pkgs.fetchFromGitHub,
    # pinned to the v0.1.40.1 tag (the `version` in the package). To track main or bump the version,
    # change the fetch in pkgs/by-name/st/strata/package.nix.
  };

  outputs =
    { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      # The package itself lives in pkgs/by-name/st/strata/package.nix (the source pin, the build, the
      # config the server reads) and knows its own HIP target list, model size and MMQ prompt path:
      # hipArchs, model and prefillMmq are callPackage parameters there, default
      # [ "gfx1100" "gfx1151" "gfx1201" ], IQ2_XS and true. Nothing is passed in here, so those defaults
      # apply; for another card or another size, change the default there or callPackage it yourself:
      #   pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = "IQ3_S"; };
      # In a NixOS configuration the service module's services.strata.hipArchs, services.strata.model and
      # services.strata.prefillMmq do the same. The list is validated by the source's own hip_backend.cmake (gfx1100 + gfx1201
      # maintainer-validated, gfx1101 + gfx1200 community-validated, the rest - gfx1151 included - build with
      # a warning; docs/AMD_HIP.md), and is recorded in the package's bin/BUILD.json.
      strata-iq2-xs = pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = "IQ2_XS"; };
      # the same package for the two IQ3 sizes the pinned repository carries (Q2_0 is the fourth)
      strata-iq3-xxs = pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = "IQ3_XXS"; };
      strata-iq3-s = pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = "IQ3_S"; };
    in
    {
      # Packages exposed in this flake
      packages.x86_64-linux = {
        strata = strata-iq2-xs;
        strata-iq2-xs = strata-iq2-xs;
        strata-iq3-xxs = strata-iq3-xxs;
        strata-iq3-s = strata-iq3-s;
        default = strata-iq2-xs;
      };

      # the service module (modules/services/strata.nix): import it in a NixOS configuration as
      # nixosModules.strata, then services.strata.enable = true
      nixosModules.strata = import ./modules/services/strata.nix;
    };
}
