# Ghost Engine: Modding & Sigil Scripting

The Ghost Engine is fully extensible via the **Sigil** language and a binary plugin system.

## 1. Sigil Scripting
Sigil is a deterministic, low-level language designed for "Memory Surgery."
*   **Location**: Move your `.sgl` scripts into the `platforms/<os>/<arch>/sigil/` folder.
*   **Execution**: The engine automatically scans this folder upon ignition and etches valid sigils into the lattice.

## 2. Binary Plugins
Advanced behaviors (like custom GPU kernels) can be added as binary plugins.
*   **Path**: Place your compiled `.dll` or `.so` files into `platforms/<os>/<arch>/plugins/`.
*   **Hot-Loading**: The engine supports real-time plugin injection if the `trainer.lock` is not active.

## 3. Creating Custom Shaders
The Vulkan compute pipeline can be extended by adding new `.comp` files to `platforms/shared/src/shaders/`.
*   **Rebuild**: After adding a shader, run `zig build` from the `platforms/shared/` directory to compile them into SPIR-V.
