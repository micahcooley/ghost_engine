# Ghost Absolute Specification

## Honest Description

Ghost Absolute is an mmap-backed dictionary walker with 8 sharded workers performing bit-mixed hash lookups over a fixed memory region. It produces deterministic lattice fingerprints suitable as a routing front-end for a downstream reservoir.

## Active Core

- Source: `src/absolute_final.zig`
- State file: `state/ghost_absolute.bin`
- Default field: 2,097,152 64-bit voxels, 16 MiB
- Active window: 32 KiB
- Walker layout: 8 walkers, each assigned one 4 KiB shard inside the active window
- Mixing: XOR plus `rotl`; `@bitReverse` is not used in the active core
- Mapping mode: `MAP_SHARED`; existing non-empty mapped state is preserved, and empty files are seeded once

The active ingest loop is intentionally narrow. Each input byte selects a voxel inside its walker's assigned shard, XORs a rotated byte-derived lane value into that voxel, and advances the walker from the prior voxel state plus the mixed value. The walkers do not write each other's shards, which removes the cross-walker read-after-write hazard present in the earlier shared-window loop.

## What It Measures

`src/adapters/ghost_throughput_bench.zig` reports:

- baseline XOR-loop throughput in MiB/s
- sharded core throughput in MiB/s
- sharded core write count and edge fingerprint
- N=1000 unique prompt calibration using deterministic PRNG-generated prompts
- Unique Edge Rate, defined as unique edge fingerprints divided by prompt count

`src/adapters/sovereign_interface.zig` exposes the same active core as a UI-facing mirror. It reports only values derived from the local mapped field and the `IngestReport` returned by `AbsoluteCore.ingestMeasured(...)`:

- `fieldBytes` and `fieldCount` from the actual mapped field
- `peakVoxel` from the highest current input-resonance scan over the mapped field
- `resonanceDensity` as normalized `@popCount(peakVoxel ^ edgeFingerprint ^ dominantDelta) / 64`
- `dominantDelta` and `edgeFingerprint` from the ingest report
- `spectralPath` from the dominant edge, fingerprint, peak voxel, and delta
- `activeNeologism` from a deterministic 64-bit syllabic mapping
- `pathfinderChain`, a dynamic chain of alien names and English anchors produced by a 31-bit prime neighbor walk. Chain length varies with input pressure; it is not a fixed response sentence.

`src/adapters/grammar_pulse.zig` is an offline corpus-folding tool for local Common Crawl WET/plain text files. It accepts a real corpus path, folds up to 1,000,000 plausible sentences into the shared `ghost_absolute.bin` field, compares a grammar-density measurement against a deterministic noise baseline, and errors instead of synthesizing a corpus when input is missing or insufficient.

The benchmark is reproducible from the repo root with:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/ghost_throughput_bench
./zig-out/bin/grammar_pulse --corpus /path/to/common-crawl-wet-or-text --max-sentences=1000000 --json
./zig-out/bin/sovereign_interface --message Hello --json
```

## Grounding Note

VSA grounding is currently non-load-bearing for Ghost Absolute. It is present elsewhere in the repository as adjacent experimental machinery, but the Absolute core does not depend on VSA vectors to discriminate prompts. Primary discrimination for this research line comes from sparse routing and byte-pressure behavior in `src/void.zig`, plus the deterministic edge fingerprints emitted by the sharded mmap walker.

## Non-Claims

Ghost Absolute is not a language model, proof engine, or verified intelligence system. It does not prove semantic support, execute reasoning over evidence, or produce authoritative answers. Its current role is a deterministic routing and fingerprinting front-end whose behavior must be evaluated with throughput and collision statistics rather than theatrical claims.

The sovereign interface is a local visualization and pronunciation layer over those measurements. Its English anchors are deterministic labels selected from peak bits; they are not a learned semantic decoder.
