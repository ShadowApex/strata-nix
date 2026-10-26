# strata-nix

A Nix flake that builds [Strata](https://github.com/Niko1221/Strata) — an OpenAI- and
Anthropic-compatible model server that runs a large MoE model on one AMD GPU plus system RAM.
Every model download is hash-pinned, so the build is reproducible and fetches nothing at
configure time.

Requires Linux `x86_64`, Nix with flakes enabled, an AMD GPU (default HIP targets:
`gfx1100`, `gfx1151`, `gfx1201`), and the disk and RAM listed in the model table below.

The model files are mostly under the Qwen Community License, so building those needs unfree
packages allowed. Swift 1.5 uses the Swift Open License, Qwen3.6 is Apache 2.0, and the
DeepSeek sets use DeepSeek's model license. This flake allows unfree for itself; your own
configuration needs `nixpkgs.config.allowUnfree = true`. The engine and its tools stay MIT.

## Models

Each size is a package of its own (`strata-model-<family>-<size>`): its GGUF files, the pack
and tokenizer cut from them, and the image encoder for the family. `nix build
.#strata-model-qwen-iq3-s` builds that payload alone — downloads and pack, no engine — which
is how to warm the cache before switching a machine over. The default size is `Qwen_IQ2_XS`.

Canonical names are family-prefixed. The old names (`Q2_0`, `IQ2_XS`, `IQ3_XXS`, `IQ3_S`,
`Gyro-S`, `Gyro-M`, `DSV41_*`) are deprecated aliases: they still work in
`services.strata.model`, with an evaluation warning.

**Qwen3.8-Flash-Next**

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Qwen_Q2_0` | 66.4 GB | 48 GB RAM | 2-bit, the fastest |
| `Qwen_IQ2_XS` | 68.0 GB | 48 GB RAM | 2-bit i-quant, a little better quality, close in speed |
| `Qwen_IQ3_XXS` | 75.8 GB | 60 GB RAM | 3-bit i-quant, better quality, slower |
| `Qwen_IQ3_S` | 83.6 GB | 62 GB RAM | 3.5-bit, the best quality, the slowest; wants a 64 GB PC |

**Swift 1.5** — a fine-tune that thinks for less time before answering; same RAM as the
matching original size.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Swift_IQ2_XS` | 68.0 GB | 48 GB RAM | 2-bit i-quant |
| `Swift_IQ3_XXS` | 75.8 GB | 60 GB RAM | 3-bit i-quant |
| `Swift_IQ3_S` | 83.6 GB | 62 GB RAM | 3.5-bit |

**Coder** — half the experts, kept for code, tools and images.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Coder_IQ1_M` | 58.4 GB | 32 GB RAM | weaker outside coding |

**Unsloth Dynamic** — 3/4/6-shard GGUFs with `--compat-bf16`; below the all-in-RAM figure,
part of the experts is read from the SSD.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Unsloth_UD_IQ4_XS` | 93.7 GB | 48 GB RAM | all experts in RAM from about 80 GB |
| `Unsloth_UD_Q4_K_XL` | 111.3 GB | 48 GB RAM | all experts in RAM from about 94 GB |
| `Unsloth_UD_Q5_K_XL` | 158.3 GB | 108 GB RAM | Q5_K experts |
| `Unsloth_UD_Q6_K_XL` | 169.2 GB | 118 GB RAM | Q6_K experts |
| `Unsloth_Q8_0` | 188.2 GB | 136 GB RAM | the reference quality |

**Gyro** — trellis quantizations; memory is GPU and system RAM together.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Gyro_S` | 58.5 GB | 27.6 GB GPU+RAM | TQ1_0, the smallest; lower quality than the 2-bit sizes |
| `Gyro_M` | 92.0 GB | 35 GB GPU+RAM | TQ2_0, about IQ3_XXS quality in ~20% less memory |

**Qwen3.6-35B-A3B** — its own engine path, reads the GGUF directly, drafts from the MTP block
inside it, and serves pictures.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Qwen36_UD_Q4_K_XL` | 22.9 GB | 32 GB RAM | 4-bit, the smallest |
| `Qwen36_UD_Q6_K_XL` | 32.6 GB | 44 GB RAM | 6-bit, closer to the full model |
| `Qwen36_Q8_0` | 37.8 GB | 52 GB RAM | 8-bit, the closest to the full model |

**DeepSeek-V4.1-Flash** — a different engine binary (`bin/strata-dsv41`), four shards, a
110 GB n-gram table read from disk, and no picture reader.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `DeepSeek41_IQ1_M` | 239.0 GB | 34 GB RAM | IST-DAS 1.75 bpw: code and agent work, weaker prose |
| `DeepSeek41_IQ2_XXS` | 256.8 GB | 40 GB RAM | IST-DAS 2.00 bpw: ~5-7 tokens a second on a 12 GB card |
| `DeepSeek41_IQ2_XS` | 274.0 GB | 44 GB RAM | IST-DAS 2.25 bpw: the best of the three |
| `DeepSeek41_UD_Q8_K_XL` | 508.4 GB | 306 GB RAM | Unsloth Dynamic 8-bit: wants hundreds of GB of RAM or several cards |

## Build and run

```sh
nix build .#strata                        # ~2 minutes of compile; downloads fetched once
nix run .#strata -- --help                # the engine's usage, from the store
nix shell .#strata --command strata-server  # OpenAI + Anthropic APIs on 127.0.0.1:8080
curl http://127.0.0.1:8080/health         # from another shell
```

`strata-server` forwards remaining flags to the server (`--port`, `--host`, `--api-key`,
`--gpu 0,1`, `--config <file>`):

```sh
nix shell .#strata --command strata-server --port 9000 --host 0.0.0.0 --api-key <a long random secret>
```

Serving other devices needs `--host 0.0.0.0` **together with** `--api-key`. If a card is not
found, run `nix shell .#strata --command strata-device --list-devices` to see what the machine
exposes.

For another card or size, pass the engine package's `callPackage` parameters — `hipArchs`,
`model` (a model package), `mtp` (`null` for a `DeepSeek41_*` or `Qwen36_*` model) and
`prefillMmq`:

```sh
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = p.strata-model-qwen-iq3-s; mtp = p.strata-mtp; }'
```

Use the flake's locked nixpkgs, not `<nixpkgs>`: another nixpkgs means another ROCm.

## NixOS service

```nix
{
  inputs.strata-nix.url = "github:ShadowApex/strata-nix";
  outputs = { self, nixpkgs, strata-nix }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata-nix.nixosModules.strata
        {
          services.strata.enable = true;
          services.strata.hipArchs = [ "gfx1100" "gfx1151" "gfx1201" ];  # the card in the machine
          services.strata.model = "Qwen_IQ3_S";                          # a size from the table above
          services.strata.apiKey = "a long random secret";               # or null + environment.STRATA_API_KEY
        };
      ];
    };
  };
}
```

The unit runs as the `strata` user with the `render` and `video` groups, keeps `/dev/kfd` and
`/dev/dri` visible, allows unlimited memlock, and has no start timeout — loading the model takes
minutes. Its working directory, `/var/lib/strata` (`services.strata.stateDir`), is the only
writable place. Other useful options: `services.strata.package` (any assembled package),
`services.strata.maxContext`, `services.strata.port`/`host`, `services.strata.gpu` or
`services.strata.gpuRoles`, `services.strata.env` for anything else the engine reads from the
environment, and `services.strata.extraConfig` for the config the server reads.

For engine flags the module does not model, append them without replacing the package's
arguments:

```nix
services.strata.extraEngineArgs = [
  "--vram-reserve-mib" "2048"  # Flash-Next, Swift, Coder, Unsloth and Gyro
];
```

`services.strata.engineArgs` still replaces the whole list when you need to remove a flag; the
VRAM knobs differ by family (`--expert-vram` for Qwen3.6, `--reserve-mib` for DeepSeek-V4.1).
