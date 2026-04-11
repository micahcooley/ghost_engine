# Ghost Engine

**Sovereign intelligence for every silicon, owned by no one but you.**

Ghost Engine is a bitwise inference engine that runs on your hardware, your terms. No cloud. No API keys. No floating-point non-determinism. Just deterministic, hardware-native intelligence on whatever machine you have — Windows, Linux, macOS. x86_64, ARM64. Your silicon, your ghost.

## Why Ghost Exists

Most AI systems require you to trust someone else's infrastructure. Ghost doesn't.

- **No cloud.** Runs entirely local. Your data never leaves your machine.
- **No floats.** All computation is bitwise (XOR, POPCNT, majority rule). Same input, same output, every time, on every platform. No rounding errors, no GPU nondeterminism.
- **No vendor lock-in.** Cross-platform by design. The engine adapts to your OS and architecture, not the other way around.
- **No black box.** Every resonance, every lattice state, is inspectable. You can see what the engine knows and why it generates what it generates.

## The No-Float Philosophy

Ghost operates in a 1024-bit HyperVector space. Meaning lives in **Hamming distance** between vectors, not in floating-point weights. This means:

- Bit-perfect reproducibility across all hardware
- No GPU-specific numerical drift
- Training and inference are the same operation — there is no separate "model file"
- The lattice is the model. It's always live, always updating, always yours.

## Getting Started

No global installs required. The forge provides everything.

### 1. Bootstrap the toolchain

```powershell
.\sylor_forge.ps1
```

Downloads Zig and Vulkan SDK into `.toolchain/`. No system pollution.

### 2. Seed the state (~2.1 GB)

```powershell
.\tools\seed_lattice.ps1
```

Creates the lattice, meaning matrix, and tag store — tabula rasa, ready to learn.

### 3. Build

```powershell
$env:PATH = "$(Get-Location)\.toolchain\zig;" + $env:PATH
$env:VULKAN_SDK = "$(Get-Location)\.toolchain\Vulkan"

zig build -Doptimize=ReleaseFast
```

Two binaries come out: `ghost_sovereign` (inference REPL) and `ohl_trainer` (training pipeline).

### 4. Teach it

```powershell
cp zig-out/bin/ohl_trainer.exe platforms/windows/x86_64/bin/
cd platforms/windows/x86_64
.\bin\ohl_trainer.exe corpus\your_text.txt --standard
```

The trainer ingests your text and etches meaning directly into the lattice. No epochs, no loss curves, no checkpoint files. The lattice is always current.

### 5. Talk to it

```powershell
.\bin\ghost_sovereign.exe
```

Interactive REPL. Type, it resonates. Every response is generated from the live lattice state.

## Architecture

```
src/
  ghost.zig          -- Module root
  vsa_core.zig       -- HyperVector, MeaningMatrix, Panopticon
  ghost_state.zig    -- GhostSoul, UnifiedLattice, StreamState
  engine.zig         -- SingularityEngine (inference topology)
  trainer.zig        -- OHL trainer with 4-tier transmission
  vsa_vulkan.zig     -- Vulkan compute engine
  sigil_core.zig     -- Sigil parsing and etching
  compute_api.zig    -- GPU abstraction layer
  sys/               -- Platform abstraction (Windows, Linux, macOS)
  shaders/           -- Vulkan SPIR-V compute kernels
```

The engine maps ~2.1 GB of state into process memory (lattice + meaning matrix + tags). Training and inference share this memory zero-copy — what the trainer learns, the inference engine sees immediately. No serialization, no save steps.

## The 4-Tier Operational System

The trainer adapts to your hardware and needs:

| Tier | Flag | Throughput | Profile |
|------|------|-----------|---------|
| Max | `--max` | 4096 batch, 4 streams | Full saturation |
| High | `--high` | 2048 batch, 2 streams | High flow |
| Standard | `--standard` | 1024 batch, 1 stream | Nominal (default) |
| Background | `--background` | 512 batch, throttled | Stealth / shared machine |

## Roadmap

- [ ] Linux and macOS runtime support (source already cross-platform via `src/sys/`)
- [ ] ARM64 native builds
- [ ] Agents (see `AGENTS_SPEC.md`)
- [ ] Sigil scripting for memory surgery
- [ ] Plugin hot-loading for custom compute kernels

## Pre-flight Checklist

- [ ] Run `.\sylor_forge.ps1`
- [ ] Run `.\tools\seed_lattice.ps1`
- [ ] Verify Vulkan drivers are current
- [ ] `zig build` from project root

## License

See [LICENSE](LICENSE).

---

**SylorLabs — Sovereign AI for the Silicon Era.**
