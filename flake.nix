{
  description = "Strata: an OpenAI- and Anthropic-compatible model server on one AMD GPU plus system RAM (Linux, ROCm from nixpkgs); the package also carries the IQ2_XS model, its derived tokenizer, the MTP draft layer and the image encoder, every download a pinned fetchurl";

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
      # config the server reads) and knows its own HIP target list: hipArchs is a callPackage parameter
      # there, default [ "gfx1100" "gfx1151" "gfx1201" ]. Nothing is passed in here, so that default
      # applies; for another card, change the default there or callPackage it yourself:
      #   pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; };
      # In a NixOS configuration the service module's services.strata.hipArchs does the same. The list is
      # validated by the source's own hip_backend.cmake (gfx1100 + gfx1201
      # maintainer-validated, gfx1101 + gfx1200 community-validated, the rest - gfx1151 included - build with
      # a warning; docs/AMD_HIP.md), and is recorded in the package's bin/BUILD.json.
      strata = pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { };
    in
    {
      packages.x86_64-linux.strata = strata;
      packages.x86_64-linux.default = strata;
      # the service module (modules/services/strata.nix): import it in a NixOS configuration as
      # nixosModules.strata, then services.strata.enable = true
      nixosModules.strata = import ./modules/services/strata.nix;
    };
}
