## Ghost Serious Workflow Benchmarks

This suite measures Ghost on replacement-oriented workflow tasks rather than chat-style prompts.

It is built around real local fixture repos and Ghost's shipped deterministic flows:

- `ghost_task_operator` / integrated operator workflows
- `code_intel`
- `patch_candidates`
- bounded execution verification
- panic dump / replay
- external evidence ingestion
- support graph and proof surfaces
- Phase 3 artifact schema, response engine, and verifier adapter probes
- project-shard cache behavior

### Layout

- `fixtures/base_service/`
  - multi-file Zig service fixture with build and test workflows
- `fixtures/runtime_oracle_positive/`
  - build/test fixture plus bounded runtime oracle that proves a synthesized patch at runtime
- `fixtures/runtime_oracle_sequence_positive/`
  - build/test fixture plus bounded runtime oracle that verifies ordered events, state transitions, and multiple state outputs in one run
- `fixtures/runtime_oracle_negative/`
  - build/test fixture plus bounded runtime oracle that rejects bad runtime behavior cleanly
- `fixtures/runtime_oracle_transition_positive/`
  - build/test fixture plus bounded runtime oracle that verifies repeated-action state transitions in one run
- `fixtures/execution_timeout/`
  - bounded timeout harness fixture
- `fixtures/operator_blocked_simple/`
  - minimal repo with no Linux-native build workflow so blocked task handling is measured directly
- `fixtures/external_evidence_support/`
  - deterministic local evidence bundle used by the external-evidence-assisted operator workflow
- `fixtures/pack_scaling/`
  - mounted-pack routing, conflict/trust visibility, and compute-tier stress fixtures
- `fixtures/tank_malformed_symbolic/`
  - malformed config and semi-structured symbolic input fixture for partial-finding preservation checks
- `fixtures/tank_mixed_stacktrace/`
  - mixed docs plus stack-trace/path-like fixture for unresolved weak-input coverage
- `fixtures/tank_noisy_anchor/`
  - noisy symbolic corpus fixture with one anchored surviving surface and bounded noise suppression
- `fixtures/tank_reinforced_pattern/`
  - repeated weak-structure symbolic pattern fixture used for deterministic reinforcement reuse checks
- `fixtures/tank_patch_weak/`
  - weak patch-rationale fixture used to benchmark exploratory planning plus proof-admission blocking
- `fixtures/tank_patch_ambiguous/`
  - ambiguous patch-rationale fixture used to preserve structured ambiguity in unresolved output
- `shims/scripted_verification/bin/zig`
  - deterministic verification shim that injects one failing candidate and one retried candidate
- `shims/refinement/bin/zig`
  - deterministic verification shim that forces bounded refinement to a smaller patch surface
- `shims/always_fail/bin/zig`
  - deterministic verification shim that forces verification failure paths
- `shims/dispatch_repair/bin/zig`
  - deterministic verification shim that forces wrapper-dispatch normalization repairs
- `shims/multifile_expanded/bin/zig`
  - deterministic verification shim that requires bounded multi-surface caller adaptation
- `results/latest-linux.json`
  - most recent Linux benchmark output produced by the runner
- `results/latest-linux.md`
  - human-readable summary of the most recent Linux run

### Run

```sh
zig build bench-serious-workflows
```

The runner writes fresh reports under `benchmarks/ghost_serious_workflows/results/`.

### Outcome Buckets

- `supported_success`
- `correct_unresolved_or_refused`
- `failed_verification_or_runtime`

### Current Measured Scope

The latest Linux run in this workspace reports:

- 42 total cases and 42 passing cases
- 7 integrated operator-workflow cases and 7 passing workflow cases
- task-state distribution: `verified_complete=4`, `blocked=2`, `unresolved=1`
- support/provenance completeness: `27/28`
- replay coverage: `1/1` replay workflow cases fully replayable
- external evidence outcomes: `ingested=2`, `insufficient=0`, `conflicting=0`
- 13 verified supported patch or task-verification results
- patch compile-pass rate: 84% (16/19 candidate build attempts)
- test-pass rate: 87% (14/16 candidate test attempts)
- runtime-pass rate: 83% (5/6 attempted runtime steps)
- latency per verified result: 7509 ms
- cold start / warm start: 276 ms / 360 ms
- cold cache changed files / warm cache changed files: 15 / 0
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

Workflow cases now explicitly measure:

- verified-complete patch workflow
- blocked workflow
- unresolved workflow
- replay-from-task workflow
- external-evidence-assisted workflow
- runtime-verified patch workflow
- weak-structure tank-path preservation on malformed, noisy, and mixed symbolic fixtures
- deterministic reinforcement reuse over later runs
- exploratory patch planning from weak rationale without proof admission
- unresolved ambiguous patch rationale preservation

### Notes

- The suite does not compare Ghost against external systems.
- Reported metrics are produced from actual local runs.
- Honesty behavior is treated as a benchmarked property, not something to bypass.
- The cold/warm case measures shard-local cache behavior and changed-file counts; it does not guarantee warm latency will always be lower on every machine.
- External evidence now resolves against both the staged corpus path Ghost writes and stable source-basename aliases such as `@corpus/docs/runbook.md`.
- Phase 3 response-mode and verifier-adapter probes are measured with real local execution; timings are reported as observed, not normalized or padded.
