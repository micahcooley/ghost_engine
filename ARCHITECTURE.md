# Ghost Engine Architecture

A bare-metal Vector Symbolic Architecture (VSA) engine with Vulkan GPU compute acceleration, multi-GPU fleet training, and distributed consensus.

## Domain Term Mapping

| Ghost Term | CS / Math Term | Description |
|---|---|---|
| Rune | Unicode Codepoint | A single UTF-32 character. The atomic unit of input. |
| HyperVector | 1024-bit VSA Vector | `@Vector(16, u64)`. A pseudo-random bipolar vector in hyperspace. |
| generate(seed) | VSA Identity Vector | Deterministic hash (splitmix64 variant) mapping any u64 to a 1024-bit vector. |
| bind(a, b) | VSA Binding (XOR) | `a ^ b`. Produces a vector dissimilar to both inputs. Symmetric, invertible. |
| bundle(a, b, c) | VSA Bundling (Majority Rule) | `(a & b) \| (b & c) \| (c & a)`. Superposes 3 vectors into 1. Lossy compression. |
| permute(v) | VSA Permutation | Circular bit-shift by 19 on each lane. Produces a near-orthogonal vector. |
| Resonance | Hamming Similarity | `1024 - popcount(a ^ b)`. Range [0, 1024]. 1024 = identical, 512 = random, 0 = inverse. |
| Rotor | Rolling Hash State | A u64 FNV-1a derivative that evolves per-rune. Acts as a context-dependent address. |
| MeaningMatrix | Hash-Table of Accumulators | Open-addressed (double-hash) table. Each slot holds 1024 x u32 counters. Collapse via thresholding produces a 1024-bit binary vector. |
| collapseToBinary(hash) | VSA Memory Read | Probes the MeaningMatrix by hash, reads 1024 u32 accumulators, thresholds each to a single bit, producing a 1024-bit HyperVector. |
| applyGravity | VSA Memory Write (Hebbian) | For each of 1024 bit positions: if bit=1, increment counter; if bit=0, decrement. Saturating arithmetic. |
| Myelination | Weight Locking (MSB) | When a u32 counter reaches 10,000, the MSB (0x80000000) is set. The weight becomes permanent. |
| Unified Lattice | Memory-Mapped u16 Array | 1 GB file (`unified_lattice.bin`). 512M x u16 counters. Secondary storage for GPU etched patterns. |
| GhostSoul | Multi-Scale Context State | Four HyperVector registers (syntax, phrase, concept, global) with cascade etching on boundary detection. |
| Boundary | Syntactic Delimiter | Enum: word (space), phrase (punctuation), paragraph (brace), soul (low energy). Triggers context cascade. |
| PagedPanopticon | Paged Text Buffer | 64 pages x 16M u32 = 4 GB literal recall. Stores every rune seen. Concept anchors stored separately for O(n) nearest-neighbor search. |
| MesoLattice | Cursor State | Tracks the current position in the generation stream. |
| Monte Carlo Engine | Tree Search | 5-lane parallel rollout over top-K candidates. Each lane simulates 10 steps of greedy character selection. Winner chosen by terminal resonance score. |
| Koryphaios | Coherence Gate | A 2-threshold Hamming distance check (manager + critic) that gates candidate acceptance during reasoning. Prevents context drift. |
| OperationalTier | GPU Batch Size Heuristic | Enum from `god` (16x base) to `background` (base/8). Derived from `maxComputeWorkGroupInvocations`. |
| BMP Space | Precomputed Identity Table | 65,536 HyperVectors generated at init. Hierarchical search via 256 centroids (each bundling 256 vectors). |
| GreedyBatcher | Multi-Stream Scheduler | Atomic-cursor round-robin over corpus file streams. Packs runes into GPU dispatch buffers. |
| ClusterNode | Gossip Protocol | UDP broadcast for myelin lock events + heartbeat. TCP fallback for hash-mismatch slot sync. 16-byte fixed packets. |

## Data Flow

```
Input Text
    |
    v
[Rune Iterator] -- UTF-8 decode --> codepoints
    |
    v
[GhostSoul.absorb(rune)]
    |-- generate(codepoint) -> HyperVector
    |-- Update rotors (FNV-1a rolling hash)
    |-- Bundle into syntax/phrase/concept/global registers
    |-- Detect boundary -> cascade etch across levels
    |-- Push to Panopticon (literal recall)
    |
    v
[SingularityEngine.resolveText1D()]
    |-- Query resonance (GPU or CPU hierarchical search)
    |      CPU: 256 centroid sweep -> top-8 chunks -> 2048 candidates
    |      GPU: Vulkan compute shader -> 256 energy values
    |-- Top-K selection
    |-- Reasoning (Monte Carlo GPU rollout or Koryphaios CPU fallback)
    |-- Oracle audit (1/10000 runes: GPU vs CPU energy comparison)
    |
    v
Output Rune
```

## GPU Pipeline

Five SPIR-V compute shaders, embedded in the binary:

| Shader | Purpose |
|---|---|
| `genesis_etch` | Batch Hebbian update: writes to MeaningMatrix accumulators |
| `lattice_etch` | 4-probe hashing with greedy saturation into the Unified Lattice |
| `resonance_query` | Hamming distance sweep: computes energy per candidate character |
| `recursive_lookahead` | Monte Carlo tree search with shared-memory reduction |
| `thermal_prune` | Bit-shift decay on lattice counters |

The training path uses `dispatchMergedEtch` which records lattice + meaning matrix compute into a single command buffer with a pipeline barrier between them.

## Memory Layout

| Artifact | Size | Format |
|---|---|---|
| `unified_lattice.bin` | 1 GB | 512M x u16 (memory-mapped) |
| `semantic_monolith.bin` | 2 GB | 512M x u32 (accumulators) |
| `semantic_tags.bin` | 8 MB | 1M x u64 (hash keys) |

GPU buffers are sized dynamically based on detected VRAM (60% meaning matrix, 30% lattice, 10% overhead), with power-of-2 slot counts for deterministic double-hashing.

## Build

```bash
zig build -Doptimize=ReleaseFast     # Build all executables
zig build release                      # Package distributable
zig build test                         # Run unit tests
zig build test-parity                  # GPU vs CPU parity verification
```
