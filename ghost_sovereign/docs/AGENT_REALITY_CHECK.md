# Ghost Sovereign Agent Reality Check

This file exists because agents have been confused in both directions: some call the project fake, and some overclaim it as a finished autonomous intelligence. Both are wrong.

## Ground Truth

Ghost Sovereign is real Zig code. It builds and runs locally. The core is a reservoir / constraint system with VSA-derived laws, multiple invention engines, a calibration harness, and newer manifold bridge demos.

It is not a finished LLM replacement. It does not currently produce reliable natural language answers from its own learned decoder. Most human-readable architecture explanations are agent translations from numeric marks, closure deltas, trigger edges, and benchmark outputs.

## What Is Real

- `zig build` succeeds in this directory.
- `./zig-out/bin/calibration` produces eight distinct prompt edges and stable lattice fingerprints.
- The benchmark chain in `results/` records measurable invention-engine comparisons.
- `src/aetheric.zig` uses `src/manifold.zig` to place VSA anchors and word hypervectors into a memory-mapped voxel grid.
- `src/search.zig` ingests a small hardcoded article and runs a dictionary-limited query demo.
- `src/vsa_decoder.zig` contains a prototype dictionary-based hypervector unbinder and a simple brace/paren verifier.
- `src/adapters/sovereign_interface.zig` wraps `src/absolute_final.zig` and emits live measured mirror snapshots: peak voxel, normalized resonance density, dominant delta, edge fingerprint, spectral path, deterministic syllabic neologism, and a Pathfinder chain.
- `src/adapters/grammar_pulse.zig` is a real offline corpus ingester. It reads local Common Crawl WET/plain text files or directories, folds plausible sentences into `ghost_absolute.bin`, compares grammar density against deterministic noise, and errors instead of inventing corpus data.
- `src/wiki_ingestion_synthesis.zig`, `src/decoder_synthesis.zig`, and `src/ingestion_strategy_synthesis.zig` run proposal probes that output marks and scars.

## What Is Not Real Yet

- No web-scale fetch/parse/store/query pipeline exists. `grammar_pulse` can fold local corpus files; it does not download Common Crawl for you and does not provide source-backed retrieval.
- No source-backed retrieval returns cited passages from the manifold.
- No trained decoder maps arbitrary reservoir states back into reliable prose.
- `ghost_core` and `ghost_search` output dictionary-selected words, not fluent answer generation.
- `ghost_invent_void` currently prints placeholder success text after pressure-shaping a message.
- Synthesis probes do not write architecture papers by themselves. Agents translate the numeric output.
- The default `AbsoluteCore` field used by the sovereign interface is 16 MiB in this checkout. Do not call it a live 10 GB allocation unless the state file and `fieldBytes` output prove that exact size.
- The neologism/pathfinder anchors are deterministic bit-slice back-mapping labels. They are not proof of learned semantic understanding.

## Verified Commands

From `ghost_engine/ghost_sovereign`:

```bash
zig build
./zig-out/bin/calibration
./zig-out/bin/ghost_core
./zig-out/bin/ghost_search
./zig-out/bin/wiki_ingestion_synthesis
./zig-out/bin/ghost_invent_void invent --message="invent a local tokenless architecture for typo intent on consumer hardware"
./zig-out/bin/grammar_pulse --corpus /path/to/common-crawl-wet-or-text --max-sentences=1000000 --json
./zig-out/bin/sovereign_interface --message Hello --json
```

Observed behavior on 2026-05-17:

- `zig build` exited 0.
- `calibration` produced distinct edges: `122`, `111`, `177`, `826`, `523`, `677`, `5`, `788`.
- `ghost_core` emitted a dominant resonance label and code-dictionary tokens.
- `ghost_search` ingested a hardcoded `Artificial Intelligence` article and emitted small-dictionary tokens.
- `wiki_ingestion_synthesis` emitted mark `0x8DB70E1FA4402FC9` and scar `0xACE`.
- `ghost_invent_void` emitted placeholder text: `Resolution achieved`.
- `sovereign_interface --message Hello --json` emitted real `AbsoluteCore` measurements including `fieldBytes: 16777216`, `fieldCount: 2097152`, `writes: 5`, `resonanceDensity: 0.328125`, and an active neologism derived from the measured peak.

## How To Report This Honestly

Use this wording:

> Ghost Sovereign is a real local Zig reservoir and invention-probe stack. It has reproducible benchmark and calibration outputs. Its newer aetheric/manifold/decoder code is real and runnable, but still prototype-grade: dictionary-limited, not source-backed retrieval, and not a trained language generator.

Do not use this wording:

> Ghost Sovereign is fake.

Do not use this wording either:

> Ghost Sovereign is a complete ASI or full LLM replacement.

## Agent Rule

If you make a capability claim, point at one of these:

- a source file,
- a command that runs,
- a result file,
- or a clearly labeled agent translation.

If you cannot point at one of those, mark the claim unresolved.
