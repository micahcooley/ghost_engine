# Code Intel And Patching

This document covers the shipped code-intel pilot, task-intent grounding, support graphs, and proof-backed patch flow.

## Code Intel Scope

`ghost_code_intel` is a deterministic pilot. It is not a claim of universal semantic understanding.

Supported query kinds:

- `impact`
- `breaks-if`
- `contradicts`

## Indexed Surfaces

Native indexing is Zig-first and bounded:

- `.zig`
- `.comp`
- `.sigil`
- `.c`, `.cc`, `.cpp`, `.cxx`
- `.h`, `.hh`, `.hpp`, `.hxx`

Symbolic ingestion is also implemented for bounded cross-symbol grounding:

- `.md`, `.txt`, `.rst`
- `.toml`, `.yaml`, `.yml`, `.json`, `.ini`, `.cfg`, `.conf`, `.env`
- `.xml`, `.html`
- `.rules`, `.dsl`

The symbolic path is structural and bounded. It extracts symbolic units, references, and structural hints so Ghost can ground documentation or configuration concepts into code or runtime targets when deterministic support exists.

## Persistence

Code-intel outputs persist under the selected shard:

- `code_intel/last_query.txt`
- `code_intel/last_result.json`
- `code_intel/cache/index_v1.gcix`

The cache is shard-local. The benchmark suite includes a cold-versus-warm case to keep that behavior measurable.

## Target Resolution And Grounding

Current resolution model:

- explicit `path:symbol` targets are preferred
- bare ambiguous symbols stay `unresolved`
- symbolic units can ground into bounded code or runtime targets
- if symbolic grounding ties across multiple surfaces, the result stays `unresolved`

That means Ghost can bridge from docs/config/symbolic units into code only when the support remains bounded and deterministic.

## Task Intent Grounding

`ghost_task_intent` is the narrow task-intent parser. It is also used by:

- `ghost_code_intel --intent=...`
- `ghost_patch_candidates --intent=...`

Implemented grounding:

- actions: build, implement, refactor, explain, verify, compare, plan
- targets: files, functions, modules, shards, concepts, symbols, quoted targets, path-like targets
- constraints: determinism, Linux-first, no-new-deps, API stability, performance, language hints
- output modes: patch, explanation, plan, alternatives

Dispatch is narrow and explicit:

- grounded explain and verify requests map to `code_intel`
- grounded build, implement, refactor, and plan requests map to `patch_candidates`
- alternatives requests force exploratory reasoning mode
- unsupported or ambiguous requests remain `clarification_required` or `unresolved`

## Support Graph Output

Both `ghost_code_intel` and `ghost_patch_candidates` emit a `supportGraph` object in JSON output.

Current fields:

- `permission`: final permission state
- `minimumMet`: whether the minimum bounded support threshold was met
- `flowMode`: current flow name such as `proof` or `explore_then_proof`
- `unresolvedReason`: why permission was denied when unresolved
- `nodes`: bounded support nodes
- `edges`: bounded support edges

Important behavior:

- `supported` output is only allowed when decision traces and evidence traces both exist
- if minimum support is missing, Ghost downgrades the result back to `unresolved`
- support graphs are not decorative; they are part of the output permission contract

## Patch Candidate Flow

`ghost_patch_candidates` is proof-backed patch generation with explicit verification.

Current flow:

1. Run `code_intel` in exploratory mode to widen bounded candidate discovery.
2. Build strategy hypotheses and patch scaffolds.
3. Cluster candidates and queue a bounded subset for proof mode.
4. Verify queued candidates with build, test, and optional runtime workflows when Linux-native workflows are detected.
5. Re-rank verified survivors under proof mode.
6. Select the minimal verified survivor using `bounded_refactor_minimality_v1`.

The output `supportGraph.flowMode` for this workflow is `explore_then_proof`.

## Verification And Minimality

Implemented verification behavior:

- build verification
- test verification
- runtime verification when a bounded Linux-native runtime workflow is available
- one bounded retry cycle
- bounded refinement traces when a smaller follow-up candidate is generated

Implemented selection behavior:

- verified survivors can still be rejected by the honesty gate
- the final winner prefers smaller verified scope, not the broadest patch
- if no candidate survives verification, final output is `unresolved`

## Execution Harness

Patch verification uses `src/execution.zig`.

Current guarantees:

- workspace-root confinement
- bounded `zig build` and `zig run`
- allowlisted shell tools only
- bounded output capture
- bounded timeouts
- explicit failure signals in result JSON

This harness is intentionally narrower than a general shell executor.

## Current Benchmark Reality

From the latest Linux serious-workflow report in this workspace:

- 15/15 benchmark cases passed
- 5 verified supported patch results
- patch compile-pass rate: 85% (12/14 build attempts)
- test-pass rate: 75% (9/12 test attempts)
- runtime-pass rate: 0% (0/0 runtime attempts)

The `0/0` runtime rate exists because the suite does not yet include a positive runtime-verified patch fixture. It does not mean runtime verification is currently broken.

## Current Limits

- the code-intel pilot only supports `impact`, `breaks-if`, and `contradicts`
- native support is bounded, not full compiler-level understanding
- symbolic grounding is structural and support-backed, not open-ended semantic interpretation
- draft renderers are deterministic views over bounded traces, not a second reasoning engine
