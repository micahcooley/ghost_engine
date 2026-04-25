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

GIP operations are divided into three maturity categories:

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
| `feedback.summary` | Returns event counts if workspace metadata resolves; otherwise `unsupported` flag | `requires_workspace_metadata` |
| `session.get` | Returns session data if session file exists; otherwise `path_not_found` | `requires_existing_session` |

Stateless operations do not fake data. They return structurally valid empty
outputs that are safe for clients to consume.

### Unsupported (structured unsupported response)

| Operation | Status |
|-----------|--------|
| `verifier.run` | Not implemented |
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

### Artifacts
- `artifact.read` — Read file content (workspace-bounded) **(Implemented)**
- `artifact.list` — List directory entries **(Implemented)**
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
- `hypothesis.verifier.schedule` — Schedule verifier for hypothesis **(Not implemented yet)**

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
| `hypothesis.list` | allowed | yes |
| `hypothesis.triage` | allowed | yes |
| `verifier.list` | allowed | yes |
| `pack.list` | allowed | yes |
| `pack.inspect` | allowed | yes |
| `feedback.summary` | allowed | yes |
| `session.get` | allowed | yes |
| `command.run` | allowlist | no (not implemented) |
| `verifier.run` | allowed | no (not implemented) |
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
echo '{"gipVersion":"gip.v0.1","kind":"pack.inspect","packId":"my-pack"}' | ghost_gip --stdin
echo '{"gipVersion":"gip.v0.1","kind":"feedback.summary"}' | ghost_gip --stdin --workspace /path/to/project
echo '{"gipVersion":"gip.v0.1","kind":"session.get","sessionId":"my-session"}' | ghost_gip --stdin
```

## Examples

See `examples/gip/` for sample request JSON files:

- `hypothesis_list.json` — hypothesis.list request
- `hypothesis_triage.json` — hypothesis.triage request
- `verifier_list.json` — verifier.list request
- `pack_list.json` — pack.list request
- `pack_inspect.json` — pack.inspect request

## Module Structure

```
src/gip.zig            — Root module (re-exports)
src/gip_core.zig       — Protocol version, enums, capability model
src/gip_schema.zig     — Request/response types, JSON rendering
src/gip_validation.zig — Request validation, safety checks
src/gip_dispatch.zig   — Request routing, operation execution
src/gip_cli.zig        — CLI binary entry point
```
