# Strata from Nix (Linux, AMD GPU)

The [flake](../flake.nix) builds the Strata engine for AMD cards with nixpkgs' ROCm 7 (hipcc +
hipBLAS from `pkgs.rocmPackages`, no TheRock wheels, no overlay) and packages it with the Python
server. The package definition itself is [pkgs/by-name/st/strata/package.nix](../pkgs/by-name/st/strata/package.nix)
(the source pin, the build, the config the server reads), and the files it reads live beside it there
(`hip_backend.cmake`, `llama.cpp.nix`, `config.json`); the flake only picks the architecture list
from its inputs and `callPackage`s it. The package (`.#strata`) contains, in one store path:

- `bin/strata` - the engine, compiled with `-DSTRATA_ENABLE_HIP=ON`
- `bin/strata-device` - the device probe (`--list-devices`)
- `bin/strata-server` - the server: the repo's `serve/` tree run by the store's Python
  (`http.server`, jinja2, regex, psutil, pillow)
- `etc/strata/strata.json` - a placeholder engine config (the real one is written after the model
  download, below)
- `bin/BUILD.json` - version, backend, and the architectures the engine was built for

Everything ROCm the engine loads (libamdhip64, hsa-runtime64, hipBLAS, LLVM bitcode libs) is in the
package's closure, so the PC needs only the kernel's `amdgpu` driver - no ROCm installed.

This is a second installation path. The first is the one-click setup
(`START-HERE.bat` / `setup.sh`): see [AI_SETUP.md](AI_SETUP.md) for how a user starts Strata, and
[AMD_HIP.md](AMD_HIP.md) for the HIP backend itself. Nix is for a PC where the user manages the
software with Nix.

## Build

```sh
nix build .#strata          # ~2 minutes for the default 3-arch build on a 16-core PC (dependencies fetched once)
nix run .#strata -- --help  # the engine's own usage, from the store
```

The build runs CMake + Ninja in the Nix sandbox. The source is fetched by the package itself
(`fetchFromGitHub`, pinned to the `v0.1.37` tag) - it is not a flake input, so `nix flake update`
does not move it; bump `version` in the package and re-pin its hash. The llama.cpp the engine builds
ggml from is not fetched over the network at configure time: it is the pinned commit `3cf03257f219...`
unpacked from a hash-pinned tarball ([llama.cpp.nix](../pkgs/by-name/st/strata/llama.cpp.nix); the same commit
CMakeLists.txt's FetchContent default and `setup.py`'s LLAMA_CPP_COMMIT use), passed as
`-DSTRATA_GGML_DIR`.

### Which card: the architecture list

The flake input `strata-config` (default [config.json](../pkgs/by-name/st/strata/config.json), beside
the package) carries
`"hipArchs"`, the list the engine is compiled for. It defaults to `gfx1100;gfx1151;gfx1201`:

- `gfx1100` - RX 7900 XT / XTX (RDNA3)
- `gfx1151` - Radeon 8060S (RDNA 3.5) - builds, not validated on a real card yet
- `gfx1201` - RX 9070 / 9070 XT, Radeon AI PRO R9700 (RDNA4)

For a different card, pass that card's architecture as an input override (the valid list and the
validated cards are in [AMD_HIP.md](AMD_HIP.md)):

```sh
# one architecture: the ready-made example file, or your own one-liner
nix build .#strata --override-input strata-config path:./pkgs/by-name/st/strata/config.gfx1100.json
# several (cards of two families need it, e.g. a gfx1100 + gfx1201 split, see AMD_HIP.md):
echo '{"hipArchs": "gfx1100;gfx1201"}' > /tmp/strata-gfx1100-gfx1201.json
nix build .#strata --override-input strata-config path:/tmp/strata-gfx1100-gfx1201.json
```

The chosen list lands in `bin/BUILD.json` (so a machine can see what its engine was built for):

```json
{ "version": "0.1.37", "backend": "hip", "archs": ["gfx1100", "gfx1151", "gfx1201"] }
```

The build log also prints one line per target (`compiling for gfx1100` / `gfx1151` / `gfx1201`) and
CMake's own `-- Strata: HIP enabled, arch gfx1100,gfx1151,gfx1201`. An architecture that does not
belong to any supported card family is refused by CMake (the same
`cmake/hip_backend.cmake` list the `setup.py` build uses; the package overrides that file with its own
[hip_backend.cmake](../pkgs/by-name/st/strata/hip_backend.cmake), which adds `gfx1151` and `gfx1150`);
the rest of the list is compiled anyway.

## Run

The server is `bin/strata-server`. It starts the engine from `etc/strata/strata.json` and serves
OpenAI- and Anthropic-compatible APIs on `127.0.0.1:8080`:

```sh
nix run -c strata-server .#strata   # or: $(nix build .#strata --print-out-paths)/bin/strata-server
```

The model is not part of the package (it is 66-120 GB and per-model; Nix does not own it). The
server needs it on disk before it can start, as the setup flow provides it:

1. Download the model and write the real config. Run the setup's download against the store
   package's path - it works out of the source tree as well:

   ```sh
   python3 setup.py --gguf-dir /path/to/Strata-data --yes --family qwen --model IQ2_XS   # size by RAM: MODELS.md
   ```

   Setup writes `strata-<model>.json` into the tree (engine path, `--pack`, tokenizer - the files
   and HuggingFace repos are in [AI_SETUP.md](AI_SETUP.md) and [MODELS.md](MODELS.md)). Or download
   the shards from the HuggingFace repos listed in [INSTALL.md](INSTALL.md#model-files-downloaded-by-hand-or-from-a-mirror-495)
   yourself and run the tokenizer export `python3 tools/strata_tokenizer.py`.
2. Point the package's config at it - copy the args setup wrote (pack, native shard, PLE shard,
   tokenizer) into whatever path you pass to `--config`:

   ```sh
   $(nix build .#strata --print-out-paths)/bin/strata-server --config /path/to/strata-iq2_xs.json
   ```

3. Verify:

   ```sh
   curl http://127.0.0.1:8080/health | python3 -m json.tool
   ```

`strata-server` forwards every other flag to the server (`--port`, `--host`, `--api-key`,
`--gpu 0,1` ...). The API-key caveat is unchanged from the setup path: the server binds to
`127.0.0.1` by default; to let other devices reach it, pass `--host 0.0.0.0` **together with**
`--api-key <a long random secret>` and nothing else.

The engine alone (no server) is `bin/strata`; its usage is `--help`. The device probe is
`bin/strata-device --list-devices` - run it first when a card is not found: if it does not list
the card, the kernel driver or the build's architecture list is the problem, not the model.

## What the package is and is not

- In: the engine and server for one model family, the ROCm runtime, the Python dependencies.
  Built with `STRATA_NATIVE_EXPERTS=ON` and `STRATA_PORTABLE=ON` (ggml-cpu at the AVX2 baseline:
  this flake may build on a different PC than the one that runs the result; the AVX-512 expert
  kernels keep their runtime dispatch).
- Out: dev shells, CUDA, Windows, image vision calibration, the pre-built engine path, the model
  weights, and every benchmark - the numbers in [AMD_HIP.md](AMD_HIP.md) and
  [DETAILS.md](DETAILS.md) were measured on the setup-built engine; a Nix-built engine of the same
  version and architectures is the same code, and nothing here claims otherwise.

Verified on this machine (16 cores, nix 2.34.8, nixpkgs 26.05): `nix build .#strata` compiles the
default three-architecture list in ~2 minutes (dependencies fetched once, this flake's compile
only), `nix run .#strata -- --help` exits 0, and the stored server - pointed at a mock engine, which
needs neither the model nor a GPU - serves `/v1/chat/completions` from the store with nothing outside
its closure:

```sh
# P = $(nix build .#strata --print-out-paths); PY = the python3 env in P's closure
(cd "$P" && "$PY/bin/python3" -m serve.server --engine mock --port 8080)
```
