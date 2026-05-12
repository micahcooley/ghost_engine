# Heterogeneous Memory Contract

This is an implementation guide for keeping Ghost responsive on a 16GB Linux
machine while still using Vulkan for high-volume VSA search.

## Placement

| Logic type | Location | Memory type | Reason |
| --- | --- | --- | --- |
| Root and Verified epistemic tiers | CPU | system RAM | Branch-heavy authority logic stays on CPU. |
| Shadow candidate activation | CPU | system RAM | Prompt-time filtering should reduce the search set before GPU transfer. |
| VSA lattice search | GPU | device-local VRAM | Bulk Hamming/geometric comparison is parallel and linear. |
| Spreading activation and ConceptNet-style walks | CPU | system RAM | Pointer-heavy graph traversal is not a good Vulkan workload. |
| GIP exchange buffers | CPU/GPU boundary | host-visible staging memory | This is the explicit loading dock for transfer batches and result IDs. |

## Stage-Gate Movement

Ghost should move data only after each stage has reduced or validated the next
work item.

1. CPU architect stage
   - Parse the prompt and activate a bounded candidate set.
   - Prefer Root/Verified/Shadow metadata in system RAM.
   - Do not transfer the whole world model for a prompt.

2. RAM to VRAM staging stage
   - Write selected binary hypervectors into a host-visible staging buffer.
   - Copy staging data into device-local storage buffers before compute search.
   - Keep the staging buffer explicit; hidden global GPU mutation is not part of
     the contract.

3. GPU execution stage
   - Dispatch Vulkan compute only when the candidate set is large enough to
     amortize PCIe and synchronization cost.
   - Search binary 1024-bit hypervectors as 128-byte rows.
   - Return only compact winning GRE/rune IDs and scores.

4. CPU verification stage
   - Read back the small result buffer.
   - Hand candidate IDs to CPU-side verification and the Reality Oracle.
   - GPU similarity is never proof and must not promote support by itself.

## Latency Rules

- Use CPU search for small candidate sets. The default GPU threshold is 1000
  candidate runes unless a benchmark proves a lower threshold on the active
  device.
- Keep GPU payloads binary where possible: a 1024-bit hypervector is 128 bytes,
  so 1GB can hold roughly 8 million vectors before metadata.
- Prefer asynchronous preload on a transfer queue when the CPU is already busy
  with compile or oracle work.
- Do not move Root/Verified authority state to GPU-only memory. GPU results are
  candidate retrieval data; CPU verification remains authoritative.

## Build Split

The full VSA path currently requires LLVM on Zig 0.14.1. The Zig native x86_64
backend fails on `cmp_gt @Vector(16, u32)` in `src/vsa_memory.zig`, so full Ghost
builds must not force `-fno-llvm`.

Use the hybrid loop instead:

```bash
zig build check-native-gip-parser
zig build --watch -fincremental --cache-dir .zig-cache --global-cache-dir ~/.cache/zig
zig build release -j1 --maxrss 12000000000 --skip-oom-steps
```

`check-native-gip-parser` is intentionally narrow. It compile-checks the scalar
GIP parser with `-fno-llvm -fno-emit-bin`; VSA, semantic tensor, Vulkan, and
audio-adjacent vector paths stay on LLVM until the native backend can lower the
required vector operations.
