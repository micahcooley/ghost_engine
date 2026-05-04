# Learning Loop

The first Learning Loop surface is `learning.loop.plan`. It is a read-only,
candidate-only planning operation:

`project.autopsy` -> `learningLoopPlan` -> `verifierCandidateProposal` ->
approved `verifier.candidate.execute` -> verifier execution evidence candidate

The planner itself does not execute verifiers, ingest failures, apply patches,
apply corrections, review negative knowledge, mutate procedure packs, or persist
learning state. The verifier-candidate handoff persists candidate/review
metadata in an append-only project-shard JSONL file. A later explicit
`verifier.candidate.execute` request may run only approved candidates and may
append verifier execution records; it still does not create proof/support or
apply follow-on mutations.

## Safety Contract

Every plan reports:

- `candidate_only: true`
- `non_authorizing: true`
- `read_only: true`
- `mutates_state: false`
- `commands_executed: false`
- `verifiers_executed: false`
- `patches_applied: false`
- `packs_mutated: false`
- `corrections_applied: false`
- `negative_knowledge_promoted: false`
- `support_granted: false`
- `proof_discharged: false`

Rendering may explain these boundaries. Rendering cannot create authority.

## Verifier Candidate Lifecycle

`learning.loop.plan` keeps returning read-only verifier refs. The explicit
handoff is separate:

- `verifier.candidate.propose_from_learning_plan` validates
  `learningLoopPlan.verifier_candidate_refs[]` and appends proposed verifier
  candidate metadata.
- `verifier.candidate.list` folds the same append-only metadata and returns the
  latest proposed/approved/rejected status for each candidate.
- `verifier.candidate.review` appends approval or rejection metadata for an
  existing same-shard candidate.
- `verifier.candidate.execute` requires an approved same-shard candidate,
  explicit `confirmExecute:true`, a workspace root, and argv tokens. It reuses
  the bounded execution harness in `src/execution.zig`.

Candidate records are stored under the project shard at
`verifier_candidates/verifier_candidates.jsonl`. The file is append-only:
records are not rewritten, compacted, deleted, promoted into packs, or treated
as evidence. Approval means only "approved for possible future execution." It
does not run a command, run a verifier, produce evidence, discharge support,
prove an answer, apply a patch, ingest a failure, or mutate corpus, correction,
negative-knowledge, pack, trust, snapshot, or scratch state.

Every verifier candidate/review surface reports or preserves:

- `candidateOnly: true`
- `nonAuthorizing: true`
- `reviewRequired: true` on candidates
- `executesByDefault: false`
- `executed: false`
- `producedEvidence: false`
- `commandsExecuted: false`
- `verifiersExecuted: false`
- `supportGranted: false`
- `proofDischarged: false`

Approved verifier execution records are stored under the project shard at
`verifier_executions/verifier_execution_records.jsonl` only after a command is
actually spawned by the bounded harness. Rejected, unapproved, unconfirmed, or
disallowed requests return structured non-execution results without evidence.
`verifier.candidate.execution.list` and `verifier.candidate.execution.get`
inspect that JSONL store directly by `projectShard`; inspection is read-only and
does not schedule, retry, or execute verifiers. Empty inspection means no
persisted execution records were visible. Unknown is not false, and no evidence
is not negative evidence.
Execution records are evidence candidates only:

- `evidenceCandidate: true` only for spawned execution output
- `nonAuthorizing: true`
- `supportGranted: false`
- `proofGranted: false`
- `correctionApplied: false`
- `negativeKnowledgePromoted: false`
- `patchApplied: false`
- `corpusMutation: false`
- `packMutation: false`

## Derivation

The planner derives next-step candidates from Project Autopsy structures:

- safe command candidates -> `approval_required_verifier_candidate`
- verifier gaps -> `missing_evidence_step`
- risk surfaces -> `triage_candidate`
- guidance candidates -> `procedure_guidance_review_candidate`
- unknowns or empty autopsy output -> `evidence_collection_candidate`

All next steps include `requires_approval:true`,
`executes_by_default:false`, `applies_by_default:false`, and
`non_authorizing:true`.

Unknown remains unknown. No evidence is not negative evidence. Safe command
candidates are not verifier results.
