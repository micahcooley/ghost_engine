# Ghost Engine: Mathematical Foundations

The Ghost Engine is built on the mathematics of **High-Dimensional Vector Space Alignment** (VSA).

## 1. HyperVector Resonance
We operate in a 1024-dimensional bitspace. Meaning is not stored in values, but in the **Hamming Distance** between vectors. 
*   **Nearness**: A Hamming distance < 400 indicates semantic resonance.
*   **Void**: A Hamming distance > 600 indicates semantic orthogonality.

## 2. The Majority Rule (Bundling)
To "memorize" multiple vectors into a single point in the matrix, we use a bitwise Majority Rule:
1.  Align N vectors.
2.  For each bit position, if more than 50% of the vectors have a `1`, the resulting bit is `1`.
3.  This creates a "composite" vector that retains a high degree of resonance with all its constituent parts.

## 3. Threshold Recurrent Phase-Change (TRP)
The engine detects "meaning" by monitoring the flux of resonance. When a new input causes the lattice to shift beyond a deterministic threshold, a **Phase-Change** is triggered, resulting in the "etching" of a new sigil.

## 4. No-Float Determinism
By using only bitwise operations, the engine achieves **Absolute Determinism**. The same input will always produce the exact same resonance across any hardware that supports the standard VSA instruction set.

## 5. DETERMINISM & RESONANCE SAFETY
The mathematical core of Ghost is **fragile by design**. Any divergence in how bitwise logic is applied will lead to catastrophic semantic decay:
*   **The No-Float Mandate**: Never introduce floating-point math (`f32`, `f64`) into `vsa_core.zig` or `src/shaders/`. Even a single rounding error will destroy the engine's bit-perfect determinism across different hardware architectures.
*   **Resonance Thresholds**: The **Hamming Distance** thresholds (< 400 for near, > 600 for void) are calibrated for 1024-bit bitspace. Modifying these in `src/config.zig` or `src/vsa_core.zig` will fundamentally change the engine's "perception." If tuned incorrectly, the engine will either "flatline" (perceive all input as noise) or "hallucinate" (resonate with everything).
*   **Vector Bundling (Majority Rule)**: The Majority Rule implementation (a & b) | (b & c) | (c & a) is the engine's only way to "memorize." Any change to how bitwise bundling is handled in the GPU kernels will result in a state that the CPU cannot interpret correctly.

