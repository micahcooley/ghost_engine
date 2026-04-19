# Ghost Engine Architectural Guide: The Sovereign Monolith

This guide outlines the structural philosophy of Ghost Engine V27.

## 1. The Ternary State-Space Model (TSSM)
Unlike traditional neural networks, the Ghost Engine does not use weights in the classical sense. It utilizes a **Meaning Matrix**—a sparse, recurrent lattice where 1024-bit HyperVectors resonate to form semantic boundaries.

## 2. Hardware-Native System Layer
The engine bypasses standard OS file buffering to achieve maximum NVMe throughput.
*   **Sector Alignment**: All I/O is performed in 4096-byte blocks to match hardware physical sectors.
*   **Mapped Memory Consistency**: The ~2.1 GB semantic state is mapped into process memory via platform-native APIs (`CreateFileMapping`/`MapViewOfFile` on Windows, `mmap` on Linux/macOS). This allows multiple processes (Trainer, Core, Bridge) to access the same intelligence simultaneously.

## 3. Unified Source Structure
All source code lives at the project root:
*   **`src/`**: Core modules (`vsa_core`, `ghost_state`, `engine`, `trainer`, `vsa_vulkan`, `sigil_core`)
*   **`src/shaders/`**: Vulkan SPIR-V compute shaders
*   **`src/sys/`**: Platform abstraction layer (`windows.zig`, `linux.zig`)
*   **`build.zig`**: Single build definition for all targets
*   **`platforms/windows/x86_64/`**: Runtime only (binaries, state, corpus)

## 4. The No-Float Philosophy
All calculations are performed using bitwise logic (XOR, POPCNT, Majority Rule). This eliminates rounding errors, overflows, and the non-deterministic nature of floating-point arithmetic, resulting in a perfectly stable, recurrent fractal state.

## 5. Silicon Fragility: Memory & Alignment
Ghost Engine is optimized for **zero-copy hardware saturation**. This makes several components extremely sensitive:
*   **Memory Mapping (The Cortex)**: The ~2.1 GB semantic state is memory-mapped via native APIs (`MapViewOfFile`/`mmap`). **Fragility**: Any change to `src/config.zig` that alters the `TOTAL_STATE_BYTES` or shifts the offsets of `UnifiedLattice` and `MeaningMatrix` will render the existing `state/*.bin` files incompatible or cause immediate segfaults.
*   **Bit-Perfect Parity**: The CPU code in `src/vsa_core.zig` and the Vulkan SPIR-V kernels in `src/shaders/` MUST be 100% identical in their bitwise behavior. **Fragility**: If the GPU implementation of `Majority Rule` or `POPCNT` differs from the CPU version, the engine will "split," where the Trainer and Inference engine effectively live in different realities.
*   **Sector Alignment**: All I/O is performed in **4096-byte blocks** to match hardware sectors. **Fragility**: Breaking this alignment in `src/sys/` will lead to fatal I/O errors and state corruption.

