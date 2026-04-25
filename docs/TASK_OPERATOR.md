# Ghost Task Operator

## Session Model

Ghost now records shard-local task sessions under `state/.../shards/.../tasks/`.

Each session stores:

- `task_id`
- raw originating intent plus grounded dispatch snapshot
- current objective
- bounded subgoals
- explicit task state: `planned`, `running`, `blocked`, `unresolved`, `verified_complete`, `failed`
- chosen reasoning mode
- optional bounded external-evidence request
- external-evidence state: `not_needed`, `requested`, `fetched`, `ingested`, `conflicting`, `insufficient`
- shard/corpus/abstraction context references
- bounded action history with artifact, draft, and panic-dump references
- latest support summary from support graphs and verification flows

The session file is inspectable JSON and resume is bounded by recorded `nextSubgoalIndex`.

## Operator Loop

The operator is deterministic and bounded:

1. `ground_request`
2. `collect_support`
3. `synthesize_and_verify_patch` for patch workflows only

Each step checkpoints session state after execution. Resume re-enters from the recorded next subgoal. Reopen is explicit and only resets a terminal non-complete state back to the current recorded subgoal.

## Integration

The operator reuses existing Ghost systems:

- `task_intent` for grounded request snapshots
- `code_intel` and support graphs for support collection
- bounded external evidence fetch/search only as an explicit support-recovery step
- `corpus_ingest` for shard-local staging, lineage, trust, and live ingestion of fetched sources
- `patch_candidates` for bounded synthesis, verification, and repair
- `technical_drafts` for stable task-local drafts
- `panic_dump` for replay-oriented stop snapshots
- shard-local storage for session JSON and task artifact snapshots

## Linux-First Workflow Surface

`ghost_task_operator` is now the primary serious-workflow entrypoint instead of a thin task-session wrapper only.

Integrated command family:

- `project`
  Inspect the mounted project shard roots used by code-intel, patch, corpus, abstractions, and task sessions.
- `run` / `resume` / `show`
  Start, continue, and inspect bounded task sessions.
- `support`
  Inspect latest support/provenance without opening result artifacts manually.
- `inspect`
  Run bounded `code_intel` impact, breaks-if, or contradiction analysis.
- `plan`
  Run bounded patch planning without staging the selected patch.
- `verify`
  Run bounded patch synthesis and verification.
- `oracle`
  Run the same bounded patch verification surface with explicit runtime-oracle reporting.
- `replay`
  Replay either a panic-dump path or the latest panic dump attached to a recorded task id.

All commands support stable rendering modes:

- `--render=summary` or `--render=concise`
- `--render=json`
- `--render=report`

`report` mode reuses existing technical drafts and replay reports. It is not a chat surface.

## Response Mode UX

Operator workflows stay on verifier-capable paths for proof, correctness, test, verify, and patch-capable actions. Draft/report rendering is a view over recorded artifacts and support traces; it does not turn an unverified draft into `verified_complete`.

The task state remains the authority:

- draft/report output can explain assumptions and missing information
- fast response paths are only eligible for cheap, fully grounded, non-verifier-required obligations
- deep response paths are required when verifier hooks or patch-capable action surfaces are involved
- budget exhaustion is reported as budget exhaustion, not ordinary unresolved output

## Measured Linux Snapshot

The current Linux serious-workflow suite measures the operator surface directly:

- verified-complete workflow rate: 100%
- blocked workflow rate: 100%
- unresolved workflow rate: 100%
- replay-from-task workflow rate: 100%
- external-evidence-assisted workflow rate: 100%
- runtime-verified patch workflow rate: 100%
- task-state distribution across workflow cases: `verified_complete=4`, `blocked=2`, `unresolved=1`
- replay coverage: `1/1` replay workflow cases fully replayable

## Example Verified Multi-Step Flow

1. `ghost_task_operator run --intent="refactor src/api/service.zig:compute but keep the API stable" --max-steps=1`
   Creates a task and completes `ground_request`.
2. `ghost_task_operator resume <task-id> --max-steps=1`
   Runs `collect_support`, records support graph evidence and a refactor-plan draft.
3. `ghost_task_operator resume <task-id> --max-steps=1`
   Runs bounded patch synthesis and verification. `verified_complete` is only reached if a selected candidate is proof-backed and verification reaches `build_test_verified` or `runtime_verified`.
4. `ghost_task_operator support <task-id> --render=report`
   Emits the latest technical draft without manually chasing the task artifact paths.

## Example Stop Cases

- `blocked`
  A patch task can stop as `blocked` when no Linux-native build workflow exists. The session preserves the exact reason and writes a panic dump snapshot for replay.
  `ghost_task_operator replay --task-id=<task-id> --render=report` reads that replay path directly from the task state.
- `unresolved`
  A support step can stop as `unresolved` when intent grounding or symbolic support remains ambiguous. The session preserves the unresolved reason and keeps the recorded support context for deterministic reopen.

## External Evidence Path

When a task has an explicit external-evidence request and local support stays insufficient, the support step may enter a bounded evidence-acquisition path:

1. record `requested`
2. fetch only the provided URLs and/or a bounded result set from the provided search queries
3. snapshot fetched files under the current shard
4. classify them through `ghost_corpus_ingest`
5. apply the ingested corpus state and re-run support collection

Fetched evidence stays inspectable through:

- task-local external-evidence artifacts under `tasks/`
- shard-local `corpus_ingest` manifests and files
- support-graph nodes marked as `external_evidence`

Current measured behavior:

- externally fetched files are promoted into deterministic shard-local corpus paths such as `@corpus/docs/01-runbook.md`
- follow-up corpus targets can resolve through the staged shard-local path and stable source-basename aliases such as `@corpus/docs/runbook.md`

Ghost does not silently upgrade fetched text into truth:

- external evidence enters with explicit trust and provenance
- conflicting ambiguity remains `conflicting`
- weak or low-signal fetches remain `insufficient`
- proof-mode honesty rules still gate final `supported` output

## Current Limits

- The first operator loop only covers code-intel and patch workflows.
- Task-local result snapshots are write-on-step artifacts; replay does not yet reconstruct a task directly from snapshots alone.
- Sessions do not yet splice live abstraction lineage updates back into future subgoal planning.
- External-evidence alias coverage is bounded to ingested corpus classes Ghost currently indexes.
