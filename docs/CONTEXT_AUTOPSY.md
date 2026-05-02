# Context Autopsy (Pack-Driven)

## 1. Overview
Context Autopsy is the universal generalization of Project Autopsy. While Project Autopsy specifically analyzes codebases (workspaces) to detect languages, build systems, and verifiers, Context Autopsy extends this pattern to arbitrary user situations—such as relationship advice, baking, marketing, research, planning, or debugging.

Crucially, Context Autopsy achieves this **without hardcoded domain adapters in the core engine**. Instead, it uses Knowledge Packs as the source of domain operational knowledge. The Ghost core handles the universal context/intake structure, intent grounding, pack candidate selection, and non-authorizing output presentation, while the packs themselves provide the specific domain concepts, signals, failure modes, and action candidates.

## 2. Project Autopsy as an Instance of Context Autopsy
Currently, Project Autopsy runs a fixed, hardcoded set of checks against a local directory (e.g., `src/project_autopsy.zig`). In the Context Autopsy model:
- The "situation" or "intake" is defined as a `ContextCase` (e.g., "Analyze this directory").
- A "Software Engineering" or "Local Workspace" Knowledge Pack provides the specific files to look for (`build.zig`, `package.json`, `Cargo.toml`).
- The pack defines what signals those files produce (`PackAutopsySignal` for "zig_build", "npm_scripts").
- The pack defines what risks those files entail (`PackRiskSurface` for auth files or database migrations).
- The pack suggests verifier commands (`PackCheckCandidate` mapped to `VerifierPlanCandidate`).

Ghost core simply evaluates the `ContextCase` against the mounted Knowledge Packs, matching pack-defined rules to produce a `ContextAutopsyResult`, completely decoupling the engine from knowing what a "build system" or a "test runner" is.

## 3. Pack-Provided Autopsy Guidance
Instead of Ghost hardcoding what to look for, Knowledge Packs provide declarative autopsy guidance:
- **Domain Concepts & Signals:** A "Baking" pack might define signals like `flour_type`, `hydration_ratio`, `oven_temp`.
- **Common Failure Modes:** A "Marketing" pack might define `missing_target_audience` or `unclear_call_to_action` as high-value unknowns.
- **Risk Surfaces:** A "Relationship" pack might define `escalating_conflict` or `stonewalling` as risk surfaces that require delicate handling.
- **Candidate Actions:** A pack provides non-authorizing actions (e.g., "Suggest apologizing", "Suggest adding 50g water", "Suggest running `zig build`").
- **Checks and Verifiers:** Hard verifiers (e.g., compiler exit codes) vs. soft real-world checks (e.g., "Taste the dough", "Ask your partner how they feel"). Soft checks are explicitly labeled as weaker.
- **Negative Knowledge & Anti-patterns:** Packs provide known traps (e.g., "Do not mix baking soda without acid" or "Do not assume CI checks out PRs locally").

Ghost evaluates the user's situation against these pack rules. The engine remains ignorant of baking or marketing, only understanding how to unify signals, risks, checks, and candidates into a unified `ContextAutopsyResult`. Generic rule evaluation in Ghost remains non-authorizing: deterministic rules may suggest risks, checks, evidence expectations, unknowns, or follow-ups, but rule firing is never proof and never executes a verifier.

## 4. Runtime Status

Context Autopsy now has a native runtime path through GIP as `context.autopsy`.
The runtime accepts a generic `ContextCase` payload, request-supplied pack
guidance, and persisted autopsy guidance from mounted Knowledge Packs. It
evaluates only guidance whose domain-neutral match criteria apply to the case
and returns a draft/non-authorizing `ContextAutopsyResult`.

Current match criteria are intentionally generic, deterministic, bounded, and
case-insensitive for tags and keyword matching:
- `intent_tags_any` / `intent_tags_all`
- `context_keywords_any` / `context_keywords_all`
- `artifact_kinds_any` / `artifact_kinds_all`
- `situation_kinds_any` / `situation_kinds_all`
- `required_context_fields`

Keyword matching first checks structured case data such as description/summary,
intent tags, situation kinds, artifact kinds, and declared artifact/input ref
labels, purposes, and reasons. Bounded JSON string/key inspection remains a
fallback for request-provided context values. Applied guidance includes
non-authorizing match trace metadata on pack influence records so operators can
inspect why a guidance entry applied.

If pack guidance is present but none of it applies, the engine emits an explicit
unknown/gap. It does not treat non-matching guidance as proof that a concept is
absent.

Evidence expectations from pack guidance are surfaced as pending evidence
obligations. They are not executed, are not treated as proof, and remain
non-authorizing. Hard verifier expectations and soft checks are classified as
pending obligations only.

Persisted guidance is loaded from the optional Knowledge Pack manifest storage
field `autopsyGuidanceRelPath`. The preferred file shape is versioned:

```json
{
  "schema": "ghost.autopsy_guidance.v1",
  "packGuidance": []
}
```

Legacy unversioned shapes remain accepted for compatibility: a top-level
guidance array, an object with `packGuidance`, or an object with
`pack_guidance`. Versioned guidance may also use the `pack_guidance` alias.
Guidance entry fields keep existing camelCase/snake_case aliases where they are
unambiguous. The validator warns on legacy unversioned guidance and rejects
unknown/future schema strings. Runtime loading still treats missing, malformed,
or unsupported persisted guidance as warning/unknown and does not crash the
request. Merge order is deterministic: persisted mounted-pack guidance first in
mount registry order, then request-supplied guidance in request order.

Persisted guidance can be reviewed before runtime use with:

```sh
ghost_knowledge_pack validate-autopsy-guidance --pack-id=<id> --version=<v>
ghost_knowledge_pack validate-autopsy-guidance --manifest=<path>
ghost_knowledge_pack validate-autopsy-guidance --all-mounted --project-shard=<id>
ghost_knowledge_pack validate-autopsy-guidance --json --manifest=<path>
ghost_knowledge_pack capabilities --json
```

The validator is read-only. It validates the declared guidance file exists,
parses as JSON, uses one of the accepted top-level shapes, keeps bounded match
criteria, includes required fields for contributed signals/unknowns/risks/
candidate actions/check candidates/evidence expectations, and reports
authorizing or execution-like fields as structured warnings. Validation errors
return non-zero from the CLI; warnings alone do not. Expected path, manifest,
schema, and guidance validation failures are rendered as clean human output or
structured JSON, without Zig stack traces. The tool does not mount, promote,
fix, execute, or mutate packs.

Default validation limits are named policy values: `maxGuidanceBytes=524288`,
`maxGuidanceEntries=256`, `maxArrayItems=128`, and `maxStringBytes=2048`.
Operator overrides are available for byte, array-item, and string-byte limits:
`--max-guidance-bytes=<n>`, `--max-array-items=<n>`, and
`--max-string-bytes=<n>`. Overrides remain bounded by hard caps reported by
`ghost_knowledge_pack capabilities --json`; unlimited validation is not
supported.

Artifact references may include bounded include/exclude filters. Filters use a
small deterministic glob syntax over workspace-relative paths: `*` matches
within one path segment, `?` matches one character within one path segment, `**`
as a full path segment matches across path segments, and `/` is a literal
separator. Examples include `*.zig`, `src/*.zig`, `src/**/*.zig`, `.git/**`,
`zig-out/**`, `.zig-cache/**`, and `node_modules/**`. Exclude filters take
precedence over include filters. If no include filters are provided, every
non-excluded file remains eligible. Filtered, skipped, and truncated files still
surface through artifact coverage and explicit unknowns.

File-backed context input references provide a separate data-plane path for
large textual context, logs, and transcript-style inputs that should not be
embedded into the stdin JSON control plane. The canonical request shape is
`context.input_refs` / `context.inputRefs`:

```json
{
  "context": {
    "summary": "Review a large transcript",
    "input_refs": [
      {
        "kind": "file",
        "path": "notes/transcript.txt",
        "id": "transcript",
        "label": "Interview transcript",
        "purpose": "bounded transcript context",
        "maxBytes": 65536
      }
    ]
  }
}
```

Input refs are file-only. Paths must resolve inside the workspace. Ghost reads
only up to the declared byte budget, clamps excessive budgets, never executes
anything, never mutates files, and does not echo raw input text in the response.
`inputCoverage` reports requested refs, bytes read, skipped refs, truncation,
budget hits, and explicit unknowns for unread or truncated regions. These
unknowns remain missing evidence, not negative evidence, and the result remains
draft/non-authorizing.

Coverage and capacity pressure are explicit by contract. Skipped, filtered,
unsupported, unread, truncated, capped, dropped, or saturated data must surface
as coverage, telemetry, warnings, or unknowns rather than silent success.
Capacity warnings are diagnostic only; they are not proof, do not teach dropped
data, and do not authorize support.

## 5. Minimal Proposed Schema

```zig
pub const ContextCase = struct {
    description: []const u8,
    intake_data: std.json.Value, // Raw situational data (workspace path, chat history, problem description)
    intake_type: []const u8,      // e.g., "workspace", "chat", "document"
};

pub const PackAutopsySignal = struct {
    name: []const u8,
    source_pack: []const u8,
    kind: []const u8,          // e.g., "domain_marker", "ingredient", "tech_stack"
    confidence: []const u8,
    reason: []const u8,
};

pub const PackSuggestedUnknown = struct {
    name: []const u8,
    source_pack: []const u8,
    importance: []const u8,    // high, medium, low
    reason: []const u8,
};

pub const PackRiskSurface = struct {
    risk_kind: []const u8,
    source_pack: []const u8,
    reason: []const u8,
    suggested_caution: []const u8,
    non_authorizing: bool = true,
};

pub const PackCandidateAction = struct {
    id: []const u8,
    source_pack: []const u8,
    action_type: []const u8,   // e.g., "command", "communication", "physical_action"
    payload: std.json.Value,   // action-specific details
    reason: []const u8,
    risk_level: []const u8,
    requires_user_confirmation: bool = true,
    non_authorizing: bool = true,
};

pub const PackCheckCandidate = struct {
    id: []const u8,
    source_pack: []const u8,
    check_type: []const u8,    // e.g., "hard_verifier", "soft_real_world_check"
    purpose: []const u8,
    risk_level: []const u8,
    confidence: []const u8,
    evidence_strength: []const u8, // e.g., "absolute", "heuristic", "subjective"
    requires_user_confirmation: bool = true,
    non_authorizing: bool = true,
    why_candidate_exists: []const u8,
};

pub const ContextAutopsyResult = struct {
    context_case: ContextCase,
    detected_signals: []PackAutopsySignal,
    suggested_unknowns: []PackSuggestedUnknown,
    risk_surfaces: []PackRiskSurface,
    candidate_actions: []PackCandidateAction,
    check_candidates: []PackCheckCandidate,
    state: []const u8 = "draft",
    non_authorizing: bool = true,
};
```

## 6. Migration Plan
- **Phase 1: docs/spec only**
  - Establish the universal Context Autopsy design and constraints (this document).
- **Phase 2: generic internal types**
  - Implement `ContextCase`, `ContextAutopsyResult`, and associated generic structures in Ghost core alongside existing `project_autopsy.zig`.
- **Phase 3: Project Autopsy maps into Context Autopsy model**
  - Refactor `project_autopsy.zig` to output the new `ContextAutopsyResult` schema internally, mapping legacy types to the new universal types.
- **Phase 4: pack-aware context autopsy prototype using existing packs**
  - Implement engine routing to query mounted packs for signals, risks, and checks, fusing them with the intake context.
- **Phase 5: correction-native learning candidates**
  - `context.autopsy` results can be disputed through the explicit GIP `correction.propose` operation.
  - The correction proposal is signal, not proof. It creates review-required correction candidates and proposed learning outputs only.
  - Proposed outputs can include negative-knowledge candidates, pack guidance candidates, corpus update candidates, verifier/check candidates, or follow-up evidence requests.
  - No Context Autopsy correction silently mutates packs, corpus, negative knowledge, command state, verifier state, or future behavior.
  - Accepted learning requires a separate explicit review lifecycle. In current GIP, negative-knowledge review validation is present, but append-only persistence remains structured unsupported until a safe persistence target exists.

## 7. Explicit Non-Goals
- **No domain-specific hardcoded adapters:** Ghost core will not contain logic for baking, marketing, relationship advice, etc.
- **No hidden execution:** Context Autopsy does not execute commands or perform actions automatically.
- **No automatic pack mutation:** Autopsy is read-only; it observes and generates draft results without modifying the packs.
- **No treating pack content as proof:** Packs are signal sources, not truth authorities.
- **No replacing verifier/support gates:** Autopsy only produces candidates; it does not authorize correctness claims or bypass verifier/support checks.

## 8. Authority Rules
- **Packs are signal sources, not truth authorities:** They guide the autopsy but do not dictate absolute facts about the current context.
- **Candidate actions are non-authorizing:** They are suggestions requiring user or system confirmation.
- **Checks produce evidence, not automatic truth:** The results of a check must be evaluated; they do not automatically prove correctness.
- **Soft real-world checks must be labeled weaker than hard verifiers:** A subjective user check is distinct from a deterministic compiler exit code.
- **Unknown is not false:** Missing evidence is represented as an unknown, not as negative evidence.
- **No evidence is not negative evidence:** The absence of a signal does not imply the absence of the underlying concept.
- **Capacity warnings are not proof:** Skipped, truncated, capped, dropped, or saturated data creates explicit coverage/unknown pressure and never authorizes a claim.
- **No hidden learning:** User corrections against Context Autopsy output are routed through `correction.propose`; they remain non-authorizing, `treatedAsProof:false`, and review-required until `correction.review` explicitly accepts or rejects them into append-only reviewed records. Accepted reviewed corrections are still not proof and only create future-behavior candidates or warnings unless a separate explicit lifecycle applies them.
