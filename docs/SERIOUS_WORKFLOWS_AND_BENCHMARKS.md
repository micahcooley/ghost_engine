# Serious Workflows And Benchmarks

This document covers the serious-workflow benchmark suite and how to read the current reports.

## Purpose

The suite measures implemented Ghost workflow behavior, not open-ended chat quality.

Current measured surfaces:

- code-impact correctness
- contradiction detection correctness
- unresolved-versus-unsupported honesty behavior
- minimal-safe-refactor selection
- execution-loop handling
- provenance/support completeness
- patch compile-pass rate
- test-pass rate
- runtime-pass rate
- latency per verified result
- shard-local cold-versus-warm cache behavior

## Runner

Run:

```bash
zig build bench-serious-workflows
```

Outputs:

- `benchmarks/ghost_serious_workflows/results/latest-linux.json`
- `benchmarks/ghost_serious_workflows/results/latest-linux.md`

The runner is implemented in `src/bench_serious_workflows.zig`.

## Current Linux Report

Latest report from this workspace:

- total cases: 15
- passed cases: 15
- failed cases: 0
- code impact correctness rate: 100%
- contradiction detection correctness rate: 100%
- unresolved-vs-unsupported correctness rate: 100%
- minimal-safe-refactor correctness rate: 100%
- execution-loop handling rate: 100%
- provenance/support completeness rate: 100%
- verified supported patch results: 5
- patch compile-pass rate: 85% (12/14)
- test-pass rate: 75% (9/12)
- runtime-pass rate: 0% (0/0)
- latency per verified result: 6940 ms
- cold start / warm start: 40 ms / 56 ms
- cold cache changed files / warm cache changed files: 11 / 0

## Interpreting The Rates

- `patch compile-pass rate` is the fraction of attempted candidate build steps that passed, not the fraction of benchmark cases.
- `test-pass rate` is the fraction of attempted candidate test steps that passed, not the fraction of benchmark cases.
- `runtime-pass rate` is the fraction of attempted runtime verification steps that passed.
- `runtime-pass rate: 0% (0/0)` currently means no positive runtime verification fixture exists in the patch benchmark path yet. It does not mean runtime execution is failing.

## Cold And Warm Cache Behavior

The suite includes `cold_warm_code_intel_start`.

What it measures:

- first run after clearing shard-local code-intel cache
- second run against the same project shard with the cache already populated
- changed-file counts in the code-intel cache lifecycle

What it does not claim:

- it does not guarantee warm latency is always lower than cold latency on every machine
- it does not claim a universal startup speed result outside the fixture and machine used for the run

## Execution Harness Coverage

The suite covers three execution-harness outcomes:

- successful bounded `zig run`
- refused unrestricted shell command
- bounded timeout on a workspace-local script

That means the current benchmarked execution harness behavior is:

- Linux-first
- workspace-confined
- bounded
- refusal-capable

## Patch Workflow Coverage

Current patch cases cover:

- verified success
- minimal verified scope selection over broader verified scope
- retry after failed candidate verification
- bounded refinement traces
- unresolved result when all candidates fail verification
- abstraction-reference support completeness

This is the current measured scope behind the patch metrics above.

## Files To Read With The Reports

- [benchmarks/ghost_serious_workflows/README.md](../benchmarks/ghost_serious_workflows/README.md)
- [benchmarks/ghost_serious_workflows/results/latest-linux.md](../benchmarks/ghost_serious_workflows/results/latest-linux.md)
- [benchmarks/ghost_serious_workflows/results/latest-linux.json](../benchmarks/ghost_serious_workflows/results/latest-linux.json)

## Current Deferred Work

Intentionally deferred benchmark work:

- add a positive runtime-verified patch fixture so runtime-pass rate becomes non-empty
- expand measured scope only when the new behavior is already implemented and benchmarkable
