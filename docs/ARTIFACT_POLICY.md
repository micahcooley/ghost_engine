# Ghost Artifact Policy

Ghost Engine is a general artifact intelligence architecture.
Code is one domain, not the universal center.
The kernel is designed to be **artifact-neutral**.

## Kernel vs. Domain Policies

The Ghost kernel handles information through a domain-neutral pipeline:

```
artifact → claims → obligations → hypotheses → verifiers → evidence → candidates
```

Nothing in this pipeline is inherently code-specific.
Technical excellence in a specific domain (like code) is achieved through
**domain policies**, not hardcoded kernel heuristics.

Policies are **routing and scoring hints**.
They influence which artifacts are weighted more heavily,
how minimality is defined, and how contradictions affect trust —
but they never create authority.

## Architecture Rules

1. **Ghost kernel is artifact-neutral.**
   Code-specific excellence belongs in code-domain policy.
2. **Minimality, quotas, priors, and trust decay are policy, not proof.**
   A policy can suggest a preference or weight.
   A policy cannot create proof.
3. **Policies are non-authorizing.**
   No policy grants support. No policy grants proof.
4. **Unknown is not false.**
   No evidence is not negative evidence.
5. **No hidden writes. No hidden command execution.**
6. **Rendering can explain authority. Rendering cannot create authority.**
7. **Future artifact families are first-class citizens:**
   docs, recipes, logs, configs, contracts, spreadsheets, datasets, incidents.

## Implemented Policies

### 1. Intervention Policy (`src/patch_candidates.zig`)

Controls the "minimality" and cost of proposed changes (patches).

- **CodeInterventionPolicy**: Penalizes multi-file changes (file_cost=400),
  new dependencies (dependency_cost=220), and expanded scope
  (expanded_scope_penalty=180) to prefer localized, verified patches.
- **ArtifactInterventionPolicy**: Neutral default that does not penalize
  structural breadth. Suitable for documentation, datasets, or any domain
  where multi-file consistency is expected, not penalized.

### 2. Evidence Family Policy (`src/code_intel.zig`)

Controls the relative weight of different artifact families during grounding.

| Profile | code | docs | config | logs | tests | other |
|---|---|---|---|---|---|---|
| DEFAULT_CODE_FAMILY_POLICY | **3** | 2 | 2 | 1 | 1 | 1 |
| DEFAULT_DOCS_FAMILY_POLICY | 1 | **4** | 1 | 1 | 1 | 1 |
| DEFAULT_NEUTRAL_FAMILY_POLICY | 2 | 2 | 2 | 2 | 2 | 2 |

### 3. Hypothesis Prior Policy (`src/code_intel.zig`)

Controls the starting "bias" for different types of contradictions or impacts.

- **HypothesisPriorPolicy**: Allows configuring weights for
  categories (structural, procedural, relational, boundary, state, invariant)
  and tiers (pattern, convention, logic, contract).
- Defaults are tuned for code but are inspectable and overridable.

### 4. Trust Decay Policy (`src/abstractions.zig`)

Controls how knowledge is promoted or demoted based on contradiction evidence.

- **TrustDecayPolicy**: Defines thresholds for demoting `core` or `promoted`
  knowledge when contradictions accumulate.
- **Core is not universally untouchable**: it can be demoted to `promoted`
  or `project` if consistently contradicted — unless immunity is explicitly
  enabled via `core_immune_to_contradiction`.
- Trust decay is non-authorizing: contradiction triggers demotion,
  but demotion is not proof. The contradiction itself is evidence;
  the policy action (demotion) is routing, not authority.

## Policy Metadata Inspection (`src/artifact_policy.zig`)

The `PolicySummary` struct provides a read-only, serializable view of the
active policy configuration. This metadata is exposed to clients via the
GIP `artifact.policy.describe` read-only endpoint. It exposes:

- `active_profile` — which domain profile is active (code / documentation / neutral / custom)
- `domain_scope` — artifact/domain scope description
- `intervention_policy_name` — name of the active intervention policy
- `family_policy_name` — name of the active evidence family policy
- `prior_policy_name` — name of the active hypothesis prior policy
- `trust_decay_policy_name` — name of the active trust decay policy
- `trust_decay_core_immune` — whether core knowledge has contradiction immunity
- `non_authorizing` — always `true`
- `support_granted` — always `false`
- `proof_granted` — always `false`

The last three fields are **compile-time constants** that exist in every
serialized summary to make the non-authorizing nature of policies visible
and hard to regress.

## Future Domains

Ghost can be extended to new domains by defining a matching policy set:

| Domain | Surface | Intervention Preference | Family Priority |
|---|---|---|---|
| **Recipes** | ingredients, steps | ingredient consistency | steps > wording |
| **Logs** | events, sequence | causal correlation | sequence > environment |
| **Contracts** | clauses, obligations | legal consistency | clauses > metadata |
| **Datasets** | records, schema | data integrity | schema > individual records |
| **Incidents** | timeline, config, logs | timeline correlation | logs > config |

## Authority and Proof

Policies are **non-authorizing**.
A policy can suggest a preference or a weight,
but it cannot create proof.
Final support permission always requires evidence from an external verifier.

- No policy grants support.
- No policy grants proof.
- No policy executes commands.
- No policy applies corrections.
- No policy promotes knowledge.
- No policy authorizes mutations.
