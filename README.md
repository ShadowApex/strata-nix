# strata-nix

A Nix flake that builds [Strata](https://github.com/Niko1221/Strata) — an OpenAI- and
Anthropic-compatible model server running on one AMD GPU plus system RAM — for Linux with nixpkgs'
ROCm 7 (`hipcc` + hipBLAS from `pkgs.rocmPackages`, no TheRock wheels, no ROCm install on the host
beyond the kernel's `amdgpu` driver).

One store path contains the engine, the Python server, the IQ2_XS model, its derived tokenizer and the
MTP draft layer; every download is a hash-pinned `fetchurl`, so the build is reproducible and needs no
network at configure time.

Detailed notes (what's in the package, the architecture list, what was verified): [docs/NIX.md](docs/NIX.md).

## Requirements

- Linux, `x86_64`, Nix with flakes enabled
- An AMD GPU whose HIP architecture is in the target list (default `gfx1100`, `gfx1151`, `gfx1201`)
- Disk for the pinned model + checkpoint shards (~120 GB of downloads during the build)

## Build

```sh
nix build .#strata            # ~2 minutes of compile on a 16-core PC (downloads fetched once)
nix run .#strata -- --help    # the engine's usage, from the store
```

For a different card, `hipArchs` is a `callPackage` parameter of the package, default
`[ "gfx1100" "gfx1151" "gfx1201" ]`. Change that default in
`pkgs/by-name/st/strata/package.nix`, or override it for a single build:

```sh
nix build --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; }'
```

The chosen list is recorded in the package's `bin/BUILD.json`.

## Run

```sh
P=$(nix build .#strata --print-out-paths)
$P/bin/strata-server                 # OpenAI + Anthropic APIs on 127.0.0.1:8080
curl http://127.0.0.1:8080/health | python3 -m json.tool
```

`strata-server` reads the package's `etc/strata/strata.json` and forwards remaining flags to the server
(`--port`, `--host`, `--api-key`, `--gpu 0,1`, `--config <file>`). To serve other devices, use
`--host 0.0.0.0` **together with** `--api-key <a long random secret>`.

The engine alone is `$P/bin/strata`; the device probe is `$P/bin/strata-device --list-devices` — run it
first when a card is not found.

## As a NixOS service

```nix
{
  inputs.strata-nix.url = "github:<you>/strata-nix";
  outputs = { self, nixpkgs, strata-nix }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata-nix.nixosModules.strata
        {
          services.strata.enable = true;
          services.strata.hipArchs = [ "gfx1100" "gfx1151" "gfx1201" ];   # the card in the machine
          services.strata.apiKey = "a long random secret";              # or null + environment.STRATA_API_KEY
        };
      ];
    };
  };
}
```

The unit runs as the `strata` user with the `render` and `video` groups, keeps `/dev/kfd` and `/dev/dri`
visible, allows unlimited memlock for the resident experts, and has no start timeout (loading the model
takes minutes). Its working directory is `/var/lib/strata` — the only writable place, since the package
itself is a read-only store path.

## Layout

| Path | What it is |
| --- | --- |
| `flake.nix` | `callPackage`s the package; exposes `nixosModules.strata` |
| `pkgs/by-name/st/strata/package.nix` | The source pin, the build, the config the server reads; `hipArchs` is its parameter, default `[ "gfx1100" "gfx1151" "gfx1201" ]` |
| `pkgs/by-name/st/strata/hip_backend.cmake` | Adds `gfx1151`/`gfx1150` to the tagged source's arch list |
| `pkgs/by-name/st/strata/llama.cpp.nix` | Pinned llama.cpp (source only) used as `-DSTRATA_GGML_DIR` |
| `modules/services/strata.nix` | The `services.strata` NixOS module (`services.strata.hipArchs` is a list of archs) |
| `docs/NIX.md` | Full notes |
