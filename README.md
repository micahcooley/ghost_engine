# Ghost Engine V27: Sovereign Bitwise Intelligence

The Ghost Engine is a high-performance, hardware-native implementation of a **Ternary State-Space Model (TSSM)**. Centered on the "No-Float Philosophy," it operates entirely on bitwise resonance within a 1024-bit HyperVector space.

## Architecture

The project is built from a unified root:
- **`src/`** — All source code (single source of truth)
- **`build.zig`** — Unified build for all targets
- **`src/shaders/`** — Vulkan SPIR-V compute shaders
- **`platforms/windows/x86_64/`** — Runtime artifacts only (binaries, state, corpus)

## Quick Start (Windows x86_64)

No global installs required. The forge provides a hermetic toolchain.

1. **Initialize the Forge**:
    ```powershell
    .\sylor_forge.ps1
    ```
    *Downloads Zig 0.13.0 and portable Vulkan SDK into `.toolchain/`.*

2. **Seed the State** (~2.1 GB total):
    ```powershell
    .\tools\seed_lattice.ps1
    ```
    *Creates `unified_lattice.bin` (1 GB), `semantic_monolith.bin` (1 GB), and `semantic_tags.bin` (8 MB).*

3. **Build from Root**:
    ```powershell
    $env:PATH = "$(Get-Location)\.toolchain\zig;" + $env:PATH
    $env:VULKAN_SDK = "$(Get-Location)\.toolchain\Vulkan"

    zig build -Doptimize=ReleaseFast
    ```

4. **Run the Trainer**:
    ```powershell
    cp zig-out/bin/ohl_trainer.exe platforms/windows/x86_64/bin/
    cd platforms/windows/x86_64
    .\bin\ohl_trainer.exe corpus\wikitext.txt --standard
    ```

5. **Run Inference**:
    ```powershell
    cp zig-out/bin/ghost_sovereign.exe platforms/windows/x86_64/bin/
    cd platforms/windows/x86_64
    .\bin\ghost_sovereign.exe
    ```

## Core Principles

1. **No-Float Navigation**: Intelligence via bitwise resonance (Hamming distance, majority-rule bundling). Zero floating-point non-determinism.
2. **Silicon-Native I/O**: Direct NVMe bypass via `SetFilePointerEx` and sector-aligned 4096-byte I/O.
3. **Holographic Monolith**: ~2.1 GB mapped-memory lattice for zero-copy training visible to concurrent inference threads.

## Pre-flight Checklist

- [ ] Run `.\sylor_forge.ps1` to ensure environment consistency.
- [ ] Run `.\tools\seed_lattice.ps1` to initialize state files.
- [ ] Verify Vulkan drivers are up to date.
- [ ] `zig build` from project root before contributing.

---
**SylorLabs: Sovereign AI for the x86 Silicon Era.**
