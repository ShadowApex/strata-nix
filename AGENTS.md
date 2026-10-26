# Agent Instructions

## Code Guidelines

- After changing any `.nix` file, verify that the package still builds. Fix any
  errors or warnings. Iterate until the build is clean, then run `nixfmt` to
  ensure formatting is consistent.
- Do not deeply nest code. Keep it flat and easy to read where possible.
- Do not add superfluous comments. Basic doc comments are fine. Explanatory
  comments should be reserved for complex or non-intuitive logic. In those cases,
  keep comments short.
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
flake.nix                          # wires the pins together and exposes packages.* (strata, strata-tools, strata-dsv41-tools, strata-mtp and one strata-model-<family>-<size> per size) and nixosModules.strata
pkgs/by-name/st/strata/            # the engine and its assembly, in nixpkgs' by-name layout (this directory is what would move to nixpkgs)
  package.nix                      # the source pin, the build, and the config the server reads; hipArchs, model, mtp and prefillMmq are its parameters
  llama.cpp.nix                    # pinned llama.cpp, source-only store path, used as -DSTRATA_GGML_DIR and for gguf-py
pkgs/by-name/st/strata-tools/      # the pinned Strata tools tree the Flash-Next, Swift, Coder, Unsloth and Qwen36 packs and the draft-layer extract run, at its own rev
pkgs/by-name/st/strata-dsv41-tools/  # the same at 0.2.4.2, pruned to tools/dsv41 (pack_gguf.py and strata_tokenizer.py): the DeepSeek packs
pkgs/by-name/st/strata-mtp/        # the MTP draft layer: the pinned checkpoint shards plus the extract
pkgs/by-name/st/strata-model-<size>/  # one per size: the original Qwen, Gyro and DeepSeek packages keep their old directory names for pack-cache stability; Swift, Coder, Unsloth and Qwen36 use canonical family-prefixed names. Each holds its GGUF files, pack/tokenizer and family mmproj
modules/services/strata.nix        # the services.strata NixOS module (the service as a systemd unit)
README.md                          # build/run/service usage, and the layout table
```

The engine package is one output whose closure is the whole package — engine, Python server, model,
tokenizer, MTP draft layer, image encoders, ROCm runtime. It is the assembly: real content for the
Python tree the server runs from, symlinks into the store paths the stage derivations and the model and
draft-layer packages produce. With
this output layout:

```text
bin/strata            the engine (HIP)
bin/strata-dsv41      the second engine binary: DeepSeek-V4.1-Flash (src/dsv41, arch deepseek41)
bin/strata-device     the device probe (--list-devices)
bin/strata-server     the Python server wrapper
bin/strata-vision     the image encoder (llama.cpp's mtmd), on the CPU: the fallback reader
bin/strata-vision-hip the same encoder on the AMD GPU (ggml-hip), the reader the config names
bin/BUILD.json        the engine version, backend, arch list, model size and family, picture readers and
                      hipBLASLt version actually compiled
bin/tuning/           the hipBLASLt prompt tables matching that version, for the archs that have one
etc/strata/strata.json  the config the server reads
pack/<name>           the packed model and the tokenizer derived from its GGUF metadata (symlink). For a
                      DeepSeek size this is pack/maya-ds4/ and its name is setup.py's tag plus the set
models/<name>         the pinned GGUF file(s) (symlink): two shards, one Gyro file, or a DeepSeek set with
                      the Engram table and the drafter beside it
vision/               the pinned mmproj the image encoder reads (symlink); absent for a DeepSeek size
mtp/rt                the packed MTP draft layer (symlink); absent for a DeepSeek size
data/expert-profile.bin
serve/ tools/ strata_control/ strata_cli/ chat.py requirements.txt
                      the upstream Python tree, run from the store (real copies)
```

## Key Invariants

- The Strata source is **not** a flake input: the package fetches it itself with
  `fetchFromGitHub`, pinned to the tag matching `version`. A flake input named
  `strata` once shadowed the derivation built from it inside its own definition
  and recursed; do not reintroduce one.
- The tag and the engine's version are different numbers: v0.2.4 built engine 0.1.49 and v0.2.4.2 builds
  0.1.49.2, and
  `bin/BUILD.json` carries the engine's, which the assembly reads out of `CMakeLists.txt`'s
  `project(strata VERSION ...)` rather than hardcoding it. The server reads that file as the engine's
  version, and `setup.py` compares it against per-model minimums (`GYRO_ENGINE` and friends), so a
  hardcoded package version there would be wrong. setup.py reads up to four components, so the
  four-part number a Control-only hotfix stamps (v0.2.4.1 is engine 0.1.49.1 over engine sources only
  the Terminal package was missing files from) compares correctly against a three-part minimum.
  The packages pin the tag, not the newest tag: pin a hotfix only when it touches something this
  build copies. v0.2.4.1 touched only the Terminal's setup scripts, so the pin stayed at v0.2.4; v0.2.4.2
  touches `src/dsv41/ds4_gg_cpu.cpp` and the ggml-cpu feature flags (see the BMI2 note below), two of
  `serve/server.py`'s DeepSeek conversation defaults, and `tools/dsv41/pack_gguf.py`, so it is pinned.
- Payloads enter the build as `linkFarm` directories, never as bare files in
  `buildInputs`: stdenv `source`s every bare file there as a setup hook.
- `configurePhase = "true"` is deliberate. stdenv's default configure would run
  cmake with no flags and hit the network `FetchContent` for llama.cpp.
- The build is one derivation per stage so the expensive stages cache on their own. The engine stage must
  stay a `stdenv.mkDerivation` with `propagatedBuildInputs = rocmLibs`, which is what patches the RPATH; a
  `runCommand` would not.
- The pack and the draft-layer extract are not stages of the engine package at all: they live in the model
  packages and `strata-mtp`, which take a pinned `strata-tools` store path as an argument and never see the
  engine's source. Nix is input-addressed, so a stage reading `${src}/tools/iq_pack.py` re-runs the pack over
  the model data on every engine release even when the script is byte-identical. Bumping `version` in the
  engine package leaves the model drvPaths, the pack drvPath and the mtp drvPath byte-identical; only the
  engine, both readers and the assembly change. There are two tools pins because the Flash-Next-line and
  DeepSeek lines pack with different files:
  `strata-tools` (0.2.1.4) carries `tools/iq_pack.py`, `tools/gguf_reader.py`, `tools/_paths.py`, `tools/mtp_*`
  and `tools/strata_tokenizer.py` for the Flash-Next-line packs (original, Swift, Coder, Unsloth, Gyro), the
  Qwen3.6 tokenizer, and the checkpoint extract,
  `strata-dsv41-tools` (0.2.4.2) carries `tools/dsv41/pack_gguf.py`, `tools/dsv41/_paths.py` and
  `tools/strata_tokenizer.py` for the DeepSeek packs, which need no numpy. Move a pin only when the files its
  packs run change: v0.2.3 touched `tools/mtp_fetch.py` alone (OS certificates for its HTTPS fetch, #3722),
  which this build never runs over the network, so that pin stayed at 0.2.1.4 through two releases; v0.2.4
  added the `deepseek-v3` pre-tokenizer sequence to `tools/strata_tokenizer.py`, which the Flash-Next pack
  runs too, so it is a file the first pin holds — but that branch only fires for a GGUF whose pre-tokenizer
  name starts with `deepseek`, so a Qwen pack takes the same `QWEN35_PATTERN` either way and the pin stayed
  at 0.2.1.4, which keeps those packs and the checkpoint extract cached. Moving it anyway re-runs every
  Flash-Next-line pack over its model data and the ~55 GB extract for output that is byte-identical. Moving the
  first pin further also means copying `strata_control/tls.py` into that tree, because `strata_tokenizer.py`
  does not import it but the server does. v0.2.4.2 changed `tools/dsv41/pack_gguf.py` — its automatic mmproj
  find now takes only a file whose projector is `deepseek41v` (#3927) — and that is the tool the second pin
  holds, so it moved even though this build names no mmproj and the shard farms hold none, so the packs it
  produces are the ones 0.2.4 produced. That move costs a full read of every DeepSeek set.
- Since v0.2.4 the engine derivation builds two binaries: `strata` and `strata-dsv41`
  (`-DSTRATA_BUILD_DSV41=ON`, which upstream leaves OFF). Always build it — the assembly links it for every
  size, and a DeepSeek config runs it. Its vendored kernels link hipBLAS, and nixpkgs splits that header
  into `hipblas-common`: the stage passes `-I${hipblas}/include -I${hipblas-common}/include` through both
  `CMAKE_HIP_FLAGS` and `CMAKE_CXX_FLAGS` (`dsv41Includes`) — the device pass and the host pass of those
  sources both read `hipblas/hipblas.h`, and the dsv41 targets are hand-written `add_library(... OBJECT)`
  and `add_executable` sources CMake compiles without an imported target's include directories, so the path
  has to name both split outputs. `hipblas-common` is a `nativeBuildInputs` entry only: it is header-only,
  and putting it in `rocmLibs` would grow every binary's RPATH for nothing. Do not add a `-include` of
  `strata/dsv41/hip_extra.h`: since the source builds that engine itself it force-includes that header into
  both dsv41 targets for the HIP and CXX passes (`if(STRATA_ENABLE_HIP)` under the dsv41 target block), which
  is where the CUDA-name mappings come from.
- The package passes no `-march`/`-mcpu` for the CPU kernels and should not need one: `STRATA_PORTABLE=ON`
  (upstream's own `packaging/build_hip_linux.sh` passes it too) turns off ggml's `-march=native` detection,
  the AVX-512 and AVX2 kernels carry their own per-file `COMPILE_OPTIONS` and dispatch at runtime, and
  stdenv's default `-march=native` would bake the build machine into the store path. Since v0.2.4.2
  CMakeLists.txt additionally forces `GGML_BMI2` off for the DSV41 build (after the portable set, guarded on
  `STRATA_BUILD_DSV41`, which this package always turns on): ggml's `IQ1_S`/`IQ1_M` dots use `_pdep_u64` when
  the build has BMI2, AMD Zen 1/2 run PDEP in microcode — about 3× on the 2.00 set's CPU lane — and
  `src/dsv41/ds4_gg_cpu.cpp` now covers those types with Strata's own rows at every token count, bit-identically.
- The config shape differs per family, and the model package decides it through its contract (`key`, `family`,
  `expertProfile`, and for Qwen36 `arch`, `ownPath`, `mtpCount`; DeepSeek's `dsparkConf`). A DeepSeek config is
  setup.py's `install_dsv41`: `exe` at `bin/strata-dsv41`, `--pack`/`--max-context`/`--eos`/`--dspark auto`
  (plus `--dspark-conf 0.65` for an IST-DAS set), `arch deepseek41`, no `--native`, no `--ple-gguf` (the
  pack's own tensor map names every file, including the Engram table and the drafter beside the shards), no
  `vision` section and no `--vision` (that family ships no mmproj — `tools/dsv41/vision_pack.py` cuts one
  from DeepSeek's own checkpoint), and `engine_ready_s` 3600 because hundreds of GB are read before READY.
  `--rope-scale` and `--yarn` are Flash-Next only: `strata-dsv41` has no such flag, so the service writes no
  rope scaling for a `DeepSeek41_*` or `Qwen36_*` size however big its `maxContext` is.
- The service's DeepSeek switches: `engineReady` (the server's READY wait), `keepConversations` and
  `conversationSlotsGb` (`STRATA_DS4_SLOT_KEEP`/`_GB` in the config's engine `env`), and
  `autoPinSystemPrompt` (`STRATA_DS4_AUTO_PIN`, read by the server process, so it belongs in the unit's
  `Environment` rather than the engine's). The slot folder is `stateDir/ds4-slots`: the engine's own default
  is `ds4-slots` beside the pack, and `$out/pack` is a read-only symlink into the model package. The two
  switches default to what `serve/server.py` writes: both were off in v0.2.4 and both are on since v0.2.4.2,
  so the module keeps them null and says so rather than hardcoding a value upstream moves.
- `--dump-logits` and the parity tests in `tools/dsv41/` (smoke, bench) need the model and a card; nothing in
  this repository runs them.
- The assembly keeps `serve/` and `tools/` as real copies: `serve/server.py` takes
  `Path(__file__).resolve().parents[1]` as its root, so a symlinked `serve/` would point it at the wrong
  store path. Only the payloads are links, and the closure still contains them. Since 0.2.0 the server
  also imports `strata_control/` (`vision_reader`, `procs`, `engine_component`, `offline`) and, through
  it, `strata_cli/`, so both are copied too; only the terminal's dashboards want `rich`/`textual`, which
  the server never imports, so the Python environment stays six packages (jinja2, regex, psutil, pillow,
  jsonschema, which `serve/structured.py` needs to actually validate a request's `response_format`, and
  truststore since 0.2.3, which `strata_control/tls.py` installs so an HTTPS picture or tool URL is checked
  against the host's CA store).
- Store paths inside generated files must be real dependencies, not text. The
  package substitutes `@OUT@`/`@PY@` with `sed`; the service module builds its
  config with `runCommand` (a string read from the store at eval time carries no
  context and cannot be written back out).
- `etc/strata/strata.json` is read with plain `json.loads`, so nothing in it may
  be a comment; the explanation of the `vision` section lives in the Nix source.
- Images need both halves of the config, as `setup.py` writes them: the `vision` section makes the server
  spawn the encoder, and `--vision` in `args` is what makes the engine accept the `GENI` requests it sends.
  The server passes the config's `args` unchanged, so the flag belongs in the package's file.
- Since v0.2.0 the AMD backend has two picture readers, and the package ships both: `tools/vision` built
  plain (`bin/strata-vision`, CPU) and built with `-DSTRATA_VISION_HIP=ON
  -DSTRATA_VISION_HIP_ARCHS="<the same target list>"` (`bin/strata-vision-hip`). The config names the GPU
  one as `exe` with the CPU one as `cpu_exe`, which is what `setup.py` writes for a card of 24 GB or more;
  `serve/vision_reader.py` falls back to the CPU reader when the GPU one cannot start, and `BUILD.json`'s
  `vision_archs` is how it knows the card is not covered. Both are the second CMake project, built against
  the llama.cpp store path with `-DLLAMA_DIR=` and `MTMD_VIDEO=OFF` (the server sends still images only,
  so it needs no ffmpeg). Its `model` is shard 1 with shard 2 beside it under the original names, which is
  how llama.cpp resolves a split GGUF.
- The GPU reader's stage is the one stage that needs `rocm.rocblas`: llama.cpp's `ggml-hip` does
  `find_package(rocblas REQUIRED)` and links it (791 MB in the closure). The engine stage still omits it —
  its CMakeLists finds it only for the gfx103x solution table and treats "not found" as a status.
- nixpkgs has no single `/opt/rocm` prefix: each ROCm package is its own store
  path, found through `CMAKE_PREFIX_PATH`, and the HIP compiler is
  `rocm.clr/bin/amdclang++`.
- Since v0.2.1 an AMD engine package carries hipBLASLt prompt tables, and the assembly stages them with the
  source's own `packaging/stage_tuning.py`: it reads the hipBLASLt version out of the headers it builds
  against (`${rocm.hipblaslt}`), copies `tools/hip/<arch>-hipblaslt-<version>.txt` for the target archs into
  `bin/tuning/`, and writes that version to `BUILD.json` as `hipblaslt_version`. Do not hand-copy the
  tables: a table's solution ids are valid for one architecture family and one hipBLASLt version, and the
  engine refuses a mismatch. nixpkgs' hipBLASLt is 1.2.2 (100202), which has tables for gfx1100 and gfx1201
  and none for gfx1151 (those need 1.4 or 1.5), so the default target keeps plain hipBLAS. The server looks
  for `tuning/` only for a config whose `exe` is `component:strata-engine`, which this package does not use,
  so `bin/strata-server` asks `strata_control/hipblaslt_tuning.py` which table fits the card it finds and
  exports `STRATA_HIPBLASLT_TUNING`. It stays off unless the run config says `"hipblaslt_table": true`
  (`services.strata.hipblasltTable` writes it; a `STRATA_HIPBLASLT_TABLE` environment switch overrides the
  config), because a table changes the prompt's floating-point sums. Since engine 0.1.48 the engine also
  searches for `tuning/` beside the executable it was started as (`/proc/self/exe`), and takes a table that
  fits unless told otherwise — keep the tables out of the engine derivation: `bin/strata` is a symlink, so
  that search resolves to the engine stage, and staging tables there would silently turn the opt-in on.
- `hipArchs`, `model`, `mtp` and `prefillMmq` are the caller-visible knobs. `hipArchs` is a list (or a `;`-joined string). It
  is validated by the source's own `cmake/hip_backend.cmake` — gfx1100/gfx1201 by the maintainers,
  gfx1101/gfx1200 by their owners, the rest (the default `gfx1151` included) build with a warning —
  and is recorded in `bin/BUILD.json`. Nothing patches that file: the arch list this repository used to
  carry in `hip_backend.patch` landed upstream in `v0.1.40`.
- `prefillMmq` is the GGML MMQ prompt path (`-DSTRATA_PREFILL_MMQ`, ON here against upstream's OFF default;
  it requires HIP, which this package always enables). It reaches the engine stage alone, so flipping it
  rebuilds the engine and the assembly, not the pack, the encoder or the draft layer, and it is recorded in
  `bin/BUILD.json` as `prefill_mmq`.
- Each size is its own by-name package. `services.strata.model` is a canonical family-prefixed string
  (`"Qwen_IQ3_S"`) and the module maps it to a model package; the old names (`IQ3_S`, `Gyro-S`, `DSV41_*`)
  remain accepted aliases that evaluate with a deprecation warning. The engine package takes a model
  *package*, never a string, because a by-name package may only use its function arguments and cannot go
  looking for its siblings. Each model package carries its own pins and its own pack derivation
  (`strata-pack-<pack>`, one name per size so the caches do not collide) and exposes `passthru.strata` as the
  contract the assembly reads: `key` (the canonical name; existing packages add it while keeping `size` and the
  shard-farm name unchanged so their packs stay cached), `size`, `packName`, `modelName`, `minEngine`, `ram`,
  `download`, `memoryNote`, `shard1`, `ple`, `mmprojName`, and the `shards`/`pack`/`mmprojDir` store paths,
  plus `family`, the Flash-Next `expertProfile`, and the Qwen36 `arch`, `ownPath` and `mtpCount`. A model
  package with no `family` is a Flash-Next one. The assembly links `${model}/shards`, `${model}/pack`,
  `${model}/mmproj` and `${mtp}` (the last two absent when the model has no `mmprojName` or `mmprojDir`), and
  fails the build when the engine is older than `minEngine` (setup.py's `MIN_ENGINE` and `GYRO_ENGINE`). It
  refuses an `mtp` beside a DeepSeek or Qwen36 model rather than fetching the 55 GB checkpoint extract those
  engine paths never read, and takes `data/<expertProfile or expert-profile.bin>` from the engine source.
  Switching size rebuilds the assembly alone: the engine, both encoders and the draft layer stay cached.
- What differs between the model lines is written in each model package, mirroring `setup.py`'s
  `FAMILIES`/`MODELS`/`MULTI_FILE_FAMILIES`/`OWN_PATH_FAMILIES`: the repository and its pinned revision, the
  published file names, the shard count, the `model_name` prefix, and any extra pack flag. It repeats per file
  rather than living in one shared table because a `by-name` package may only use its function arguments; the
  mmproj pin repeats the same way and collapses to one store path. The original and Coder shard 2 is
  byte-identical in every GSQ-RCO size (the PLE table alone); Swift's shard 1 holds the PLE table and shard 2
  the later layers, so its `ple` points at shard 1. Unsloth's 3/4/6-shard files pass `--compat-bf16` and set
  `ple = null`, so the assembly omits `--ple-gguf` and lets the engine find the PLE shard from shard 1. The
  Coder keeps half the experts and names `expert-profile-coder.bin`; Swift uses its own 2 shards and mmproj.
  Gyro (agentionai's trellis TQ quants) is one GGUF that holds the n-gram table, so `--ple-gguf` points at the
  same file as `--native`, its pack needs `--compat-bf16`, and its `experts.bin` is marked v5 with a
  `hadamard.txt` beside it (Hadamard-folded experts an older engine would read as noise). Its mmproj is the
  GSQ-RCO one, pinned once for both families. The trellis MMQ prompt kernels come from
  `cmake/strata_ggml_tq_overlay.cmake`, which writes an overlay of the pinned llama.cpp's ggml-cuda headers at
  configure time; `STRATA_MMQ_TQ_OVERLAY` is ON upstream and this package leaves it at its default.
- Qwen3.6-35B-A3B is the own-path line: `strata` switches to `src/qwen35` from the GGUF architecture, reads
  the file directly, drafts from its own MTP block (`--mtp 2`), and needs only the tokenizer in `pack/`. Its
  config carries no `--pack`, `--expert-profile`, `--ple-gguf` or MTP path, and the module gives it no rope
  scaling and no `strata-mtp`. It uses the same `strata` binary, so no extra CMake target is built.
- DeepSeek-V4.1-Flash is the `strata-dsv41` line: four shards per set plus three files every set shares — the
  110.6 GB
  Engram table, the 8 GB DSpark drafter and shard 1 of Unsloth's UD-Q8_K_XL set, of which only the GGUF
  metadata is read (the Engram table is written as MXFP4 for the 2-bit sets, whose shards do not hold it).
  Nothing is copied into the pack: `pack_gguf.py` records offsets into the files beside it, so the pack is a
  few MB and the shard farm must carry the shared files under their published names. The three IST-DAS sets
  share those files, so they collapse to three store paths; the Unsloth set pins its own nine shards. Its
  pack derivation is `strata-pack-dsv41-<set>` (one name per set: each reads different shards), and the pack
  folder inside the model package is `maya-ds4/`, which is what setup.py names it — one folder for every set,
  so the derivation keeps the set's name and `packName` carries both.
- `llama.cpp.nix` is `import`ed directly by the engine package, the flake and the service module. That is
  fine here, but a nixpkgs `by-name` package may only use its function arguments, so it would have to
  become its own `by-name` entry to be upstreamed. `strata-tools`, `strata-mtp` and the model packages
  already follow that rule: they take `strataTools` and `strataLlamaCpp` as arguments, which the flake and
  the module pass in.
- The model and draft-layer packages carry `unfreeRedistributable` meta (the Qwen Community License, and
  DeepSeek's model license for the `ds4-*` packages), so anything building them needs unfree allowed; this
  flake imports nixpkgs with `config.allowUnfree = true` and a consumer's configuration needs the same. The
  engine, the readers and the tools pins stay MIT.
- The output is read-only: the service can write only to `services.strata.stateDir`
  (`/var/lib/strata`). The GPU is reached through the kernel driver, so the unit
  keeps `/dev/kfd` and `/dev/dri` visible (no `PrivateDevices`), needs the
  `render`/`video` groups and unlimited memlock, and has no start timeout.
- `x86_64-linux` only: the flake defines no other system and the package's
  `platforms` say so.

## Commands

```sh
nix build .#strata                 # ~2 min compile; ~120 GB of pinned downloads on a cold cache
nix build .#strata.passthru.engine # the compile stages alone (also .vision, .visionHip): no model downloads
nix build .#strata --dry-run       # does this change invalidate the derivation? (nothing printed = cached)
nix run .#strata -- --help         # the engine's usage, from the store (no GPU needed)
nix flake check --no-build         # eval only: checks the derivation and the NixOS module

# the server's own plumbing without a GPU or a model: --engine mock answers from the config's tokenizer
nix shell .#strata --command strata-server --engine mock --port 8321
```

Plain `nix flake check` builds the package, so use `--no-build` for the quick
check.

A change to a model package's recipe re-runs its pack over its model data (a DeepSeek pack also reads through
its set's shards and the shared 110 GB Engram table, and needs that table downloaded first); a
change to a pin re-downloads. An engine release touches neither: the pack and the
extract run the tools pins, and you move a pin only when the files its packs run change, which re-runs the
packs of that line and the checkpoint extract once. Check with `--dry-run` before starting a rebuild.

```sh
# another card: hipArchs is a callPackage parameter of the engine package. Use the flake's locked nixpkgs, not
# <nixpkgs>: another nixpkgs means another ROCm and hipBLASLt, and a table is valid for one version only.
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = p.strata-model-qwen-iq2-xs; mtp = p.strata-mtp; }'

# another model size: the payload alone (its downloads and its pack, no engine), then assemble over it
nix build .#strata-model-qwen-iq3-s
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = p.strata-model-qwen-iq3-s; mtp = p.strata-mtp; }'

# a DeepSeek size: its own pack, and no draft layer (the package refuses one)
nix build .#strata-model-deepseek41-iq1-m
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = p.strata-model-deepseek41-iq1-m; mtp = null; }'

# a Qwen3.6 size: its own GGUF path, tokenizer-only pack, and no MTP package
nix build .#strata-model-qwen36-ud-q4-k-xl
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = p.strata-model-qwen36-ud-q4-k-xl; mtp = null; }'

# re-pin a hash after changing a pin
nix-prefetch-url --unpack https://github.com/Niko1221/Strata/archive/v<version>.tar.gz

# formatting
nix shell nixpkgs#nixfmt --command nixfmt flake.nix pkgs/by-name/st/strata/package.nix
```

There are no tests or CI in this repository. The NixOS module is exercised by
evaluating it in a consumer flake (`nixosModules.strata` +
`services.strata.enable = true`); runtime behaviour needs a real AMD card.
