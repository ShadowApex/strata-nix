{
  description = "Strata: an OpenAI- and Anthropic-compatible model server on one AMD GPU plus system RAM (Linux, ROCm from nixpkgs); the package also carries the IQ2_XS model, its derived tokenizer and the MTP draft layer, every download a pinned fetchurl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # the project source, pulled from GitHub at the v0.1.37 tag (setup.py's MIN_ENGINE, the
    # `version` in the package). flake = false, so the input is a plain store path rather than a
    # flake - that is what the derivation's src uses. To track main or bump the version,
    # change the ref here: nix flake update strataSrc
    #   strataSrc = github:Niko1221/Strata/v0.1.x
    #   strataSrc = github:Niko1221/Strata/main
    # named strataSrc so it does not shadow the `strata` package built from it.
    strataSrc = { url = "github:Niko1221/Strata/v0.1.37"; flake = false; };
    # the HIP target list the engine is compiled for, read from nix/config.json. Override it for
    # your card with any of:
    #   nix build .#strata --override-input strata-config path:./nix/config.gfx1100.json
    #   nix build .#strata --override-input strata-config path:<your-file.json>
    # a file holding just the string also works: --override-input strata-config path:.../archs.json
    # with { "hipArchs": "gfx1100;gfx1201" }. The list is validated by cmake/hip_backend.cmake
    # (gfx1100 + gfx1201 maintainer-validated, gfx1101 + gfx1200 community-validated, the rest build
    # with a warning; docs/AMD_HIP.md).
    strata-config = { url = "path:./nix/config.json"; flake = false; };
  };

  outputs = { self, nixpkgs, strataSrc, strata-config }:
  let
    pkgs = import nixpkgs { system = "x86_64-linux"; };

    readJson = p:          # tryEval returns { success, value }; a missing/bad file yields success = false
      let r = builtins.tryEval (builtins.fromJSON (builtins.readFile p));
      in if r.success then r.value else null;
    # strata-config is a sourceInfo attrset (non-flake path input); .outPath names the single file it holds.
    # The file may hold the string with the list or an object { "hipArchs": "..." }.
    cfg = let a = readJson strata-config.outPath; in if a != null then a else readJson ./nix/config.json;   # override first, then in-repo
    hipArchs =
      let chosen = cfg;
      in if chosen == null then "gfx1100;gfx1151;gfx1201"
         else if builtins.typeOf chosen == "string" then chosen
         else if chosen ? hipArchs then chosen.hipArchs
         else "gfx1100;gfx1151;gfx1201";

    # the package itself lives in pkgs/by-name/st/strata/package.nix (the pins, the build, the config
    # the server reads). Only what a package.nix cannot know on its own is passed in here: the pinned
    # source from the flake input and the architecture list chosen above.
    strata = pkgs.callPackage ./pkgs/by-name/st/strata/package.nix {
      src = strataSrc;
      inherit hipArchs;
    };
  in
  {
    packages.x86_64-linux.strata = strata;
    packages.x86_64-linux.default = strata;
  };
}
