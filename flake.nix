{
  description = "Strata: an OpenAI- and Anthropic-compatible model server on one AMD GPU plus system RAM (Linux, ROCm from nixpkgs); the package also carries the IQ2_XS model, its derived tokenizer and the MTP draft layer, every download a pinned fetchurl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # the project source is not an input: the package fetches it itself with pkgs.fetchFromGitHub,
    # pinned to the v0.1.37 tag (setup.py's MIN_ENGINE, the `version` in the package). To track main
    # or bump the version, change the fetch in pkgs/by-name/st/strata/package.nix.
    # the HIP target list the engine is compiled for, read from the package's config.json
    # (pkgs/by-name/st/strata/config.json). Override it for
    # your card with any of:
    #   nix build .#strata --override-input strata-config path:./pkgs/by-name/st/strata/config.gfx1100.json
    #   nix build .#strata --override-input strata-config path:<your-file.json>
    # a file holding just the string also works: --override-input strata-config path:.../archs.json
    # with { "hipArchs": "gfx1100;gfx1201" }. The list is validated by the package's hip_backend.cmake
    # (gfx1100 + gfx1201 maintainer-validated, gfx1101 + gfx1200 community-validated, the rest build
    # with a warning; docs/AMD_HIP.md).
    strata-config = { url = "path:./pkgs/by-name/st/strata/config.json"; flake = false; };
  };

  outputs = { self, nixpkgs, strata-config }:
  let
    pkgs = import nixpkgs { system = "x86_64-linux"; };

    readJson = p:          # tryEval returns { success, value }; a missing/bad file yields success = false
      let r = builtins.tryEval (builtins.fromJSON (builtins.readFile p));
      in if r.success then r.value else null;
    # strata-config is a sourceInfo attrset (non-flake path input); .outPath names the single file it holds.
    # The file may hold the string with the list or an object { "hipArchs": "..." }.
    cfg = let a = readJson strata-config.outPath; in if a != null then a else readJson ./pkgs/by-name/st/strata/config.json;   # override first, then in-repo
    hipArchs =
      let chosen = cfg;
      in if chosen == null then "gfx1100;gfx1151;gfx1201"
         else if builtins.typeOf chosen == "string" then chosen
         else if chosen ? hipArchs then chosen.hipArchs
         else "gfx1100;gfx1151;gfx1201";

    # the package itself lives in pkgs/by-name/st/strata/package.nix (the source pin, the build, the
    # config the server reads). Only what a package.nix cannot know on its own is passed in here: the
    # architecture list chosen above.
    strata = pkgs.callPackage ./pkgs/by-name/st/strata/package.nix {
      inherit hipArchs;
    };
  in
  {
    packages.x86_64-linux.strata = strata;
    packages.x86_64-linux.default = strata;
    # the service module (modules/services/strata.nix): import it in a NixOS configuration as
    # nixosModules.strata, then services.strata.enable = true
    nixosModules.strata = import ./modules/services/strata.nix;
  };
}
