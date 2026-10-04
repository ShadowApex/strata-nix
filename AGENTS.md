# Agent Instructions

## Code Guidelines

- After changing any `.nix` file, verify that the package still builds. Fix any
  errors or warnings. Iterate until the build is clean, then run `nixfmt` to
  ensure formatting is consistent.
- Do not deeply nest code. Keep it flat and easy to read where possible.
- Do not add superfluous comments. Basic doc comments are fine. Explanatory
  comments should be reserved for complex or non-intuitive logic.
- Keep implementation as simple as possible.
- After making changes, review your code and look for opportunities to simplify
  or otherwise improve your changes.

Nix-specific:

- If `nixfmt` is not installed on the host, run it through nixpkgs:
  `nix shell nixpkgs#nixfmt --command nixfmt <file>`. The tree is not currently
  nixfmt-clean, so formatting a file you did not otherwise change produces
  unrelated churn — format the files you touched, or do formatting in its own
  commit.
- Every source is a hash-pinned `fetchurl`/`fetchFromGitHub`. Any change to a
  pin (version, tag, HF revision, llama.cpp commit) means re-pinning the hash:
  the first build reports the mismatch, or use
  `nix-prefetch-url --unpack <archive url>`.
- Keep the build network-free. Nothing may fetch at configure or build time; if
  a dependency is needed, pin it as a store path and pass the path in.

## Repository Structure

```text
flake.nix                          # thin wrapper: callPackage the package, expose packages.* and nixosModules.strata
pkgs/by-name/st/strata/            # the package, in nixpkgs' by-name layout (this directory is what would move to nixpkgs)
  package.nix                      # the source pin, the build, and the config the server reads; hipArchs is its parameter
  llama.cpp.nix                    # pinned llama.cpp, source-only store path, used as -DSTRATA_GGML_DIR
  hip_backend.patch                # applied by patchPhase: adds gfx1151/gfx1150 to the tag's arch list
modules/services/strata.nix        # the services.strata NixOS module (the service as a systemd unit)
README.md                          # build/run/service usage, and the layout table
```

The package produces one self-contained store path — engine, Python server, model,
tokenizer, MTP draft layer, image encoder, ROCm runtime — with this output layout:

```text
bin/strata            the engine (HIP)
bin/strata-device     the device probe (--list-devices)
bin/strata-server     the Python server wrapper
bin/strata-vision     the image encoder (llama.cpp's mtmd), on the CPU
bin/BUILD.json        the version, backend, arch list and vision backend actually compiled
etc/strata/strata.json  the config the server reads
pack/iq2xs            the packed model and the tokenizer derived from its GGUF metadata
models/IQ2_XS         the two pinned GGUF shards
vision/               the pinned mmproj the image encoder reads
mtp/rt                the packed MTP draft layer
data/expert-profile.bin
serve/ tools/ chat.py requirements.txt   the upstream Python tree, run from the store
```

## Key Invariants

- The Strata source is **not** a flake input: the package fetches it itself with
  `fetchFromGitHub`, pinned to the tag matching `version`. A flake input named
  `strata` once shadowed the derivation built from it inside its own definition
  and recursed; do not reintroduce one.
- Payloads enter the build as `linkFarm` directories, never as bare files in
  `buildInputs`: stdenv `source`s every bare file there as a setup hook.
- `configurePhase = "true"` is deliberate. stdenv's default configure would run
  cmake with no flags and hit the network `FetchContent` for llama.cpp.
- Store paths inside generated files must be real dependencies, not text. The
  package substitutes `@OUT@`/`@PY@` with `sed`; the service module builds its
  config with `runCommand` (a string read from the store at eval time carries no
  context and cannot be written back out).
- `etc/strata/strata.json` is read with plain `json.loads`, so nothing in it may
  be a comment; the explanation of the `vision` section lives in the Nix source.
- The image encoder is CPU-only for this backend: upstream has no GPU vision
  encoder for HIP (`setup.py`'s `hip_vision()` answers "images off, or
  `--vision cpu`"). It is a second CMake project, `tools/vision`, built against
  the llama.cpp store path with `-DLLAMA_DIR=` and `MTMD_VIDEO=OFF` (the server
  sends still images only, so it needs no ffmpeg). Its `model` is shard 1 with
  shard 2 beside it under the original names, which is how llama.cpp resolves a
  split GGUF.
- nixpkgs has no single `/opt/rocm` prefix: each ROCm package is its own store
  path, found through `CMAKE_PREFIX_PATH`, and the HIP compiler is
  `rocm.clr/bin/amdclang++`.
- `hipArchs` is the only caller-visible knob (a list, or a `;`-joined string). It
  is validated by the package's `cmake/hip_backend.cmake` as patched —
  unvalidated archs build with a warning — and is recorded in `bin/BUILD.json`.
- `hip_backend.patch` is a temporary divergence from the tagged source (unchanged since
  `v0.1.37`). When it lands upstream, drop the patch and nothing else changes.
- `llama.cpp.nix` is `import`ed directly. That is fine here, but a nixpkgs
  `by-name` package may only use its function arguments, so it would have to
  become its own `by-name` entry to be upstreamed.
- The output is read-only: the service can write only to `services.strata.stateDir`
  (`/var/lib/strata`). The GPU is reached through the kernel driver, so the unit
  keeps `/dev/kfd` and `/dev/dri` visible (no `PrivateDevices`), needs the
  `render`/`video` groups and unlimited memlock, and has no start timeout.
- `x86_64-linux` only: the flake defines no other system and the package's
  `platforms` say so.

## Commands

```sh
nix build .#strata                 # ~2 min compile; ~120 GB of pinned downloads on a cold cache
nix build .#strata --dry-run       # does this change invalidate the derivation? (nothing printed = cached)
nix run .#strata -- --help         # the engine's usage, from the store (no GPU needed)
nix flake check --no-build         # eval only: checks the derivation and the NixOS module
```

Plain `nix flake check` builds the package, so use `--no-build` for the quick
check.

A change to the build recipe re-runs the pack/extract steps over ~67 GB of model
data; a change to a pin re-downloads. Check with `--dry-run` before starting a
rebuild.

```sh
# another card: hipArchs is a callPackage parameter of the package
nix build --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; }'

# re-pin a hash after changing a pin
nix-prefetch-url --unpack https://github.com/Niko1221/Strata/archive/v<version>.tar.gz

# formatting
nix shell nixpkgs#nixfmt --command nixfmt flake.nix pkgs/by-name/st/strata/package.nix
```

There are no tests or CI in this repository. The NixOS module is exercised by
evaluating it in a consumer flake (`nixosModules.strata` +
`services.strata.enable = true`); runtime behaviour needs a real AMD card.
