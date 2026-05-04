# Artifact Autopsy (Non-Code Seed)

Ghost Engine is a general artifact intelligence architecture.
**Code is one domain profile, not the core.**
Artifact Autopsy proves this by applying read-only, non-authorizing
inspection to non-code artifact domains.

## Status

**This is a seed implementation, not full universal artifact support.**

The current pass demonstrates the shape:
- One bounded documentation audit fixture.
- One bounded recipe consistency fixture.
- Safety contract enforcement across all non-code domains.
- Integration with the domain-neutral artifact policy system.

Future passes may add:
- Filesystem-backed inspection (reading actual doc/config files).
- Pack-driven non-code autopsy guidance.
- Additional domains (incident review, config audit, contract review).

## GIP Route
The GIP route `artifact.autopsy.inspect` exposes this read-only structure.
- **Request**: `{"domain": "documentation_audit"}`
- **Response**: Bounded fixture result with safety contract intact.

## Architecture

```
artifact → claims → obligations → inconsistencies → unknowns → candidate result
```

This pipeline is domain-neutral. The same structure applies to:

| Domain | Claims Surface | Obligations Surface | Inconsistency Kind |
|---|---|---|---|
| **Documentation Audit** | README instructions, API docs | Build/test commands, setup steps | claim vs config, stale docs |
| **Recipe Consistency** | Ingredients list, step instructions | Ingredient usage in steps | missing ingredient, unused ingredient |
| **Incident Review** | Timeline events, config snapshots | Causal expectations | timeline contradiction, missing evidence |

## Safety Contract

Every `ArtifactAutopsyResult` carries explicit, redundant safety flags:

- `read_only: true`
- `non_authorizing: true`
- `candidate_only: true`
- `support_granted: false`
- `proof_granted: false`
- `commands_executed: false`
- `verifiers_executed: false`
- `mutates_state: false`
- `state: "draft"`

These are **compile-time defaults** in the struct definition. Any change
to these defaults is a visible source change that tests will catch.

## Result Schema (v1 Contract)

The v1 result contract adds explicit schema/version metadata to every
`ArtifactAutopsyResult`. These fields are **descriptive only**:

| Field | Type | Value | Invariant |
|-------|------|-------|-----------|
| `autopsy_schema_version` | `string` | `"artifact_autopsy.v1"` | Never changes within v1 |
| `artifact_autopsy_contract` | `string` | `"seed.file_bounded.v1"` | Identifies bounded inspection contract |
| `route_kind` | `string` | `"artifact.autopsy.inspect"` | The GIP kind that produced this result |
| `fixture_backed` | `bool` | `true` for fixture, `false` for file-backed | Mutually exclusive with `file_backed` |
| `file_backed` | `bool` | `true` for file reads, `false` for fixtures | Mutually exclusive with `fixture_backed` |
| `product_ready` | `bool` | `false` always | Schema presence does not imply readiness |

### Authority rules for schema metadata

1. **Schema labels are descriptive, not authorizing.**
   `autopsy_schema_version:"artifact_autopsy.v1"` does not grant authority.
2. **`product_ready:false` cannot be overridden by schema presence.**
   Presence of a schema field does not make a route product-ready.
3. **Schema metadata does not alter safety contract fields.**
   `read_only`, `non_authorizing`, `proof_granted`, etc. are unaffected.
4. **`fixture_backed` and `file_backed` are mutually exclusive.**
   A result is either a fixture (no filesystem reads) or file-backed (bounded reads).
5. **No behavior becomes product-ready just because it has a schema.**



## Fixture: Documentation Audit

The documentation audit fixture demonstrates:

1. **README claims** `make build` as the build command.
2. **Makefile** build target invokes `cmake --build build`.
3. **Candidate inconsistency**: the user-facing instruction may not match
   the actual build mechanism.
4. **Unknowns**: Makefile target semantics unknown (not parsed/executed),
   README staleness unknown (no timestamp comparison), additional build
   config may exist.

The inconsistency is a **candidate**, not proof. The Makefile may correctly
wrap cmake under a make target, which would make the README accurate.
The autopsy reports what it observes without claiming authority.

## Fixture: Recipe Consistency

The recipe consistency fixture demonstrates:

1. **Ingredients list** includes: flour, sugar, butter, eggs, vanilla extract.
2. **Step 3** references chocolate chips (not in ingredients list).
3. **Candidate inconsistency**: step references ingredient not in list.
4. **Unknowns**: whether ingredients list convention is exhaustive,
   whether chocolate chips are intentionally optional.

The inconsistency is a **candidate**, not proof. Chocolate chips may be
an intentional optional addition. The autopsy reports what it observes.

## Golden Smoke Fixtures

Reusable local smoke fixtures live under `fixtures/artifact_autopsy/`.
They are test/smoke artifacts only. They do not grant proof, support, or
authority, and they are not product-ready examples. They exist so local
verification can use stable file-backed inputs instead of ad hoc scratch files.

The fixture set covers:

- `fixtures/artifact_autopsy/documentation/README.md`
- `fixtures/artifact_autopsy/documentation/Makefile`
- `fixtures/artifact_autopsy/recipes/recipe_unused.md`
- `fixtures/artifact_autopsy/recipes/recipe_missing.md`
- `fixtures/artifact_autopsy/recipes/recipe_no_ingredients.md`
- `fixtures/artifact_autopsy/recipes/recipe_no_steps.md`

Run the repeatable developer smoke after building `ghost_gip`:

```bash
zig build
bash tools/smoke_artifact_autopsy.sh
```

The smoke script invokes `./zig-out/bin/ghost_gip` explicitly, writes only
temporary output under `${TMPDIR:-/tmp}`, and removes that output on exit. It
checks documentation audit, recipe unused ingredient, recipe missing
ingredient, missing ingredients section, missing steps section, and path
traversal rejection. The checks use `jq` when available and fall back to
literal output matching otherwise.

## Policy Integration

Artifact autopsy results carry an `active_policy_profile` field that
connects to the artifact policy system (`src/artifact_policy.zig`):

- **Documentation audit** uses the `documentation` profile:
  - No file-breadth intervention penalties.
  - Documentation weight > code weight.
- **Recipe consistency** uses the `neutral` profile:
  - Equal weights across all artifact families.
  - No domain-specific intervention penalties.

The code profile is **not assumed by default** for non-code inspections.

## Authority Rules

1. **Non-code findings are candidates, not proof.**
   A detected inconsistency is an observation, not a defect claim.
2. **Docs/recipes/logs/configs are claims/evidence surfaces, not authority.**
   An instruction in a README is a claim. It is not proof the instruction works.
3. **Unknown is not false.**
   If the Makefile was not parsed, that does not mean the Makefile is broken.
4. **No evidence is not negative evidence.**
   If an ingredient is not in the list, that does not mean it was forgotten.
5. **No hidden writes. No hidden command execution.**
6. **No verifier execution.**
   The autopsy does not run `make`, `cmake`, or any other command.
7. **No correction/NK/pack/corpus/trust/snapshot/scratch mutation.**
8. **Policies are routing/scoring hints, not authority.**
9. **Rendering can explain authority. Rendering cannot create authority.**

## Implementation

- `src/artifact_autopsy.zig` — Core types, fixtures, and tests.
- `src/artifact_policy.zig` — Domain profiles used by artifact autopsy.
- `docs/ARTIFACT_POLICY.md` — Policy documentation.
- `docs/ARTIFACT_AUTOPSY.md` — This document.

Tests are discovered through `src/test_smoke.zig` and run as part of
`zig build test`.
