# Learning Loop

The first Learning Loop surface is `learning.loop.plan`. It is a read-only,
candidate-only planning operation:

`project.autopsy` -> `learningLoopPlan` -> `verifierCandidateProposal`

It does not implement verifier execution, failure ingestion, patching,
correction application, negative-knowledge review, procedure-pack mutation, or
learning-state persistence. The verifier-candidate handoff added after the
first planner surface persists only candidate/review metadata in an append-only
project-shard JSONL file.

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
