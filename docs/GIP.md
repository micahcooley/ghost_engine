# GIP — Ghost Interface Protocol v0.1

Ghost's native, explicit, deterministic interface protocol.

> **GIP is NOT MCP.** GIP is NOT an LLM tool-call wrapper. GIP is NOT a chat completion API.
> GIP is Ghost's own protocol, designed so ghost_cli, ghost_tui, GUI editors,
> and future bridges can all consume GIP directly.

## Protocol Version

Current version: `gip.v0.1`

Every request must include `"gipVersion": "gip.v0.1"`. Requests with
missing or unsupported versions are rejected with `unsupported_gip_version`.

## Request/Response Envelope

### Response Shape

```json
{
  "gipVersion": "gip.v0.1",
  "requestId": "<optional echo>",
  "kind": "<request kind>",
  "status": "<protocol status>",
  "resultState": { ... },
  "result": { ... },
  "error": { ... },
  "stats": { ... }
}
```

### Protocol Statuses

| Status | Meaning |
|--------|---------|
| `ok` | Request completed successfully |
| `accepted` | Request accepted, result pending |
| `partial` | Partial result (budget or truncation) |
| `unresolved` | Could not determine an answer |
| `failed` | Operation failed |
| `rejected` | Request rejected (validation/capability) |
| `unsupported` | Operation not implemented |
| `budget_exhausted` | Compute budget exhausted |

### Semantic States

| State | Meaning |
|-------|---------|
| `draft` | Non-authorizing output, not yet verified |
| `verified` | Passed all required verification |
| `unresolved` | Insufficient support to determine |
| `failed` | Verification or execution failed |
| `blocked` | Blocked on approval or missing info |
| `ambiguous` | Multiple valid interpretations |
| `budget_exhausted` | Budget limit reached |

### Result State Object

Every response that produces output includes a `resultState`:

```json
{
  "state": "draft",
  "permission": "none",
  "isDraft": true,
  "verificationState": "unverified",
  "supportMinimumMet": false,
  "stopReason": "unresolved",
  "nonAuthorizationNotice": "this is a draft response..."
}
```

**Key principle:** Draft responses always include a `nonAuthorizationNotice`.
Hypotheses are always non-authorizing. No output grants permission without
explicit verification.

## Read-Only Inspection vs. Mutating Operations

GIP operations are divided into operation-maturity metadata and human-readable
categories. The machine-readable source of truth is exposed by
`protocol.describe` and `capabilities.describe` under `operationMaturity`.

Each `operationMaturity` entry includes:

| Field | Meaning |
|-------|---------|
| `kind` | GIP request kind |
| `declared` | The kind exists in the protocol enum |
| `implemented` | The kind is present in the engine `IMPLEMENTED_KINDS` table |
| `wired` | The dispatcher has a concrete route for the kind |
| `mutatesState` | The operation can write/apply/append/execute state when implemented |
| `requiresApproval` | The default capability policy requires explicit approval |
| `capabilityPolicy` | Default policy: `allowed`, `denied`, `requires_approval`, `allowlist`, or `dry_run_only` |
| `authorityEffect` | Maximum declared effect: `none`, `candidate`, `evidence`, or `support` |
| `productReady` | Whether the operation is ready to present as product-complete |
| `maturity` | Short stable maturity label for clients and tests |

`declared` does not mean implemented. `implemented` does not mean product-ready.
`wired` does not mean support authority. Current GIP v0.1 metadata is
conservative: operations are not marked `productReady:true` by default, and no
operation is marked with `authorityEffect:"support"` unless proof/support gates
are actually discharged.

Human-readable categories:

### Fully implemented (real engine data queried)

| Operation | Description |
|-----------|-------------|
| `protocol.describe` | Protocol metadata, implemented kinds, maturity |
| `capabilities.describe` | Current capability policies |
| `engine.status` | Engine version, platform, operational status |
| `verifier.list` | Lists all 7 builtin adapter entries from registry |
| `pack.list` | Lists mounted packs from mount registry |
| `pack.inspect` | Reads pack manifest from disk without mounting |

### Implemented but stateless/context-required (returns valid empty shape)

These have real dispatch handlers and valid JSON output, but return empty
results when GIP has no active session or workspace metadata:

| Operation | Behavior without context | Maturity |
|-----------|------------------------|----------|
| `hypothesis.list` | Returns empty hypotheses + zero counts | `stateless` |
| `hypothesis.triage` | Returns empty triage summary with scoring policy version | `stateless` |
| `corpus.ask` | Reads existing live shard corpus; returns explicit unknown when no corpus/evidence is visible; may include non-authorizing local sketch candidates and capacity telemetry | `read_only_live_corpus_grounded_draft` |
| `rule.evaluate` | Evaluates bounded deterministic rules over request facts and emits candidate-only outputs with explanation traces and capacity telemetry | `bounded_deterministic_non_authorizing_candidates` |
| `sigil.inspect` | Compiles and validates Sigil source, then returns bytecode disassembly and procedure inspection records without VM execution or mutation | `read_only_sigil_bytecode_inspection_non_authorizing` |
| `learning.status` | Summarizes same-shard reviewed correction and reviewed negative-knowledge scoreboard diagnostics; read-only and not proof/evidence | `read_only_reviewed_learning_loop_scoreboard_non_authorizing` |
| `learning.loop.plan` | Runs bounded Project Autopsy and derives a candidate-only learning-loop plan; no execution, verifier run, patch apply, pack mutation, correction application, or negative-knowledge promotion | `candidate_only_project_autopsy_learning_loop_plan_no_execution_no_mutation` |
| `verifier.candidate.propose_from_learning_plan` | Converts approval-required `learning.loop.plan` verifier refs into append-only proposed verifier candidate metadata; no command/verifier execution and no evidence/support creation | `append_only_verifier_candidate_metadata_from_learning_loop_no_execution` |
| `verifier.candidate.list` | Lists same-shard verifier candidate metadata and folded review status; read-only and not proof/evidence | `read_only_verifier_candidate_metadata_inspection_non_authorizing` |
| `verifier.candidate.review` | Appends approved/rejected review metadata for an existing verifier candidate; approval is for possible future execution only and does not execute | `append_only_verifier_candidate_review_metadata_no_execution` |
| `verifier.candidate.execute` | Executes only same-shard approved verifier candidate argv tokens through the bounded execution harness after explicit confirmation; appends verifier execution evidence-candidate records, never proof/support | `approved_only_bounded_verifier_execution_evidence_candidate_non_authorizing` |
| `correction.propose` | Converts a user-disputed output into a review-required correction candidate plus non-authorizing learning candidates; performs no mutation or execution | `candidate_only_review_required_no_mutation` |
| `correction.review` | Accepts or rejects a correction candidate into an append-only reviewed correction record; performs no corpus, pack, negative-knowledge, command, verifier, or global promotion mutation | `append_only_reviewed_record_no_hidden_mutation` |
| `correction.reviewed.list` | Lists same-shard reviewed correction records from append-only storage with filters, warnings, and capacity telemetry; read-only and not proof | `read_only_reviewed_correction_inspection_non_authorizing` |
| `correction.reviewed.get` | Retrieves one same-shard reviewed correction record by id; read-only, tolerant of malformed lines, and not proof | `read_only_reviewed_correction_inspection_non_authorizing` |
| `correction.influence.status` | Summarizes same-shard reviewed correction totals, target operations, possible influence candidates, warnings, and read-cap telemetry; read-only diagnostics and not proof | `read_only_reviewed_correction_influence_summary_non_authorizing` |
| `procedure_pack.candidate.propose` | Proposes explicit non-executable procedure pack candidates from reviewed corrections, reviewed negative knowledge, or `learning.status`; non-persistent unless separately reviewed | `candidate_only_no_pack_mutation_no_execution` |
| `procedure_pack.candidate.review` | Appends an accepted/rejected procedure pack candidate review record only; does not mutate packs or promote candidates | `append_only_reviewed_procedure_pack_candidate_no_pack_mutation` |
| `procedure_pack.candidate.reviewed.list` | Lists same-shard reviewed procedure pack candidate records from append-only storage; read-only and not proof/evidence | `read_only_reviewed_procedure_pack_candidate_inspection_non_authorizing` |
| `procedure_pack.candidate.reviewed.get` | Retrieves one same-shard reviewed procedure pack candidate record by id; read-only and not proof/evidence | `read_only_reviewed_procedure_pack_candidate_inspection_non_authorizing` |
| `verifier.candidate.execution.list` | Lists persisted verifier execution evidence-candidate records from same-shard JSONL storage; read-only and never proof/support | `read_only_verifier_execution_record_inspection_non_authorizing` |
| `verifier.candidate.execution.get` | Retrieves one persisted same-shard verifier execution evidence-candidate record by ID; read-only and never proof/support | `read_only_verifier_execution_record_inspection_non_authorizing` |
| `correction.list` | Reads existing correction-event state; returns empty when no state is visible | `read_only_state_inspection` |
| `correction.get` | Reads one existing correction event projection; missing IDs return `path_not_found` | `read_only_state_inspection` |
| `negative_knowledge.candidate.list` | Reads existing proposed negative-knowledge candidate state; returns empty when no state is visible | `read_only_state_inspection` |
| `negative_knowledge.candidate.get` | Reads one existing candidate projection; missing IDs return `path_not_found` | `read_only_state_inspection` |
| `negative_knowledge.record.list` | Reads reviewed negative-knowledge record projections; returns empty when no state is visible | `read_only_state_inspection` |
| `negative_knowledge.record.get` | Reads one reviewed record projection; missing IDs return `path_not_found` | `read_only_state_inspection` |
| `negative_knowledge.influence.list` | Reads recorded negative-knowledge influence projections; does not recompute or mutate triage/routing | `read_only_state_inspection` |
| `negative_knowledge.review` | Accepts or rejects a negative-knowledge candidate into append-only reviewed negative-knowledge storage; does not mutate corpus, packs, commands, verifiers, or global state | `append_only_reviewed_negative_knowledge_no_hidden_mutation` |
| `negative_knowledge.reviewed.list` | Lists same-shard reviewed negative-knowledge records from append-only storage with filters, warnings, and capacity telemetry; read-only and not proof/evidence | `read_only_reviewed_negative_knowledge_inspection_non_authorizing` |
| `negative_knowledge.reviewed.get` | Retrieves one same-shard reviewed negative-knowledge record by id; read-only, tolerant of malformed lines, and not proof/evidence | `read_only_reviewed_negative_knowledge_inspection_non_authorizing` |
| `trust_decay.candidate.list` | Reads proposed trust-decay candidate projections; does not apply trust changes | `read_only_state_inspection` |
| `negative_knowledge.candidate.review` | Legacy review validation surface; retained for compatibility while `negative_knowledge.review` is the durable append-only reviewed-record operation | `structured_unsupported_legacy_review_surface` |
| `negative_knowledge.record.expire` | Validates expiry requests but returns structured unsupported until safe append-only persistence is available | `structured_unsupported_without_persistence` |
| `negative_knowledge.record.supersede` | Validates supersede requests but returns structured unsupported until safe append-only persistence is available | `structured_unsupported_without_persistence` |
| `feedback.summary` | Returns event counts if workspace metadata resolves; otherwise `unsupported` flag | `requires_workspace_metadata` |
| `session.get` | Returns session data if session file exists; otherwise `path_not_found` | `requires_existing_session` |
| `project.autopsy` | Bounded read-only workspace inspection without command execution | `read_only_workspace_inspection` |
| `context.autopsy` | Runtime and persisted mounted-pack guidance plus bounded workspace artifact/input references for large inputs | `read_only_artifact_and_input_refs_runtime_and_persistent_pack_guidance` |
| `artifact.autopsy.inspect` | Seed non-code domain read-only artifact autopsy inspection | `read_only_artifact_autopsy_seed_non_authorizing` |

Stateless operations do not fake data. They return structurally valid empty
outputs that are safe for clients to consume.

State-inspection operations read existing task-session result paths or a
workspace-contained `statePath` JSON result file. They report `state_source` as
`no_state_found` when no persisted state is visible, or `support_graph` when
data was projected from a persisted support graph. Support-graph projection is
read-only and may omit fields that were not persisted in the graph; omitted
fields must not be interpreted as authorization, proof, approval, execution,
promotion, or pack mutation.

### Unsupported (structured unsupported response)

Kinds declared in `RequestKind` but absent from `IMPLEMENTED_KINDS` are exposed
in `operationMaturity` with `implemented:false`, `wired:false`, and
`productReady:false`. Requests to unsupported allowed operations return a
structured `unsupported` response or structured error rather than fake success.
Denied future mutations remain denied by capability policy.

| Operation | Status |
|-----------|--------|
| `verifier.run` | Not implemented |
| `verifier.candidate.execute` | Implemented; explicit approved-candidate execution only, bounded harness, append-only evidence-candidate record |
| `correction.apply` | Not implemented; denied mutation/future work |
| `negative_knowledge.promote` | Not implemented; denied mutation/future work |
| `pack.update_from_negative_knowledge` | Not implemented; denied mutation/future work |
| `trust_decay.apply` | Not implemented; denied mutation/future work |
| `command.run` | Not implemented |
| `artifact.patch.apply` | Not implemented |
| `pack.mount` / `pack.unmount` | Not implemented |
| `pack.import` / `pack.export` | Not implemented |
| `artifact.write.*` | Not implemented |
| `conversation.replay` | Not implemented |
| `hypothesis.generate` | Not implemented |
| `feedback.record` | Not implemented |
| `session.create` / `session.update` / `session.close` | Not implemented |

> No MCP bridge is implemented. GIP is consumed directly via the CLI or
> programmatic API. `protocol.describe` reports maturity per operation.

## Request Kinds

### Meta Operations
- `protocol.describe` — Protocol metadata, supported kinds, reasoning levels **(Implemented)**
- `capabilities.describe` — Current capability policies **(Implemented)**
- `engine.status` — Engine version, platform, operational status **(Implemented)**

### Project Inspection
- `project.autopsy` — Perform a read-only static analysis of the workspace **(Implemented)**
  - **Request**: `{"workspaceRoot": string}` (Note: GIP `workspace` CLI arg often maps to this)
  - **Response**: `{"projectAutopsy": {"autopsy_schema_version": "project_autopsy.v1", "read_only": true, "commands_executed": false, "verifiers_executed": false, "mutates_state": false, "operator_summary": {...}, "project_profile": {...}, "project_gap_report": {...}, "verifier_plan_candidates": [...], "state": "draft", "non_authorizing": true}, "readOnly": true, "commandsExecuted": false, "verifiersExecuted": false, "verifiersRegistered": false, "mutatesState": false, "non_authorizing": true}`
  - Canonicalizes the workspace root and performs bounded static inspection.
  - Does not execute commands, modify files, run verifiers, or mutate packs.
  - Safe command, verifier plan, risk, guidance, and operator-summary action candidates are non-authorizing candidates only; command/verifier candidates are returned with `executes_by_default: false`, and guidance/action candidates are returned with `applies_by_default: false` where relevant.

- `learning.loop.plan` — Derive a candidate-only learning-loop plan from Project Autopsy output **(Implemented)**
  - **Request**: optional JSON object with `planId` / `plan_id`, `maxEntries` / `max_entries`, and `maxDepth` / `max_depth`; workspace still comes from the GIP workspace boundary.
  - **Response**: `{"learningLoopPlan": {"schema_version": "learning_loop_plan.v1", "source": "project_autopsy", "candidate_only": true, "non_authorizing": true, "read_only": true, "mutates_state": false, "commands_executed": false, "verifiers_executed": false, "patches_applied": false, "packs_mutated": false, "corrections_applied": false, "negative_knowledge_promoted": false, "next_steps": [...], "verifier_candidate_refs": [...], "failure_ingestion_candidates": [...], "correction_candidate_placeholders": [...], "negative_knowledge_candidate_placeholders": [...], "procedure_pack_candidate_placeholders": [...], "unknowns": [...]}, "readOnly": true, "candidateOnly": true, "authorityEffect": "candidate"}`
  - Safe command candidates become approval-required verifier candidate references with `executes_by_default:false`.
  - Verifier gaps become missing-evidence steps. Risk surfaces become triage candidates. Guidance candidates become review-required procedure guidance steps. Unknowns become evidence-collection candidates.
  - Failure ingestion, correction, negative-knowledge, and procedure-pack entries are placeholders for later explicit review/execution lifecycles. They are not failures, corrections, accepted negative knowledge, or applied packs.
  - It does not execute commands, run verifiers, apply patches, mutate packs, mutate corpus, apply corrections, promote negative knowledge, mutate trust/snapshot/scratch state, grant support, or discharge proof.

- `verifier.candidate.propose_from_learning_plan` — Persist review-required verifier candidates from a learning-loop plan **(Implemented; append-only metadata only)**
  - **Request body**: `{"projectShard":"<shard>","learningLoopPlan":{...}}`
  - **Response**: `{"verifierCandidateProposal":{"candidateCount":1,"records":[...],"reviewRequired":true,"candidateOnly":true,"nonAuthorizing":true,"commandsExecuted":false,"verifiersExecuted":false,"executed":false,"producedEvidence":false,"authorityEffect":"candidate"}}`
  - Only `learningLoopPlan.verifier_candidate_refs[]` are converted. Invalid refs, empty argv, refs that do not require approval, or refs with `executes_by_default:true` are rejected closed.
  - The operation appends candidate metadata under `verifier_candidates/verifier_candidates.jsonl`; it does not execute commands or verifiers.

- `verifier.candidate.list` — List same-shard verifier candidate metadata **(Implemented; read-only)**
  - **Request body**: `{"projectShard":"<shard>","limit":128}`
  - **Response**: `{"verifierCandidateList":{"candidates":[{"status":"proposed|approved|rejected",...}],"readOnly":true,"candidateOnly":true,"nonAuthorizing":true,"commandsExecuted":false,"verifiersExecuted":false,"executed":false,"producedEvidence":false,"authorityEffect":"candidate"}}`
  - Listing folds append-only proposal/review records and never executes the candidate.
  - Candidate metadata and approval state are not evidence, proof, or support.

- `verifier.candidate.review` — Append approval/rejection metadata for a verifier candidate **(Implemented; append-only metadata only)**
  - **Request body**: `{"projectShard":"<shard>","candidateId":"<id>","decision":"approved|rejected","reviewedBy":"operator","reviewReason":"..." }`
  - **Response**: `{"verifierCandidateReview":{"status":"approved|rejected","approvalCreatesEvidence":false,"executed":false,"producedEvidence":false,...},"candidateOnly":true,"nonAuthorizing":true,"authorityEffect":"candidate"}`
  - Approval means approved for possible future execution only.
  - Review records do not run commands/verifiers, ingest failures, apply patches, mutate packs/corpus/corrections/negative knowledge, or create evidence/support.

- `context.autopsy` — Evaluate a context case with runtime/persisted mounted-pack guidance and optional bounded artifact/input references **(Implemented)**
  - **Request**: small JSON control plane with `context`, optional `packGuidance`, optional `artifactRefs`, and optional `context.input_refs` / `context.inputRefs`.
  - **Artifact ref schema**: `{"kind":"file"|"directory","path":"relative/path","purpose":"...","reason":"...","include":["src/**/*.zig"],"exclude":[".git/**","zig-out/**",".zig-cache/**"],"maxFileBytes":65536,"maxChunkBytes":32768,"maxFiles":128,"maxEntries":512,"maxBytes":524288}`.
  - **Artifact ref filters**: deterministic glob-style filters over workspace-relative paths. `*` and `?` match within one path segment, `**` as a full segment matches across path segments, and `/` is a literal path separator. Exclude filters win over include filters. Empty include filters include all non-excluded files.
  - **Response coverage**: `artifactCoverage` reports `artifactsRequested`, `filesConsidered`, `filesRead`, `bytesRead`, `filesSkipped`, `skipReasons`, `filesTruncated`, `truncationReasons`, `budgetHits`, and `unknowns`.
  - **Input ref schema**: `{"kind":"file","path":"relative/context.txt","id":"optional","label":"optional","purpose":"bounded transcript/log context","reason":"...","maxBytes":65536}`.
  - **Input ref behavior**: input refs are file-only textual context/log/transcript inputs. They resolve inside the workspace, read only bounded bytes, never execute or mutate, and do not echo raw file content in the response.
  - **Input coverage**: `inputCoverage` reports `inputRefsRequested`, `inputsConsidered`, `inputsRead`, `bytesRead`, `inputsSkipped`, `skipReasons`, `inputsTruncated`, `truncationReasons`, `budgetHits`, and `unknowns`.
  - The stdin JSON limit remains the 1 MiB control-plane boundary. Large content is referenced by path and read through bounded file/chunk/aggregate budgets.
  - Skipped, filtered, unsupported, unread, or truncated regions create explicit unknowns. They are not treated as false claims.
  - Loads only persisted autopsy guidance declared by mounted Knowledge Pack manifests; pack content remains a signal source, not proof.

### Sigil Inspection
- `sigil.inspect` — Inspect compiled Sigil bytecode and procedure records through GIP **(Implemented)**
  - **Request**: `{"source": string, "validationScope": "boot_control"|"scratch_session"}`. `sigilSource` and `validation_scope` are accepted aliases. If omitted, `validationScope` defaults to `boot_control`.
  - **Response**: `{"sigilInspection": {"status": "ok"|"validation_failed"|"parse_failed", "validation": {...}, "instructions": [...], "procedureInspectionRecords": [...], "safety": {...}, "disassemblyText": "..."}}`.
  - Compiles and validates Sigil source, then renders deterministic inspection data from the compiled program. It does not execute VM code.
  - Always reports `non_authorizing:true`, `read_only:true`, `executed:false`, `mutates_state:false`, and `authority_effect:"candidate"` in the safety block.
  - It cannot execute shell commands, mutate artifacts, packs, corpus, negative knowledge, trust state, snapshots, or scratch state, grant support, or bypass proof gates.
  - Scratch mutation-like procedure records such as BIND / ETCH / VOID remain candidate-only and require review plus verification.
  - Syntax and validation failures fail closed with structured GIP output and no execution.

### Corpus Ask
- `corpus.ask` reads only the selected live shard corpus. It does not ingest, mutate packs, mutate negative knowledge, run commands, run verifiers, or treat staged corpus as active knowledge.
- `answerDraft` remains gated by exact local recall only: case-insensitive exact token overlap and adjacent exact phrase evidence. Drafts cite `evidenceUsed`; approximate-only matches return `unresolved`.
- `similarCandidates` are approximate SimHash routing hints. They include Hamming distance, similarity score, reason, rank, and `nonAuthorizing: true`.
- Similarity candidates are not proof, are not semantic search, do not populate `evidenceUsed`, and cannot authorize an answer. No Transformers, embeddings, model adapters, or network calls are used.
- Capacity pressure is explicit. Skipped files, truncated live-corpus reads, truncated snippets, exact/sketch candidate caps, and max-result caps appear in `capacityTelemetry` and create `capacity_limited` unknowns or warnings. Dropped or skipped evidence is not learned data and cannot become negative evidence.
- Capacity warnings are diagnostic, not proof. They may recommend explicit expansion or spillover, but they never discharge support gates.
- `learningCandidates` are proposed review inputs only. A later `correction.propose` request can tie a user correction to `evidenceUsed.itemId`, similarity hints, unknowns, or capacity warnings, but `corpus.ask` itself never mutates corpus, packs, or negative knowledge.

### Correction Review

- `correction.propose` remains candidate-only and review-required. It does not persist, accept, reject, or mutate knowledge.
- `correction.review` is the explicit reviewed learning boundary. It accepts `projectShard` / `project_shard`, either a `correctionCandidate` snapshot or `correctionCandidateId`, `decision: "accepted" | "rejected"`, `reviewerNote`, optional `acceptedLearningOutputs`, and `rejectedReason` for rejected reviews.
- The response returns `reviewedCorrectionRecord`, `requiredReview:false`, `mutationFlags`, `authority`, storage metadata, and an accepted-only `futureBehaviorCandidate`.
- Reviewed correction records are stored as project-shard-local JSONL at `corrections/reviewed_corrections.jsonl` under the resolved project shard. The file is append-only: prior records are not rewritten, deleted, or silently compacted, and ordering is file append order.
- Accepted reviewed corrections are still `nonAuthorizing:true`, `treatedAsProof:false`, and `globalPromotion:false`. They may produce a future-behavior candidate or warning for later explicit lifecycles, but they do not discharge support gates and do not mutate corpus, packs, or negative knowledge.
- Rejected reviewed corrections persist the rejection and `rejectedReason`; they do not create future influence.
- `correction.reviewed.list` accepts `projectShard` / `project_shard`, optional `decision: "accepted" | "rejected" | "all"`, optional `operationKind` / `operation_kind`, `limit`, and `offset` / `cursor`. It returns `records`, `totalRead`, `returnedCount`, `malformedLines`, `warnings`, `capacityTelemetry`, `readOnly:true`, false mutation flags, and `authority.nonAuthorizing:true` / `treatedAsProof:false`.
- `correction.reviewed.get` accepts `projectShard` / `project_shard` and `id`. It returns `reviewedCorrectionRecord` when found, or `status:"not_found"` with an unknown when missing. Missing storage is tolerated, malformed JSONL lines become warnings/telemetry, and neither operation rewrites, compacts, deletes, accepts, rejects, promotes, executes commands, executes verifiers, mutates corpus, mutates packs, or mutates negative knowledge.
- `correction.influence.status` accepts `projectShard` / `project_shard`, optional `operationKind` / `operation_kind`, optional `includeRecords` / `include_records` defaulting to `false`, and optional `limit` when record echoing is enabled. It reads the same same-shard `corrections/reviewed_corrections.jsonl` under bounded record and byte caps, tolerates a missing file as a zero summary, and reports malformed JSONL lines as `warnings` plus `summary.malformedLines`.
- `correction.influence.status` returns `summary.totalRecords`, accepted/rejected counts, `operationKindCounts`, `correctionTypeCounts`, `influenceKindCounts`, suppression/stronger-evidence/verifier/negative-knowledge/corpus-update/pack-guidance/rule-update/future-behavior candidate counts, `capacityTelemetry`, false mutation flags, and `authority.nonAuthorizing:true`, `treatedAsProof:false`, `globalPromotion:false`. These counts are operator diagnostics only; they are not proof, evidence, support, review decisions, corpus updates, pack updates, negative knowledge, or global promotion.
- `learning.status` accepts `projectShard` / `project_shard`, optional `includeRecords` / `include_records` defaulting to `false`, optional `includeWarnings` / `include_warnings` defaulting to `true`, and optional `limit` when sampled records are included.
- `learning.status` reads only same-shard `corrections/reviewed_corrections.jsonl` and `negative_knowledge/reviewed_negative_knowledge.jsonl` under the reviewed-record byte and record caps. Missing files produce zero summaries. Malformed JSONL lines are warnings and counters. It never rewrites, compacts, deletes, reviews, accepts, rejects, promotes, mutates corpus, mutates packs, mutates correction/NK storage, executes commands, or executes verifiers.
- `learning.status` returns `learningStatus` with `correctionSummary`, `negativeKnowledgeSummary`, `influenceSummary`, `warningSummary`, `capacityTelemetry`, `storage`, false mutation flags, and `authority.nonAuthorizing:true`, `treatedAsProof:false`, `usedAsEvidence:false`, `supportGranted:false`, and `proofDischarged:false`. Scoreboard counts are diagnostics only; they are not proof, evidence, support, negative knowledge, correction review, corpus updates, pack guidance, verifier execution, or global promotion.
- `corpus.ask` reads accepted reviewed corrections from the same project shard only, with a bounded read limit. Missing `reviewed_corrections.jsonl` is treated as no influence. Malformed JSONL lines are exposed as `acceptedCorrectionWarnings` / `influenceTelemetry` and do not crash the ask.
- Accepted reviewed corrections can influence `corpus.ask` only as non-authorizing `correctionInfluences` and `futureBehaviorCandidates`: warnings, stronger-evidence requirements, verifier/check candidates, exact repeated bad-pattern suppression, or candidate-only negative-knowledge/corpus/pack guidance proposals. They are never copied into `evidenceUsed`, never become proof, never execute verifiers, and never mutate corpus, packs, or negative knowledge.
- `corpus.ask` can also read accepted reviewed negative knowledge from the same project shard only, with bounded record and byte limits. Missing `negative_knowledge/reviewed_negative_knowledge.jsonl` is treated as no influence. Malformed reviewed-NK JSONL lines are exposed as `acceptedNegativeKnowledgeWarnings` / `negativeKnowledgeTelemetry` and do not crash the ask.
- Accepted reviewed NK can influence `corpus.ask` only as non-authorizing `negativeKnowledgeInfluences` and `futureBehaviorCandidates`: warnings, penalties, stronger exact evidence requirements, verifier/check candidates, exact repeated known-bad answer suppression, or candidate-only pack/corpus/rule update proposals. Reviewed NK is never copied into `evidenceUsed`, never proves an answer, never executes verifiers, and never mutates corpus, packs, correction records, or negative knowledge.
- `rule.evaluate` can also read accepted reviewed corrections from the same project shard when `projectShard` / `project_shard` is supplied. The read is bounded and missing storage is no influence; malformed reviewed-correction lines become `acceptedCorrectionWarnings` and `influenceTelemetry`.
- Accepted reviewed corrections can influence `rule.evaluate` only as non-authorizing warnings, exact repeated-output suppression, stronger-review/check candidates, follow-up evidence requests, or future negative-knowledge/pack-guidance/rule-update candidates. They are never rule proof, never evidence, never support final answers, never execute verifiers or commands, and never mutate corpus, packs, negative knowledge, correction records, or unrelated shards.
- `rule.evaluate` can also read accepted reviewed NK from the same project shard when `projectShard` / `project_shard` is supplied. Matching is conservative and structural: operation kind when present, exact ids, exact/substring text over output/rule/summary/detail fields, and deterministic fingerprints. Accepted reviewed NK may warn, suppress exact repeated known-bad rule outputs, require stronger evidence or verifier/check candidates, or propose future pack/corpus/rule updates. It is never rule proof, never evidence, never support, never verifier or command execution, never mutation, and never cross-shard/global promotion.

### Reviewed Negative Knowledge

- Negative-knowledge candidates are proposed signal only. They may come from existing support-graph state or from accepted correction future-behavior candidates, but no candidate affects future behavior until an explicit `negative_knowledge.review` request accepts it.
- `negative_knowledge.review` accepts `projectShard` / `project_shard`, either a `negativeKnowledgeCandidate` snapshot or `negativeKnowledgeCandidateId`, `decision: "accepted" | "rejected"`, `reviewerNote`, optional `sourceCorrectionReviewId`, and `rejectedReason` when rejected.
- The response returns `reviewedNegativeKnowledgeRecord`, `requiredReview:false`, `readOnly:false`, `appendOnly:true`, storage metadata, mutation flags, authority flags, and an accepted-only `futureInfluenceCandidate`.
- Reviewed negative-knowledge records are stored as project-shard-local JSONL at `negative_knowledge/reviewed_negative_knowledge.jsonl` under the resolved project shard. The file is append-only: prior records are not rewritten, deleted, compacted, or reordered; ordering is file append order.
- Reviewed records store the candidate snapshot, source candidate id, optional source correction review id, `reviewDecision`, `reviewerNote`, `rejectedReason`, deterministic append-order timestamps, `influenceScope.kind:"project_shard"`, `nonAuthorizing:true`, `treatedAsProof:false`, `usedAsEvidence:false`, `globalPromotion:false`, and mutation flags.
- `negativeKnowledgeMutation:true` on `negative_knowledge.review` means only that a reviewed NK record was appended. It does not mean corpus mutation, pack mutation, global promotion, command execution, verifier execution, proof discharge, support grant, or application of influence.
- Accepted reviewed NK records are not proof and are not evidence. They may influence future `corpus.ask` and `rule.evaluate` behavior only in the same project shard as non-authorizing warnings, penalties, exact repeated-pattern suppression, stronger exact-evidence requirements, verifier/check candidates, or future pack/corpus/rule update candidates.
- Reviewed NK influence uses deterministic structural matching only: operation kind when available, exact id matches, exact or substring matches over disputed output, candidate summary/detail, rule id, output id, answer draft, evidence snippet/source path, original request summary, and deterministic FNV fingerprints. It does not use semantic matching, embeddings, Transformers, model adapters, cloud calls, or network calls.
- `negative_knowledge.reviewed.list` accepts `projectShard` / `project_shard`, optional `decision: "accepted" | "rejected" | "all"`, `limit`, and `offset` / `cursor`. It returns records in append order plus `totalRead`, `returnedCount`, `malformedLines`, warnings, capacity telemetry, `readOnly:true`, false read mutation flags, and non-authorizing authority flags.
- `negative_knowledge.reviewed.get` accepts `projectShard` / `project_shard` and `id`. It returns a matching record or `status:"not_found"` with an unknown. Missing storage is tolerated; malformed JSONL lines become warnings/telemetry.
- List/get never rewrite, compact, delete, accept, reject, promote, execute commands, execute verifiers, mutate corpus, mutate packs, mutate negative knowledge, treat NK as proof, use NK as evidence, or discharge support gates.

### Rule Evaluation
- `rule.evaluate` evaluates request-local structured facts against request-local rules. It is deterministic, bounded, and read-only.
- Facts are simple subject/predicate/object/source records. Rules contain `all` conditions, optional `any` conditions, and `emit` outputs.
- Supported output kinds are `risk_candidate`, `check_candidate`, `evidence_expectation`, `unknown`, and `follow_up_candidate`.
- Rules do not infer or append new facts. Recursive/cyclic fact output is unsupported and rejected as an invalid request.
- Outputs are candidate-only and non-authorizing. Check candidates always have `executesByDefault:false`; evidence expectations become pending obligations with `status:"pending"`, `executed:false`, and `treatedAsProof:false`.
- Rule firing cannot execute commands or verifiers, cannot mutate corpus, Knowledge Packs, or negative knowledge, and cannot discharge proof/support gates.
- The substrate is structural rule matching only. It does not use Transformers, embeddings, model adapters, network calls, or semantic black-box search.
- Fired-rule/output caps and rejected outputs appear in `capacityTelemetry`. Capacity warnings do not make any emitted candidate more authoritative.
- `correctionReviewCandidates` point at `correction.propose` for bad rule output, missing rules, unsafe candidates, misleading obligations, or capacity-limited evaluation. These review candidates are non-authorizing and not persisted.
- `acceptedCorrectionWarnings`, `correctionInfluences`, `futureBehaviorCandidates`, and `influenceTelemetry` may appear when same-shard accepted reviewed corrections match emitted rule candidates, obligations, unknowns, or explanation-trace fields by exact text, substring, or deterministic fingerprint. Matching is conservative and structural; no semantic search, embeddings, model adapters, Transformers, or network calls are used.
- `acceptedNegativeKnowledgeWarnings`, `negativeKnowledgeInfluences`, `futureBehaviorCandidates`, and `negativeKnowledgeTelemetry` may appear when same-shard accepted reviewed NK matches emitted rule candidates, obligations, unknowns, or explanation-trace fields by exact id, exact/substring text, or deterministic fingerprint. These fields are warnings/candidates only: `nonAuthorizing:true`, `treatedAsProof:false`, `usedAsEvidence:false`, `globalPromotion:false`, and mutation flags false.
  - Guidance matching is bounded and deterministic: structured tags/kinds/required fields are matched case-insensitively, keywords prefer structured context and artifact/input ref metadata before bounded JSON string/key inspection, and applied pack influences include non-authorizing `matchTrace` metadata.
  - Does not execute commands, run verifiers, mutate packs, or mutate negative knowledge.
  - Persisted Knowledge Pack autopsy guidance can be preflighted through the read-only `ghost_knowledge_pack validate-autopsy-guidance` operator tool; this is outside the GIP request surface and does not change `context.autopsy` response authority.
  - Preferred persisted guidance uses schema `ghost.autopsy_guidance.v1` with `packGuidance`; `pack_guidance` remains an accepted alias, and legacy unversioned array / `packGuidance` / `pack_guidance` shapes remain tolerated with validation warnings.
  - `ghost_knowledge_pack capabilities --json` exposes the binary version, command list, validate-autopsy-guidance flags, supported guidance schemas, and validation limit defaults/hard caps for CLI compatibility checks.

### Conversation
- `conversation.turn` — Process a user message through the engine. **(Implemented)**
  - **Request**: `{"message": string, "reasoningLevel": "quick" | "balanced" | "deep" | "max", "sessionId": string, "contextArtifacts": string[]}`
  - **Response**: Returns a `ConversationTurnResult` containing `summary`, `detail`, `suggestedNextActions`, and `intent` (classification, ambiguitySets, missingObligations).
  - **Result State Mapping**:
    - **Draft**: Non-authorizing planning output.
    - **Unresolved**: Missing info or ambiguity. See `suggestedNextActions` for human-friendly prompts (vs internal obligations).
    - **Verified**: Fully actionable output.
  - *Note*: This is the future path for `ghost_cli` migration.
- `conversation.replay` — Replay a session for determinism testing **(Not implemented yet)**

### Corpus-Grounded Ask
- `corpus.ask` — Answer from explicitly ingested live shard corpus evidence **(Implemented)**
  - **Phase 8 response additions**: `acceptedCorrectionWarnings`, `correctionInfluences`, `futureBehaviorCandidates`, and `influenceTelemetry` may appear when shard-local accepted reviewed corrections are read. All such objects remain `nonAuthorizing:true`, `treatedAsProof:false`, `globalPromotion:false`, with mutation flags false.
  - **Phase 11B response additions**: `acceptedNegativeKnowledgeWarnings`, `negativeKnowledgeInfluences`, `negativeKnowledgeTelemetry`, and NK-originated `futureBehaviorCandidates` may appear when shard-local accepted reviewed NK records are read. All such objects remain `nonAuthorizing:true`, `treatedAsProof:false`, `usedAsEvidence:false`, `globalPromotion:false`, with mutation flags false.
  - **Request**: `{"question": string}` or `{"message": string}`, plus optional `projectShard` / `project_shard`, `maxResults` / `max_results`, `maxSnippetBytes` / `max_snippet_bytes`, and `requireCitations` / `require_citations`.
  - **Response**: `{"corpusAsk":{"status":"answered"|"unknown","state":"draft"|"unresolved","permission":"none"|"unresolved","answerDraft": string optional,"evidenceUsed":[...],"unknowns":[...],"candidateFollowups":[...],"learningCandidates":[...],"trace":{...}}}`.
  - Uses only existing live corpus state created through explicit corpus ingestion/lifecycle paths. Staged corpus is not read as active knowledge.
  - Matching is bounded, deterministic, local exact recall over live corpus file excerpts. It uses case-insensitive exact token overlap plus adjacent exact phrase hits; it is not semantic search and does not use embeddings, Transformers, model adapters, or network calls.
  - `evidenceUsed` reports corpus lineage id/path/source path/source label/class/trust class, content hash, byte and line spans, bounded snippet with truncation flag, matched terms/phrase, match reason, provenance, score, and rank.
  - `capacityTelemetry` reports bounded retrieval pressure such as `truncatedInputs`, `truncatedSnippets`, `skippedFiles`, `budgetHits`, `maxResultsHit`, exact/sketch candidate caps, `capacityWarnings`, `unknownsCreated`, and expansion/spillover recommendations.
  - Unknowns include `no_corpus_available`, `insufficient_evidence`, `conflicting_evidence`, and `capacity_limited`. Weak, approximate-only, skipped, dropped, or truncated signals do not produce `answerDraft`; exact evidence may still produce a draft, but the partial coverage is disclosed.
  - `learningCandidates` are candidate-only, non-authorizing, and `treatedAsProof:false`. They are not persisted and do not mutate Knowledge Packs, corpus state, or negative knowledge.
  - Trace flags always report `corpusMutation:false`, `packMutation:false`, `negativeKnowledgeMutation:false`, `commandsExecuted:false`, and `verifiersExecuted:false`.

### Deterministic Rule Evaluation
- `rule.evaluate` — Evaluate bounded request facts/rules and return non-authorizing candidates, obligations, unknowns, and traces **(Implemented)**
  - **Request**: `{"facts":[{"subject": string,"predicate": string,"object": string,"source": string optional}],"rules":[{"id": string,"name": string,"when":{"all":[...],"any":[...]},"emit":[{"kind":"check_candidate"|"risk_candidate"|"evidence_expectation"|"unknown"|"follow_up_candidate","id": string,"summary": string,"detail": string optional}]}],"limits":{"maxFacts": int,"maxRules": int,"maxFiredRules": int,"maxOutputs": int}}`.
  - **Response**: `{"ruleEvaluation":{"nonAuthorizing":true,"candidateOnly":true,"proofDischarged":false,"supportGranted":false,"firedRules":[...],"emittedCandidates":[...],"emittedObligations":[...],"emittedUnknowns":[...],"correctionReviewCandidates":[...],"capacityTelemetry":{...},"explanationTrace":[...],"safetyFlags":{...}}}`.
  - Rule order and fact order are stable. Bounds are enforced before and during evaluation.
  - `capacityTelemetry` reports fired-rule and output caps as `maxFiredRulesHit`, `maxOutputsHit`, `maxRulesHit`, `rejectedOutputs`, `budgetHits`, `capacityWarnings`, and expansion recommendations. Capacity warnings are not proof and do not grant support.
  - Invalid rules and unsupported recursive fact outputs are rejected cleanly with `invalid_request`.

### Correction Proposal
- `correction.propose` — Propose a review-required correction candidate for a disputed output **(Implemented)**
  - **Request**: `{"operationKind": string, "originalRequestId": string optional, "originalRequestSummary": string optional, "disputedOutput": "answerDraft" | "evidenceUsed" | "unknown" | "rule_candidate" | "similarity_hint" | "capacity_warning" or {"kind": "...", "ref": string optional, "summary": string optional}, "userCorrection": string, "correctionType": "wrong_answer" | "missing_evidence" | "bad_evidence" | "outdated_corpus" | "misleading_rule" | "repeated_failed_pattern" | "unsafe_candidate", "evidenceRefs": string[] optional, "projectShard": string optional}`.
  - **Response**: `{"correctionProposal":{"status":"proposed"|"request_more_detail","requiredReview":true,"correctionCandidate":...,"learningCandidates":[...],"unknowns":[...],"mutationFlags":...,"authority":...}}`.
  - User correction is signal, not proof. Every correction candidate has `nonAuthorizing:true`, `treatedAsProof:false`, `state:"proposed"`, and `requiredReview:true`.
  - Learning candidates can propose negative-knowledge candidates, corpus update candidates, pack guidance candidates, verifier/check candidates, or follow-up evidence requests. They are not persisted and are not globally promoted.
  - Mutation flags remain false: `corpusMutation:false`, `packMutation:false`, `negativeKnowledgeMutation:false`, `commandsExecuted:false`, and `verifiersExecuted:false`.
  - Underspecified correction requests return `request_more_detail` with an explicit unknown instead of inventing a candidate. Malformed requests are rejected with structured `invalid_request` or JSON errors.

- `correction.review` — Accept or reject a correction candidate into append-only reviewed correction records **(Implemented; append-only persistence only)**
  - **Request**: `{"projectShard": string optional, "correctionCandidate": object optional, "correctionCandidateId": string optional, "decision": "accepted" | "rejected", "reviewerNote": string, "acceptedLearningOutputs": array optional, "rejectedReason": string required when rejected}`.
  - **Response**: `{"correctionReview":{"status":"reviewed","reviewedCorrectionRecord":object,"requiredReview":false,"futureBehaviorCandidate":object|null,"storage":{...},"mutationFlags":...,"authority":...}}`.
  - Records are appended to `corrections/reviewed_corrections.jsonl` in the selected project shard. The append-only storage contract forbids in-place rewrite, deletion, and compaction.
  - Accepted and rejected records remain non-authorizing. Accepted records may carry a future behavior candidate, but neither decision mutates corpus, packs, negative knowledge, commands, verifiers, or global promotion state.

- `correction.reviewed.list` — Inspect append-only reviewed correction records **(Implemented; read-only inspection only)**
  - **Request**: `{"projectShard": string optional, "decision": "accepted" | "rejected" | "all" optional, "operationKind": string optional, "limit": int optional, "offset": int optional}`.
  - **Response**: `{"correctionReviewedList":{"status":"ok","records":[...],"totalRead":int,"returnedCount":int,"malformedLines":int,"warnings":[...],"capacityTelemetry":{...},"readOnly":true,"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,...}}}`.

- `correction.reviewed.get` — Inspect one reviewed correction record by id **(Implemented; read-only inspection only)**
  - **Request**: `{"projectShard": string optional, "id": string}`.
  - **Response**: `{"correctionReviewedGet":{"status":"ok"|"not_found","reviewedCorrectionRecord":object|null,"unknown": object optional,"totalRead":int,"malformedLines":int,"warnings":[...],"capacityTelemetry":{...},"readOnly":true,"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,...}}}`.

- `correction.influence.status` — Summarize reviewed correction influence diagnostics **(Implemented; read-only diagnostics only)**
  - **Request**: `{"projectShard": string optional, "operationKind": string optional, "includeRecords": bool optional, "limit": int optional}`.
  - **Response**: `{"correctionInfluenceStatus":{"status":"ok","projectShard":string,"readOnly":true,"summary":{...},"warnings":[...],"capacityTelemetry":{...},"storage":{...},"records":[...] optional,"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,"globalPromotion":false,...}}}`.

- `learning.status` — Summarize reviewed correction and reviewed negative-knowledge loop diagnostics **(Implemented; read-only scoreboard only)**
  - **Request**: `{"projectShard": string optional, "includeRecords": bool optional, "includeWarnings": bool optional, "limit": int optional}`.
  - **Response**: `{"learningStatus":{"status":"ok","projectShard":string,"readOnly":true,"correctionSummary":{...},"negativeKnowledgeSummary":{...},"influenceSummary":{...},"warningSummary":{...},"capacityTelemetry":{...},"storage":{...},"records":[...] optional,"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,"usedAsEvidence":false,"globalPromotion":false,...}}}`.
  - The scoreboard reads only same-shard reviewed JSONL files and treats counts as diagnostics, not proof, evidence, support, review decisions, mutation, hidden learning, or global promotion.

- `procedure_pack.candidate.propose` — Propose an explicit procedure pack candidate **(Implemented; candidate-only, non-persistent)**
  - **Request**: `{"projectShard": string optional, "sourceKind": "reviewed_correction" | "reviewed_negative_knowledge" | "learning_status", "sourceReviewId": string required except for learning_status, "candidateKind": string optional}`.
  - **Response**: `{"procedurePackCandidatePropose":{"status":"candidate"|"not_found","procedurePackCandidate":object,"sourceRecord":object|null,"storage":{"persisted":false,...},"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,"usedAsEvidence":false,"executesByDefault":false,"packMutation":false,"globalPromotion":false,...}}}`.
  - Candidate steps are structured descriptions with `executable:false`. Proposals do not persist themselves, mutate packs, execute commands/verifiers, become evidence/proof/support, or promote globally.

- `procedure_pack.candidate.review` — Accept or reject a procedure pack candidate into append-only reviewed candidate storage **(Implemented; append-only candidate review only)**
  - **Request**: `{"projectShard": string optional, "procedurePackCandidate": object, "decision": "accepted" | "rejected", "reviewerNote": string optional, "rejectedReason": string optional}`.
  - **Response**: `{"procedurePackCandidateReview":{"status":"reviewed","reviewedProcedurePackCandidateRecord":object,"storage":{"path":string,"appendOnly":true,...},"mutationFlags":...,"authority":...}}`.
  - Records are appended to `procedure_packs/reviewed_pack_candidates.jsonl` in the selected project shard. Review stores candidate lifecycle state only; it does not write or mutate any pack.

- `procedure_pack.candidate.reviewed.list` / `procedure_pack.candidate.reviewed.get` — Inspect reviewed procedure pack candidate records **(Implemented; read-only inspection only)**
  - **Request list**: `{"projectShard": string optional, "decision": "accepted" | "rejected" | "all" optional, "limit": int optional, "offset": int optional}`.
  - **Request get**: `{"projectShard": string optional, "id": string}`.
  - Both return append-order records, warnings, capacity telemetry, storage flags, false mutation flags, and non-authorizing authority flags. Missing storage is empty/not-found; malformed JSONL lines become warnings.

- `negative_knowledge.review` — Accept or reject a negative-knowledge candidate into append-only reviewed negative-knowledge records **(Implemented; append-only persistence only)**
  - **Request**: `{"projectShard": string optional, "negativeKnowledgeCandidate": object optional, "negativeKnowledgeCandidateId": string optional, "decision": "accepted" | "rejected", "reviewerNote": string, "rejectedReason": string required when rejected, "sourceCorrectionReviewId": string optional}`.
  - **Response**: `{"negativeKnowledgeReview":{"status":"reviewed","reviewedNegativeKnowledgeRecord":object,"requiredReview":false,"readOnly":false,"appendOnly":true,"futureInfluenceCandidate":object|null,"storage":{...},"mutationFlags":...,"authority":...}}`.
  - Records are appended to `negative_knowledge/reviewed_negative_knowledge.jsonl` in the selected project shard. Accepted and rejected records remain non-authorizing and do not mutate corpus, packs, commands, verifiers, or global promotion state.
  - Accepted records can later influence same-shard `corpus.ask` and `rule.evaluate` as warnings, exact suppression, stronger evidence/verifier requirements, or future behavior candidates. Rejected records do not influence.

- `negative_knowledge.reviewed.list` — Inspect append-only reviewed negative-knowledge records **(Implemented; read-only inspection only)**
  - **Request**: `{"projectShard": string optional, "decision": "accepted" | "rejected" | "all" optional, "limit": int optional, "offset": int optional}`.
  - **Response**: `{"reviewedNegativeKnowledge":{"status":"ok","records":[...],"totalRead":int,"returnedCount":int,"malformedLines":int,"warnings":[...],"capacityTelemetry":{...},"readOnly":true,"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,"usedAsEvidence":false,...}}}`.

- `negative_knowledge.reviewed.get` — Inspect one reviewed negative-knowledge record by id **(Implemented; read-only inspection only)**
  - **Request**: `{"projectShard": string optional, "id": string}`.
  - **Response**: `{"reviewedNegativeKnowledge":{"status":"found"|"not_found","reviewedNegativeKnowledgeRecord":object|null,"unknown": object optional,"totalRead":int,"malformedLines":int,"warnings":[...],"capacityTelemetry":{...},"readOnly":true,"mutationFlags":...,"authority":{"nonAuthorizing":true,"treatedAsProof":false,"usedAsEvidence":false,...}}}`.

### Artifacts
- `artifact.read` — Read file content (workspace-bounded) **(Implemented)**
- `artifact.list` — List directory entries **(Implemented)**
- `artifact.policy.describe` — Inspect active domain policy metadata **(Implemented; read-only)**
- `artifact.autopsy.inspect` — Seed read-only non-code artifact inspection **(Implemented)**
  - **Request**: `{"domain": "documentation_audit" | "recipe_consistency"}`
  - **Response**: `{"artifactAutopsyInspect": {"autopsy_schema_version": "...", "read_only": true, ...}}`
  - Returns hardcoded fixtures for now to seed the architecture.
- `artifact.search` — Search for patterns in workspace **(Not implemented yet)**
- `artifact.patch.propose` — Propose edits (non-authorizing). **(Implemented)**
  - **Request**: `{"path": string, "edits": [{"editId": string, "span": {"startLine": int, "startCol": int, "endLine": int, "endCol": int}, "replacement": string, "precondition": {"expectedText": string, "expectedHash": int}}]}`
  - **Response**: Returns a non-authorizing `patchProposal` containing the edits, preview diff, and `requiresApproval: true`. Does not modify files.
  - **Limitations**: Does not verify correctness of the patch logic. `previewDiff` is currently a stub/minimal.
- `artifact.patch.apply` — Apply edits (requires approval). **(Not implemented yet)**
- `artifact.write.propose` — Propose new file (non-authorizing) **(Not implemented yet)**
- `artifact.write.apply` — Write new file (requires approval) **(Not implemented yet)**

### Verification
- `verifier.list` — List registered verifier adapters **(Implemented)**
  - **Request**: `{}`
  - **Response**: `{"adapters": [{"adapterId": "...", "domain": "...", "hookKind": "...", "inputArtifactTypes": [...], "requiredEntityKinds": [...], "requiredRelationKinds": [...], "requiredObligations": [...], "budgetCost": int, "evidenceKind": "...", "safeLocal": bool, "external": bool, "enabled": bool}]}`
  - Returns the builtin adapter registry. Does not run any verifier.
  - `safeLocal: true` indicates the adapter runs without external process execution.
  - `external: true` indicates the adapter requires build/test/runtime execution harness.
- `verifier.run` — Run a specific verifier **(Not implemented yet)**
- `verifier.candidate.execution.list` — Inspect verifier candidate execution jobs **(Implemented — inspection only)**
  - **Request**: `{"projectShard": string, "candidateId": string (optional), "statusFilter": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"executions": [<verifier_execution_record>], "counts": {"total": int, "emitted": int, "passed": int, "failed": int, "timed_out": int, "disallowed": int, "rejected": int, "unknown": int}, "projectShard": string, "max_items": int, "read_only": true, "non_authorizing": true, "commands_executed": false, "verifiers_executed": false, "mutates_state": false, "support_granted": false, "proof_granted": false, "state_source": "verifier_execution_records_jsonl", "telemetry": {...}, "trace": {...}}`
  - Read-only. Does not schedule, run, approve, retry, or execute verifiers.
  - Reads existing same-shard records from `<project shard>/verifier_executions/verifier_execution_records.jsonl`. Empty output means no persisted execution records were visible; no evidence is not negative evidence.
- `verifier.candidate.execution.get` — Inspect one execution job/result by ID **(Implemented — inspection only)**
  - **Request**: `{"projectShard": string, "executionId": string}`
  - **Response**: `{"execution": <verifier_execution_record>, "projectShard": string, "executionId": string, "read_only": true, "non_authorizing": true, "commands_executed": false, "verifiers_executed": false, "mutates_state": false, "support_granted": false, "proof_granted": false, "state_source": "verifier_execution_records_jsonl", "telemetry": {...}, "trace": {...}}`; missing IDs return structured `path_not_found`.
  - Stored records contain bounded stdout/stderr snippets captured at execution time. Inspection does not read unbounded logs and does not treat pass/fail as support, proof, correction, negative knowledge, patch, pack, corpus, trust, snapshot, or scratch authority.
- `verifier.candidate.execute` — Execute an approved verifier candidate **(Implemented; explicit confirmation required)**
  - **Request**: `{"projectShard": string, "candidateId": string, "workspaceRoot": string, "confirmExecute": true, "timeoutMs": int optional, "maxOutputBytes": int optional}`.
  - The candidate must already exist in same-shard verifier candidate metadata with folded `status:"approved"`.
  - The candidate command is replayed as argv tokens through `src/execution.zig`; shell strings, non-allowlisted commands, workspace escapes, and oversized argv are rejected by the bounded harness.
  - Successful or failed spawned executions append `<project shard>/verifier_executions/verifier_execution_records.jsonl`.
  - Validation rejections and disallowed commands return structured `executed:false`, `commandsExecuted:false`, `verifiersExecuted:false`, `producedEvidence:false` and do not append evidence.
  - Passing execution produces a verifier execution evidence candidate only. It does not grant support or proof.
  - Failing execution produces a verifier execution evidence candidate only. It does not apply corrections, promote negative knowledge, apply patches, mutate packs, or mutate corpus.
  - **Response**: `{"verifierCandidateExecution":{"status":"passed|failed|timed_out|rejected|disallowed","executionRecord":{...},"executed":bool,"commandsExecuted":bool,"verifiersExecuted":bool,"producedEvidence":bool,"evidenceCandidate":bool,"nonAuthorizing":true,"supportGranted":false,"proofGranted":false,"correctionApplied":false,"negativeKnowledgePromoted":false,"patchApplied":false,"corpusMutation":false,"packMutation":false,"mutatesState":bool,"authorityEffect":"evidence_candidate"}}`
- `hypothesis.verifier.schedule` — Schedule verifier for hypothesis **(Not implemented yet)**

### Corrections
- `correction.list` — Inspect correction events **(Implemented — inspection only)**
  - **Request**: `{"sessionId": string (optional), "artifactRef": string (optional), "correctionKind": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"corrections": [], "counts_by_correction_kind": {...}, "max_items": int, "read_only": true, "non_authorizing": true, "state_source": "no_state_found" | "support_graph", "trace": {...}}`
  - A `correction_event` records state transition evidence: a previous state was contradicted and an updated state was produced from linked evidence.
  - Correction is not proof. It remains non-authorizing and deterministic.
- `correction.get` — Inspect one correction event by ID **(Implemented — inspection only)**
  - **Request**: `{"correctionId": string}`
  - **Response**: Existing correction event projection plus linked evidence and negative-knowledge candidate refs; missing IDs return structured `path_not_found`.
  - Support-graph projections may omit original correction fields unavailable in persisted graph state.
- `correction.apply` — Apply a correction mutation **(Not implemented; denied mutation/future work)**

### Negative Knowledge
- `negative_knowledge.candidate.list` — Inspect proposed negative-knowledge candidates **(Implemented — inspection only)**
  - **Request**: `{"sessionId": string (optional), "candidateKind": string (optional), "scope": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"candidates": [], "counts": {"total": 0, "failed_hypothesis": 0, "failed_patch": 0, "failed_repair_strategy": 0, "misleading_pack_signal": 0, "insufficient_test": 0, "unsafe_verifier_candidate": 0, "overbroad_rule": 0}, "max_items": int, "read_only": true, "non_authorizing": true, "promoted": false, "pack_authorized": false, "state_source": "no_state_found" | "support_graph"}`
  - Candidates are proposed only. They are not promoted, not pack-authorized, and not proof.
- `negative_knowledge.candidate.get` — Inspect one negative-knowledge candidate by ID **(Implemented — inspection only)**
  - **Request**: `{"candidateId": string}`
  - **Response**: Existing candidate projection plus correction/evidence refs and promotion status; missing IDs return structured `path_not_found`.
  - Support-graph projections may omit original candidate fields unavailable in persisted graph state.
- `negative_knowledge.record.list` — Inspect reviewed negative-knowledge records **(Implemented — inspection only)**
  - **Request**: `{"sessionId": string (optional), "projectShard": string (optional), "statePath": string (optional), "statusFilter": string (optional), "kindFilter": string (optional), "scopeFilter": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"records": [], "counts": {"total": 0, "accepted": 0, "rejected": 0, "expired": 0, "superseded": 0, "proposed": 0}, "state_source": "no_state_found" | "support_graph" | "session_state" | "state_path", "read_only": true, "non_authorizing": true}`
  - Listing records does not apply influence, mutate routing, mutate packs, or promote anything globally.
- `negative_knowledge.record.get` — Inspect one reviewed negative-knowledge record **(Implemented — inspection only)**
  - **Request**: `{"recordId": string, "statePath": string (optional), "sessionId": string (optional)}`
  - **Response**: Full support-graph projection with review metadata, influence metadata, linked correction/candidate refs, and projection-completeness metadata.
  - Missing IDs return structured `path_not_found`.
- `negative_knowledge.influence.list` — Inspect recorded influence projections **(Implemented — inspection only)**
  - **Request**: `{"sessionId": string (optional), "statePath": string (optional), "hypothesisId": string (optional), "artifactRef": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"influence_results": [], "counts": {"matches": 0, "triage_penalties": 0, "verifier_requirements": 0, "suppressions": 0, "routing_warnings": 0, "trust_decay_candidates": 0}, "mutated_triage": false, "mutated_routing": false}`
  - This endpoint reads recorded/projection state only. It does not recompute expensive influence and does not mutate triage or routing.
- `trust_decay.candidate.list` — Inspect trust-decay candidates **(Implemented — inspection only)**
  - **Request**: `{"sessionId": string (optional), "statePath": string (optional), "sourceRef": string (optional), "packId": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"candidates": [{"id": "...", "source_ref": "...", "reason": "...", "evidence_ref": "...", "suggested_delta": null, "status": "proposed", "non_authorizing": true}], "counts": {"total": int, "proposed": int}, "trust_mutation": false}`
  - Trust decay candidates are proposals only. GIP does not directly change pack or source trust.
- `negative_knowledge.candidate.review` — Review a candidate **(Validation implemented; persistence unsupported)**
  - **Request**: `{"candidateId": string, "decision": "accept" | "reject" | "defer", "approvalContext": {"approvedBy": string, "approvalKind": "user" | "test_fixture" | "policy", "reason": string, "scope": string, "allowedInfluence": string[]}, "statePath": string (optional), "sessionId": string (optional)}`
  - Accept requires explicit `approvalContext`. Reject requires `reason`. Defer is allowed.
  - Current behavior after validation is a structured `unsupported` result because GIP does not yet have a safe append-only persistence target for review events.
  - It does not mutate packs, promote global authority, execute verifiers, or alter support/proof permission.
- `negative_knowledge.record.expire` / `negative_knowledge.record.supersede` — Record lifecycle mutation **(Validation implemented; persistence unsupported)**
  - Both require explicit reasons. Supersede also requires `newRecordId`.
  - Current behavior after validation is structured `unsupported` until safe append-only persistence is available.
- `negative_knowledge.promote` — Promote a candidate to negative knowledge **(Not implemented; denied mutation/future work)**
  - Global promotion remains unsupported. `global_candidate` is only a candidate for future export/review, not global authority.

Negative knowledge lifecycle:

```text
correction event
→ negative knowledge candidate
→ review request
→ accepted / rejected / expired / superseded record
→ scoped influence projection
```

Accepted negative knowledge remains non-authorizing. It may warn, penalize
triage, require stronger verifiers, suppress exact repeated failed patterns, or
propose trust-decay candidates. It cannot prove claims, support outputs,
discharge obligations, execute verifiers, apply patches, mutate packs, or
promote global authority.

### Hypotheses
- `hypothesis.generate` — Generate hypotheses from context **(Not implemented yet)**
- `hypothesis.list` — List active hypotheses **(Implemented — stateless)**
  - **Request**: `{"sessionId": string (optional), "artifactRef": string (optional), "statusFilter": string (optional), "maxItems": int (optional, default 128, max 128)}`
  - **Response**: `{"hypotheses": [], "counts": {"total": 0, "proposed": 0, "triaged": 0, "selected": 0, "suppressed": 0, "verified": 0, "rejected": 0, "blocked": 0, "unresolved": 0}, "maxItems": int}`
  - Hypotheses are always non-authorizing.
  - Returns empty list with zero counts — no fake hypotheses generated.
  - Does not generate new hypotheses in the list operation.
  - Will return real data when GIP bridges to active hypothesis context.
- `hypothesis.triage` — Triage and select hypotheses **(Implemented — stateless)**
  - **Request**: `{"sessionId": string (optional), "artifactRef": string (optional), "maxItems": int (optional, default 128, max 128), "includeSuppressed": bool (optional)}`
  - **Response**: `{"triageSummary": {"total": 0, "selected": 0, "suppressed": 0, "duplicate": 0, "blocked": 0, "deferred": 0, "budgetHits": 0, "scoringPolicyVersion": "hypothesis_triage_v1"}, "items": [], "maxItems": int, "includeSuppressed": bool}`
  - Does not schedule verifiers.
  - `selected` means selected for investigation, not supported.
  - Returns empty triage summary — no fake triage data.

### Knowledge Packs
- `pack.list` — List mounted packs **(Implemented)**
  - **Request**: `{}`
  - **Response**: `{"packs": [{"packId": "...", "version": "...", "mounted": bool, "enabled": bool, "domainFamily": "...", "trustClass": "...", "summary": "...", "nonAuthorizingInfluence": true}]}`
  - Pack listing does not mount, import, or export packs.
  - Pack signals remain non-authorizing.
  - If no mount registry exists, returns `ok` with empty list.
- `pack.inspect` — Inspect pack manifest **(Implemented)**
  - **Request**: `{"packId": string, "version": string (optional, default "v1")}`
  - **Response**: `{"manifestSummary": {...}, "trustFreshnessStatus": {...}, "contentSummary": {...}, "provenance": {...}, "influencePolicy": "non_authorizing", "nonAuthorizing": true}`
  - Does not mount pack. Does not mutate registry.
  - Missing pack returns structured error with `path_not_found`.
- `pack.mount` / `pack.unmount` — Mount/unmount packs **(Not implemented yet)**
- `pack.import` / `pack.export` — Import/export packs **(Not implemented yet)**
- `pack.distill.*` — Distillation operations **(Not implemented yet)**
- `pack.update_from_negative_knowledge` — Mutate a pack from negative knowledge **(Not implemented; denied mutation/future work)**

### Feedback
- `feedback.record` — Record feedback event **(Not implemented yet)**
- `feedback.replay` — Replay feedback for reinforcement **(Not implemented yet)**
- `feedback.summary` — Summarize feedback history **(Implemented — requires workspace metadata)**
  - **Request**: `{"projectShard": string (optional)}`
  - **Response**: `{"eventCounts": {"total": int}, "reinforcementFamilies": ["intent_interpretation", "action_surface", "verifier_pattern"]}`
  - If workspace/feedback data is unavailable, returns `{"unsupported": true, "reason": "..."}` with status `ok`.
  - Returns real event counts when project shard has feedback data.

### Session
- `session.create` — Create session **(Not implemented yet)**
- `session.get` — Read session by ID **(Implemented — requires existing session)**
  - **Request**: `{"sessionId": string, "projectShard": string (optional)}`
  - **Response**: `{"sessionId": "...", "historyCount": int, "currentIntent": {...}, "pendingObligations": int, "pendingAmbiguities": int, "lastResultState": {...}}`
  - Returns real session data loaded from disk if session file exists.
  - Missing session returns structured error with `path_not_found`.
- `session.update` / `session.close` — **(Not implemented yet)**

### Command
- `command.run` — Execute allowlisted command (sandboxed) **(Not implemented)**

## Capability Model

| Capability | Default Policy | Read-Only |
|-----------|---------------|-----------|
| `artifact.read` | allowed | yes |
| `artifact.list` | allowed | yes |
| `artifact.search` | allowed | yes |
| `artifact.patch.propose` | allowed | yes |
| `artifact.patch.apply` | requires_approval | no (mutation) |
| `artifact.write.propose` | allowed | yes |
| `artifact.write.apply` | requires_approval | no (mutation) |
| `corpus.ask` | allowed | yes |
| `rule.evaluate` | allowed | yes |
| `sigil.inspect` | allowed | yes |
| `learning.status` | allowed | yes |
| `correction.propose` | allowed | yes |
| `correction.review` | allowed | yes |
| `correction.reviewed.list` | allowed | yes |
| `correction.reviewed.get` | allowed | yes |
| `correction.influence.status` | allowed | yes |
| `procedure_pack.candidate.propose` | allowed | yes |
| `procedure_pack.candidate.review` | allowed | yes |
| `procedure_pack.candidate.reviewed.list` | allowed | yes |
| `procedure_pack.candidate.reviewed.get` | allowed | yes |
| `hypothesis.list` | allowed | yes |
| `hypothesis.triage` | allowed | yes |
| `verifier.list` | allowed | yes |
| `verifier.candidate.execution.list` | allowed | yes |
| `verifier.candidate.execution.get` | allowed | yes |
| `correction.list` | allowed | yes |
| `correction.get` | allowed | yes |
| `negative_knowledge.candidate.list` | allowed | yes |
| `negative_knowledge.candidate.get` | allowed | yes |
| `negative_knowledge.record.list` | allowed | yes |
| `negative_knowledge.record.get` | allowed | yes |
| `negative_knowledge.influence.list` | allowed | yes |
| `trust_decay.candidate.list` | allowed | yes |
| `negative_knowledge.candidate.review` | requires_approval | no (unsupported persistence) |
| `negative_knowledge.record.expire` | requires_approval | no (unsupported persistence) |
| `negative_knowledge.record.supersede` | requires_approval | no (unsupported persistence) |
| `pack.list` | allowed | yes |
| `pack.inspect` | allowed | yes |
| `feedback.summary` | allowed | yes |
| `session.get` | allowed | yes |
| `project.autopsy` | allowed | yes |
| `context.autopsy` | allowed | yes |
| `artifact.policy.describe` | allowed | yes |
| `artifact.autopsy.inspect` | allowed | yes |
| `command.run` | allowlist | no (not implemented) |
| `verifier.run` | allowed | no (not implemented) |
| `verifier.candidate.execute` | requires_approval | yes |
| `correction.apply` | denied | no (not implemented) |
| `negative_knowledge.promote` | denied | no (not implemented) |
| `pack.update_from_negative_knowledge` | denied | no (not implemented) |
| `trust_decay.apply` | denied | no (not implemented) |
| `pack.mount` | requires_approval | no (not implemented) |
| `pack.unmount` | requires_approval | no (not implemented) |
| `pack.import` | requires_approval | no (not implemented) |
| `pack.export` | requires_approval | no (not implemented) |
| `feedback.record` | allowed | no (mutation) |
| `session.write` | allowed | no (mutation) |
| `network.access` | denied | n/a |

### Command Allowlist

Only these commands are permitted: `zig`, `git`, `ls`, `find`, `cat`,
`head`, `tail`, `wc`, `grep`, `diff`, `echo`, `test`, `stat`.

Maximum timeout: 30 seconds. Maximum output: 256KB.

## Safety Guarantees

1. **No arbitrary shell access** — commands are allowlisted
2. **No writes without approval** — patch/write apply requires explicit approval
3. **Hypotheses are non-authorizing** — they never grant permission
4. **Path containment** — all paths validated against workspace boundary
5. **Network denied by default** — no external requests
6. **Draft semantics** — all outputs start as drafts with non-authorization notices
7. **Pack signals are non-authorizing** — pack influence never grants permission
8. **Read-only inspection is safe** — list/inspect/summary operations never mutate state
9. **Corrections are not proof** — correction events only expose state transition evidence
10. **Negative knowledge remains non-authorizing** — records and influence projections never support output
11. **No automatic negative-knowledge mutation** — GIP does not mutate packs, apply trust decay, or promote global authority
12. **Large input stays bounded** — `context.autopsy` uses artifact references, filters, chunked reads, budgets, coverage, and explicit unknowns rather than unbounded stdin JSON
13. **Corpus ask is not proof** — `corpus.ask` can draft from cited corpus evidence, but corpus text alone does not verify or authorize supported output
14. **Rules are not proof** — `rule.evaluate` emits candidate checks, obligations, risks, unknowns, and follow-ups only; rule firing cannot authorize supported output
15. **Reviewed corrections are not proof** — `correction.review` persists explicit accept/reject records, `correction.reviewed.list` / `correction.reviewed.get` inspect them read-only, `correction.influence.status` summarizes potential influence diagnostics read-only, and accepted records may influence future `corpus.ask` / `rule.evaluate` behavior as warnings, exact suppression, or candidate-only follow-ups, but they remain non-authorizing and cannot satisfy proof/support gates
16. **Reviewed correction influence is shard-scoped and non-mutating** — accepted correction influence reads only the same project shard and does not mutate corpus, packs, negative knowledge, commands, verifiers, or unrelated shards
17. **Reviewed negative knowledge influence is caution only** — accepted reviewed NK can warn, suppress exact repeated known-bad outputs, require stronger evidence/verifier candidates, or propose future behavior candidates for same-shard `corpus.ask` / `rule.evaluate`, but it is never evidence, proof, support, verifier execution, mutation, semantic matching, or global promotion
18. **Learning status is a scoreboard only** — `learning.status` summarizes reviewed correction and reviewed NK counts for one shard, but the scoreboard is not proof, evidence, support, review authority, hidden learning, mutation, or global promotion
19. **Procedure pack candidates are lifecycle candidates only** — `procedure_pack.candidate.*` can propose, review, and inspect candidate procedures, but candidates never mutate packs, execute commands/verifiers, become proof/evidence/support, auto-promote, or promote globally

## CLI Usage

```bash
# Direct kind invocation
ghost_gip protocol.describe
ghost_gip engine.status
ghost_gip artifact.read --workspace /path/to/project --path src/main.zig

# JSON request
ghost_gip --json '{"gipVersion":"gip.v0.1","kind":"protocol.describe"}'

# Stdin pipe
echo '{"gipVersion":"gip.v0.1","kind":"engine.status"}' | ghost_gip --stdin

# Inspection operations
echo '{"gipVersion":"gip.v0.1","kind":"verifier.list"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"pack.list"}' | ghost_gip --stdin --workspace /path/to/project
echo '{"gipVersion":"gip.v0.1","kind":"hypothesis.list"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"hypothesis.triage","maxItems":16}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"verifier.candidate.execution.list","projectShard":"default"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"correction.list"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"negative_knowledge.candidate.list"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"pack.inspect","packId":"my-pack"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"feedback.summary"}' | ghost_gip --stdin --workspace /path/to/project
echo '{"gipVersion":"gip.v0.1","kind":"session.get","sessionId":"my-session"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"corpus.ask","projectShard":"my-project","question":"what does the corpus say about retention?","maxResults":3}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"rule.evaluate","facts":[{"subject":"change","predicate":"touches","object":"runtime"}],"rules":[{"id":"runtime-check","name":"Runtime check expectation","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check-runtime","summary":"Review runtime behavior before support."}]}]}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"sigil.inspect","source":"LOOM CPU_ONLY\nSCAN \"system_memory\"","validationScope":"boot_control"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"correction.review","projectShard":"my-project","correctionCandidateId":"correction:candidate:example","decision":"accepted","reviewerNote":"reviewed by operator","acceptedLearningOutputs":[{"kind":"verifier_check_candidate","status":"candidate"}]}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"project.autopsy"}' | ghost_gip --stdin --workspace /path/to/project
echo '{"gipVersion":"gip.v0.1","kind":"context.autopsy","context":{"summary":"inspect source context"},"artifactRefs":[{"kind":"directory","path":".","include":["src/**/*.zig"],"exclude":[".git/**","zig-out/**",".zig-cache/**","node_modules/**"],"maxChunkBytes":32768,"maxFiles":64}]}' | ghost_gip --stdin --workspace /path/to/project
echo '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency"}' | ghost_gip --stdin
```

## Examples

See `examples/gip/` for sample request JSON files:

- `hypothesis_list.json` — hypothesis.list request
- `hypothesis_triage.json` — hypothesis.triage request
- `verifier_list.json` — verifier.list request
- `verifier_candidate_execution_list.json` — verifier.candidate.execution.list request
- `correction_list.json` — correction.list request
- `negative_knowledge_candidate_list.json` — negative_knowledge.candidate.list request
- `pack_list.json` — pack.list request
- `pack_inspect.json` — pack.inspect request
- `corpus_ask.json` — corpus.ask request over live shard corpus
- `context_autopsy_artifact_refs.json` — context.autopsy request using bounded artifact references

## Module Structure

```
src/gip.zig            — Root module (re-exports)
src/gip_core.zig       — Protocol version, enums, capability model
src/gip_schema.zig     — Request/response types, JSON rendering
src/gip_validation.zig — Request validation, safety checks
src/gip_dispatch.zig   — Request routing, operation execution
src/gip_cli.zig        — CLI binary entry point
```
