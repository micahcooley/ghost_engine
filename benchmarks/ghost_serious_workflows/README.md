## Ghost Serious Workflow Benchmarks

This suite measures Ghost on replacement-oriented workflow tasks rather than chat-style prompts.

It is built around real local fixture repos and Ghost's shipped deterministic flows:

- `code_intel`
- `patch_candidates`
- bounded execution verification
- support graph and proof surfaces
- project-shard cache behavior

### Layout

- `fixtures/base_service/`
  - multi-file Zig service fixture with build and test workflows
- `fixtures/execution_timeout/`
  - bounded timeout harness fixture
- `shims/scripted_verification/bin/zig`
  - deterministic verification shim that injects one failing candidate and one retried candidate
- `shims/refinement/bin/zig`
  - deterministic verification shim that forces bounded refinement to a smaller patch surface
- `shims/always_fail/bin/zig`
  - deterministic verification shim that forces verification failure paths
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

- 15 total cases and 15 passing cases
- 5 verified supported patch results
- patch compile-pass rate: 85% (12/14 candidate build attempts)
- test-pass rate: 75% (9/12 candidate test attempts)
- runtime-pass rate: 0% (0/0 attempted runtime steps)
- latency per verified result: 6940 ms
- cold start / warm start: 40 ms / 56 ms
- cold cache changed files / warm cache changed files: 11 / 0

The `runtime-pass rate` is currently `0/0` because the suite does not yet contain a positive runtime-verified patch fixture. It is not evidence that runtime execution is failing.

### Notes

- The suite does not compare Ghost against external systems.
- Reported metrics are produced from actual local runs.
- Honesty behavior is treated as a benchmarked property, not something to bypass.
- The cold/warm case measures shard-local cache behavior and changed-file counts; it does not guarantee warm latency will always be lower on every machine.
