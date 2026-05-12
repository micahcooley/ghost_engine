# Architecture Phase 2

Phase 2 adds three bounded infrastructure seams. GPU search can narrow a GRE
rune set, but CPU-side verification remains the only authority path.

## VSA Hypervectors

`src/vsa/hypervector.zig` defines 1024-bit binary hypervectors as 16 `u64`
lanes. Binding is XOR. Bundling is majority vote, with a fast three-vector
majority path and a slice-based deterministic majority path. Similarity is
reported as `f32` in the closed range `0.0...1.0`.

The implementation uses Zig vector operations so the normal Ghost LLVM build can
lower the math to the active x86_64 CPU target. The GIP parser remains covered by
the separate native-codegen check and is not moved onto this vector path.

## Vulkan Lattice Search

`src/gpu/search.comp` is a storage-buffer compute shader for scanning GRE runes
against a query vector by Hamming distance. `src/gpu/vulkan_init.zig` holds the
stage-gate contract:

- `<= 1000` runes stays in CPU RAM.
- `> 1000` runes is eligible for explicit RAM-to-VRAM staging and Vulkan
  compute.

The stage-gate only selects placement. Vulkan scores are retrieval candidates;
they do not promote support.

## Reality Oracle

`src/oracle/compiler_loop.zig` wraps `zig test` through `std.process.Child`.
Successful exit code `0` is the only promotion condition from `Unverified` to
`Verified`. Linux and macOS child execution applies an explicit virtual-memory
limit with `ulimit -v`; the default cap is 12GB and values at or above the 16GB
machine boundary are rejected.

## Build Contract

The new modules are `.small` code-model compatible through the existing Zig build
pattern. Full VSA, Vulkan, semantic tensor, and adjacent vector math stay on LLVM.
The scalar GIP parser remains Native through `zig build check-native-gip-parser`.
