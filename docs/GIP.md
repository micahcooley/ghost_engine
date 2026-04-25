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
- `verifier.list` — List registered verifier adapters **(Not implemented yet)**
- `verifier.run` — Run a specific verifier **(Not implemented yet)**
- `hypothesis.verifier.schedule` — Schedule verifier for hypothesis **(Not implemented yet)**

### Hypotheses
- `hypothesis.generate` — Generate hypotheses from context **(Not implemented yet)**
- `hypothesis.triage` — Triage and select hypotheses **(Not implemented yet)**
- `hypothesis.list` — List active hypotheses **(Not implemented yet)**

### Knowledge Packs
- `pack.list` — List available packs **(Not implemented yet)**
- `pack.inspect` — Inspect pack contents **(Not implemented yet)**
- `pack.mount` / `pack.unmount` — Mount/unmount packs (requires approval) **(Not implemented yet)**
- `pack.import` / `pack.export` — Import/export packs (requires approval) **(Not implemented yet)**
- `pack.distill.*` — Distillation operations **(Not implemented yet)**

### Feedback
- `feedback.record` — Record feedback event **(Not implemented yet)**
- `feedback.replay` — Replay feedback for reinforcement **(Not implemented yet)**
- `feedback.summary` — Summarize feedback history **(Not implemented yet)**

### Session
- `session.create` / `session.get` / `session.update` / `session.close` **(Not implemented yet)**

### Command
- `command.run` — Execute allowlisted command (sandboxed) **(Not implemented yet - currently unsupported)**

## Capability Model

| Capability | Default Policy |
|-----------|---------------|
| `artifact.read` | allowed |
| `artifact.list` | allowed |
| `artifact.search` | allowed |
| `artifact.patch.propose` | allowed |
| `artifact.patch.apply` | requires_approval |
| `artifact.write.propose` | allowed |
| `artifact.write.apply` | requires_approval |
| `command.run` | allowlist |
| `verifier.run` | allowed |
| `pack.inspect` | allowed |
| `pack.mount` | requires_approval |
| `pack.unmount` | requires_approval |
| `pack.import` | requires_approval |
| `pack.export` | requires_approval |
| `feedback.record` | allowed |
| `session.write` | allowed |
| `network.access` | denied |

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
```

## Module Structure

```
src/gip.zig            — Root module (re-exports)
src/gip_core.zig       — Protocol version, enums, capability model
src/gip_schema.zig     — Request/response types, JSON rendering
src/gip_validation.zig — Request validation, safety checks
src/gip_dispatch.zig   — Request routing, operation execution
src/gip_cli.zig        — CLI binary entry point
```
