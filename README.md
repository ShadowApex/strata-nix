# strata-nix

A Nix flake that builds [Strata](https://github.com/Niko1221/Strata) — an OpenAI- and
Anthropic-compatible model server running on one AMD GPU plus system RAM — for Linux with nixpkgs'
ROCm 7 (`hipcc` + hipBLAS from `pkgs.rocmPackages`, no TheRock wheels, no ROCm install on the host
beyond the kernel's `amdgpu` driver).

The package's output holds the engine, the Python server, the model (IQ2_XS by default; IQ3_XXS or IQ3_S
with the `model` parameter), its derived tokenizer, the MTP
draft layer and the image encoder with its mmproj; every download is a hash-pinned `fetchurl`, so the
build is reproducible and needs no network at configure time. Its closure is the whole package: the big
payloads are separate stage derivations that the output links to.

The build is one derivation per stage, so the expensive stages are cached on their own. The pack and the
draft layer read only the pins and the tools scripts — no ROCm, no CMake, no target list — so changing
`hipArchs` rebuilds the engine alone, not the ~6.5 minutes of pack work.

## Requirements

- Linux, `x86_64`, Nix with flakes enabled
- An AMD GPU whose HIP architecture is in the target list (default `gfx1100`, `gfx1151`, `gfx1201`)
- Disk for the pinned model + checkpoint shards + the mmproj (~124 GB of downloads during the build for
  IQ2_XS, ~132 GB for IQ3_XXS, ~140 GB for IQ3_S)
- RAM for the model's experts: 48 GB at IQ2_XS, 60 GB at IQ3_XXS, 62 GB at IQ3_S

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

Because the pack (~4 min) and the draft layer (~2.5 min) are separate derivations, a change to the target
list rebuilds the engine and the assembly only:

```sh
nix build --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" ]; }' --dry-run
```

A change to the assembly alone (the config text, the server wrapper) is a few seconds.

## Model size

`model` is a `callPackage` parameter of the package, default `IQ2_XS`, and the flake exposes the two IQ3
sizes as their own outputs:

```sh
nix build .#strata-iq3-s          # the same engine and server over the IQ3_S pins
```

| `model` | download | RAM for its experts (`setup.py`'s `MODELS`) | |
| --- | --- | --- | --- |
| `Q2_0` | 66.4 GB | 48 GB | 2-bit, the fastest |
| `IQ2_XS` | 68.0 GB | 48 GB | 2-bit i-quant, a little better quality, close in speed |
| `IQ3_XXS` | 75.8 GB | 60 GB | 3-bit i-quant, better quality, slower (more CPU work per token) |
| `IQ3_S` | 83.6 GB | 62 GB | 3.5-bit, the best quality, the slowest; wants a 64 GB PC |

The size reaches the pins and the pack stage only: the engine, the image encoder and the draft layer are
the same for every size, so switching sizes keeps the engine cached and each size caches its own pack
(`pack/iq2xs`, `pack/iq3xxs`, `pack/iq3s`). The pack work grows with the size, since `experts.bin` is
35.5 GB at IQ2_XS, 42.9 GB at IQ3_XXS and 50.3 GB at IQ3_S. The size is recorded in the package's
`bin/BUILD.json`, and the config the package writes is the low-RAM resident mode for a PC with the RAM
listed above.

## Run

```sh
P=$(nix build .#strata --print-out-paths)
$P/bin/strata-server                 # OpenAI + Anthropic APIs on 127.0.0.1:8080
curl http://127.0.0.1:8080/health | python3 -m json.tool
```

`strata-server` reads the package's `etc/strata/strata.json` and forwards remaining flags to the server
(`--port`, `--host`, `--api-key`, `--gpu 0,1`, `--config <file>`). To serve other devices, use
`--host 0.0.0.0` **together with** `--api-key <a long random secret>`.

Without an API key the server answers only requests whose `Host` is a loopback name (v0.1.38's
DNS-rebinding protection); reaching it under another name needs `allowed_hosts` in the config or in
`STRATA_ALLOWED_HOSTS`.

The engine alone is `$P/bin/strata`; the device probe is `$P/bin/strata-device --list-devices` — run it
first when a card is not found.

## Images

The package's `etc/strata/strata.json` carries a `vision` entry and `--vision` in the engine's args, so the
server encodes pictures: OpenAI `image_url` parts, Anthropic image blocks and `chat.py`'s `/image <path>` go
through
`$P/bin/strata-vision` (llama.cpp's mtmd over `$P/vision/mmproj-Qwen3.8-Flash-Next-BF16.gguf`, ~0.9 GB)
and its rows reach the engine at the prompt's image pad tokens. Each picture is cached by its hash, so a
conversation that sends the same image again encodes it once.

For the AMD backend the encoder runs on **CPU** — upstream has no GPU image encoder for HIP, and its
`setup.py` answers "images off, or `--vision cpu`" for an AMD card. It takes half the cores when the
config names no `threads`, and `max_tokens` is 300, the value `setup.py` writes for a CPU encoder; the
model wants 1024 for grounding tasks, so raise it in the config if you use bounding boxes.

Turn images off by making `vision` null in the config the server reads, and keep `--lazy` out of the
flags: the server refuses lazy loading when the config has a `vision` entry. `--vision` stays in the engine's
args, where it is harmless without an encoder; drop it with `engineArgs` if you want the engine exactly as
setup.py would have written it for a text-only install.

The encoder writes the pictures it encodes to a temp directory (`$TMPDIR`), which is writable; the store
path itself is read-only, so `stateDir` remains the only place the service writes.

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
          services.strata.model = "IQ3_S";                                # the size the default package is built with
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
itself is a read-only store path. Images are on because the package's config has a `vision` entry;
`services.strata.extraConfig = { vision = null; }` turns them off for that machine.

`services.strata.model` builds the default package with one of the sizes above, and
`services.strata.package` takes any package instead, such as the flake's `packages.strata-iq3-s`.

## Layout

| Path | What it is |
| --- | --- |
| `flake.nix` | `callPackage`s the package; exposes `packages.strata-iq3-xxs` and `packages.strata-iq3-s` and `nixosModules.strata` |
| `pkgs/by-name/st/strata/package.nix` | The source pin, the build, the config the server reads; `hipArchs` and `model` are its parameters, default `[ "gfx1100" "gfx1151" "gfx1201" ]` and `IQ2_XS` |
| `pkgs/by-name/st/strata/llama.cpp.nix` | Pinned llama.cpp (source only) used as `-DSTRATA_GGML_DIR` |
| `modules/services/strata.nix` | The `services.strata` NixOS module (`services.strata.hipArchs` is a list of archs, `services.strata.model` the size) |
