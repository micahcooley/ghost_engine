# Ghost Engine V22: Sovereign Bitwise Intelligence

The Ghost Engine is a high-performance, hardware-native implementation of a **Ternary State-Space Model (TSSM)**. Centered on the "No-Float Philosophy," it operates entirely on bitwise resonance within a 1024-bit HyperVector space.

## 🏗 Sovereign Architecture (Silo Infrastructure)

The codebase is decentralized into self-contained platform silos to ensure zero-friction portability and execution isolation.

*   **`platforms/windows/x86_64/`**: The localized Windows production environment. Contains its own binaries, local model state (`state/`), training data (`corpus/`), and specialized plugins.
*   **`platforms/linux/`**: (Roadmap) Isolated Linux runtime context.
*   **`platforms/macos/`**: (Roadmap) Isolated macOS runtime context.

## 🚀 Collaborator-Zero Quick Start

To clone and run the engine on Windows x86_64 without any global installations (no Zig or Vulkan SDK required):

1.  **Initialize the Forge**:
    ```powershell
    .\sylor_forge.ps1
    ```
    *This downloads the hermetic Zig 0.13.0 toolchain and portable Vulkan SDK into `.toolchain/`.*

2.  **Seed the Lattice**:
    ```powershell
    .\tools\seed_lattice.ps1
    ```
    *This initializes the 1GB holographic state files or downloads the 'Genesis' seed.*

3.  **Build the Release**:
    ```powershell
    # Add toolchain to path temporarily
    $env:PATH = "$(Get-Location)\.toolchain\zig;" + $env:PATH
    $env:VULKAN_SDK = "$(Get-Location)\.toolchain\Vulkan"
    
    cd platforms/windows
    zig build release -Doptimize=ReleaseFast
    ```

4.  **Ignite the Trainer**:
    ```powershell
    cd x86_64/bin
    .\ohl_trainer.exe ..\corpus\wikitext.txt --standard
    ```

## 🧠 Core Principles

1.  **No-Float Navigation**: Intelligence is derived from bitwise resonance (Hamming distance and bitwise bundling), eliminating floating-point non-determinism.
2.  **Silicon-Native I/O**: Direct NVMe bypass via `SetFilePointerEx` and sector-aligned 4096-byte I/O ensures the storage bottleneck is removed.
3.  **Holographic Monolith**: A 1GB shared-memory lattice serves as the engine's hippocampus, allowing real-time, zero-copy training visible to multiple inference threads simultaneously.

## 🛠 Pre-flight Checklist

*   [ ] Run `.\sylor_forge.ps1` to ensure environment consistency.
*   [ ] Ensure `state/unified_lattice.bin` is initialized via `seed_lattice.ps1`.
*   [ ] Verify Vulkan drivers are up to date for the `Sovereign Compute Provider`.
*   [ ] Perform a `zig build test` in the platform directory before contributing core logic.

---
**SylorLabs: Sovereign AI for the x86 Silicon Era.**
