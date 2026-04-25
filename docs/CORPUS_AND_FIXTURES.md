# Corpus and Fixtures

This document clarifies the relationship between the external data in `corpus/` and the operational behavior of the Ghost Engine.

## Operational Hygiene

External source trees present in the `corpus/` directory are **not** automatically treated as active Ghost knowledge. The engine maintains a strict boundary between "available data" and "active reasoning inputs." 

An artifact is only considered operationally active if it is:
- Explicitly referenced by a benchmark case fixture.
- Part of a mounted and activated Knowledge Pack.
- Specifically targeted for ingestion by `ghost_corpus_ingest` with a corresponding manifest entry in the shard state.
- Referenced as a fallback/demo corpus in the shell configuration.

## Corpus Classification Model

To prevent "mythological" interpretations of the source tree, all corpus artifacts are classified into one of the following tiers:

1.  **Actively used by benchmark/test**: Critical path for verifying engine correctness (e.g., specific project fixtures under `benchmarks/`).
2.  **Indexed but not benchmark-critical**: Present in the semantic index but not part of a primary verification suite.
3.  **Available corpus only**: Present on disk and eligible for ingestion, but not currently indexed or mounted.
4.  **Unrelated naming collision**: Files that happen to contain project keywords (like "ghost") but belong to unrelated external projects (e.g., Linux drivers, GCC Ada internals).
5.  **Synthetic generated fixture**: Purpose-built data for stress-testing or fallbacks (e.g., `mixed_sovereign.txt`).

## Audit Summary (April 2026)

The current "Ghost" named artifacts are classified as follows:
- `mixed_sovereign.txt`: **Tier 5** (Synthetic stress fixture).
- `tiny_shakespeare.txt`: **Tier 5** (Fallback demo data).
- GCC Ada `ghost.ads`: **Tier 4** (Naming collision).
- Linux `upd64031a.c` (Ghost Reduction): **Tier 4** (Naming collision).
- Ghost CMS Docker files: **Tier 3** (Available background only).
