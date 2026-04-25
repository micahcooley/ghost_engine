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
- integrated verified-complete task workflow
- integrated blocked task workflow
- integrated unresolved task workflow
- replay-from-task workflow
- external-evidence-assisted support recovery
- integrated runtime-verified patch workflow
- patch compile-pass rate
- test-pass rate
- runtime-pass rate
- latency per verified result
- shard-local cold-versus-warm cache behavior
- tank-path partial-finding preservation
- tank-path ambiguity preservation
- tank-path suppressed-noise tracking
- tank-path reinforcement reuse tracking
- tank-path unsupported proof-admission blocking
- mounted-pack routing, trust/conflict visibility, and compute-tier cap pressure
- response-mode selection and draft/fast/deep path latency
- artifact schema pipeline latency
- verifier adapter dispatch plus code/non-code verifier coverage

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

- total cases: 42
- passed cases: 42
- failed cases: 0
- code impact correctness rate: 100%
- contradiction detection correctness rate: 100%
- unresolved-vs-unsupported correctness rate: 100%
- minimal-safe-refactor correctness rate: 100%
- execution-loop handling rate: 100%
- provenance/support completeness rate: 96%
- support/provenance completeness: 27/28
- verified-complete workflow rate: 100%
- blocked workflow rate: 100%
- unresolved workflow rate: 100%
- replay-from-task workflow rate: 100%
- external-evidence-assisted workflow rate: 100%
- runtime-verified patch workflow rate: 100%
- verified supported patch or task-verification results: 13
- patch compile-pass rate: 84% (16/19)
- test-pass rate: 87% (14/16)
- runtime-pass rate: 83% (5/6)
- latency per verified result: 7509 ms
- cold start / warm start: 276 ms / 360 ms
- cold cache changed files / warm cache changed files: 15 / 0
- workflow cases: 7
- task-state distribution: `blocked=2`, `unresolved=1`, `verified_complete=4`
- replay coverage: 1/1 replay workflow cases fully replayable
- external evidence outcomes: `not_needed=5`, `ingested=2`
- partial-finding preservation rate: 100% (5/5)
- ambiguity preservation rate: 100% (1/1)
- suppressed-noise count: 46
- reinforcement reuse hit count: 3
- unsupported proof-admission block count: 3
- pack candidate surfaces / activated / skipped: 21 / 25 / 24
- pack budget cap hits / local-truth wins: 4 / 1
- response mode distribution: draft=1, fast=1, deep=1
- measured response mode selection / draft path / fast path / deep path: 0 / 2 / 1 / 1 ms
- measured artifact schema pipeline / verifier adapter dispatch: 3 / 15 ms
- verifier domains: code=36, non_code=2

## Interpreting The Rates

- `patch compile-pass rate` is the fraction of attempted candidate build steps that passed, not the fraction of benchmark cases.
- `test-pass rate` is the fraction of attempted candidate test steps that passed, not the fraction of benchmark cases.
- `runtime-pass rate` is the fraction of attempted runtime verification steps that passed.
- `runtime-pass rate: 83% (5/6)` is the fraction of attempted bounded runtime verification steps that passed in the current suite.
- `support/provenance completeness: 27/28` is the count behind the 96% completeness rate for support-relevant successful cases.
- `response mode distribution` comes from deterministic Phase 3 probes that exercise draft, fast, and verifier-required deep paths.
- `verifier domains` separates build/test/runtime adapter coverage from non-code adapter coverage such as config/document checks.

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
- dispatch-boundary repair that normalizes a bounded wrapper descendant
- multi-surface expanded synthesis across multiple dependent files
- unresolved result when all candidates fail verification
- abstraction-reference support completeness
- tank-path exploratory candidate generation from weak rationale with bounded proof blocking
- tank-path ambiguous patch rationale preservation with structured ambiguity output
- positive runtime-oracle verification after build/test pass
- positive runtime-oracle verification with ordered event sequences and multiple state outputs
- positive runtime-oracle verification with bounded state transitions across repeated actions
- negative runtime-oracle rejection after build/test pass

This is the current measured scope behind the patch metrics above.

## Tank Path Coverage

The suite now includes dedicated tank-path fixtures and cases for:

- malformed config and semi-structured symbolic input preserving partial findings
- mixed docs plus stack-trace/path-like weak input remaining unresolved without guessing
- noisy symbolic corpus material being suppressed while one anchored surface survives
- deterministic reinforcement reuse on later runs
- weak patch rationale improving exploratory planning only
- proof admission still blocking unsupported rationale
- ambiguous patch rationale staying unresolved with preserved ambiguity structure

## Integrated Operator Workflow Coverage

The suite now treats the operator surface as a workflow surface, not just a wrapper around subsystems.

Measured operator cases:

- `verified_complete` patch workflow through `ghost_task_operator`
- `blocked` patch workflow when no Linux-native build workflow exists
- `unresolved` support workflow when symbolic grounding ties remain unresolved
- replay directly from a recorded task panic dump
- bounded external-evidence ingestion followed by support recovery
- runtime-verified patch completion through the task operator

Current caveat:

- external-evidence-assisted targets resolve against both the staged shard-local corpus path and stable source-basename aliases such as `@corpus/docs/runbook.md`

## Files To Read With The Reports

- [benchmarks/ghost_serious_workflows/README.md](../benchmarks/ghost_serious_workflows/README.md)
- [benchmarks/ghost_serious_workflows/results/latest-linux.md](../benchmarks/ghost_serious_workflows/results/latest-linux.md)
- [benchmarks/ghost_serious_workflows/results/latest-linux.json](../benchmarks/ghost_serious_workflows/results/latest-linux.json)

## Current Deferred Work

Intentionally deferred benchmark work:

- expand runtime oracles beyond the current bounded stdout/state/invariant/event-sequence/state-transition checks only when the new behavior is implemented and benchmarkable
- expand measured scope only when the new behavior is already implemented and benchmarkable
