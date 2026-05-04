# Learning Loop

The first Learning Loop surface is `learning.loop.plan`. It is a read-only,
candidate-only planning operation:

`project.autopsy` -> `learningLoopPlan`

It does not implement verifier execution, failure ingestion, patching,
correction application, negative-knowledge review, procedure-pack mutation, or
learning-state persistence.

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
