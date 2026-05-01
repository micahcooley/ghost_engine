# Code Intel And Patching

This document covers the shipped code-intel pilot, task-intent grounding, support graphs, and proof-backed patch flow.

## Code Intel Scope

`ghost_code_intel` is a deterministic pilot. It is not a claim of universal semantic understanding.

Supported query kinds:

- `impact`
- `breaks-if`
- `contradicts`

## Indexed Surfaces

Native indexing is Zig-first and bounded:

- `.zig`
- `.comp`
- `.sigil`
- `.c`, `.cc`, `.cpp`, `.cxx`
- `.h`, `.hh`, `.hpp`, `.hxx`

Symbolic ingestion is also implemented for bounded cross-symbol grounding:

- `.md`, `.txt`, `.rst`
- `.toml`, `.yaml`, `.yml`, `.json`, `.ini`, `.cfg`, `.conf`, `.env`
- `.xml`, `.html`
- `.rules`, `.dsl`, `.test`, `.spec`
- `.tf`, `.tfvars`, `.tpl`

The symbolic path is structural and bounded. It extracts symbolic units, references, and structural hints so Ghost can ground documentation or configuration concepts into code or runtime targets when deterministic support exists.

## Corpus Ingestion

`ghost_corpus_ingest` is the deterministic bridge from external corpus material into shard-local memory inputs.

Current ingestion contract:

- scans one explicit corpus path on demand
- classifies each file into `code`, `docs`, `specs`, `configs`, or `symbolic`
- rejects unsupported or weakly structured inputs instead of falling back to loose interpretation
- stages all accepted items under the selected shard first
- manual `ghost_corpus_ingest` runs stop at the staged manifest until `ghost_corpus_ingest --apply-staged --project-shard=<id>` or a later Sigil `commit`; operator-driven external evidence can apply the staged set into shard-local live corpus immediately for support recovery

Current classification rules are explicit:

- native code: `.zig`, `.comp`, `.sigil`, `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`
- docs: `.md`, `.txt`, `.rst`, `.html`, `.xml`
- configs: `.toml`, `.yaml`, `.yml`, `.json`, `.ini`, `.cfg`, `.conf`, `.env`, `.tf`, `.tfvars`, `.tpl`
- symbolic DSL/tests/specs: `.rules`, `.dsl`, `.test`, `.spec`
- anything else: rejected

Dedup and normalization are deterministic:

- exact duplicate: identical raw bytes
- normalized duplicate: identical bytes after CRLF-to-LF normalization
- unique items only are copied into shard-local live storage

Every live corpus item carries:

- shard-local provenance
- trust class
- lineage id and lineage version
- source path and source label

`corpus.ask` computes byte/line evidence spans and a cheap FNV-1a content hash during bounded retrieval from the live file bytes. Those span fields are retrieval metadata, not a separate persisted corpus-store index.

That metadata is attached to `code_intel` subjects, evidence, abstraction traces, and grounding traces when the result depends on ingested corpus surfaces.

`corpus.ask` is the first GIP runtime slice that answers directly from this live corpus state. It does not ingest data, read staged corpus as active knowledge, run verifiers, or write learning state. Retrieval is deterministic local exact recall: case-insensitive exact token matching, adjacent exact phrase hits, simple bounded overlap/frequency scoring, and stable tie-breaking. It is not semantic search, does not use embeddings, does not add Transformers, and does not call out to a model or network service. When exact evidence is present it may return a draft/non-authorizing `answerDraft` with `evidenceUsed`; when evidence is missing, weak, approximate-only, or conflicting it returns explicit unknowns and candidate followups. Any learning output is a candidate object only and is not persisted automatically.

Phase 2 adds local sketch routing as a hint channel for corpus candidates. `corpus.ask` computes bounded 64-bit SimHash sketches over normalized local text features during the same live-corpus scan and may return `similarCandidates` with Hamming distance, similarity score, and `nonAuthorizing: true`. These candidates are approximate routing signals for near-duplicate, clustering, or recurrence work. They are not proof, are not exact memory, do not populate `evidenceUsed`, and never authorize `answerDraft`.

Minimal binary-only ingest/apply/ask loop:

```bash
./zig-out/bin/ghost_corpus_ingest /tmp/ghost-corpus-smoke --project-shard=smoke --trust-class=project --source-label=smoke
./zig-out/bin/ghost_corpus_ingest --apply-staged --project-shard=smoke
echo '{"gipVersion":"gip.v0.1","kind":"corpus.ask","projectShard":"smoke","question":"What does the corpus say about verifier execution?"}' | ./zig-out/bin/ghost_gip --stdin
```

Bounded external evidence now reuses the same path instead of a separate web-memory system:

- the operator accepts explicit URLs and/or bounded search queries
- fetch happens only inside the evidence-acquisition step, never during core reasoning
- fetched files are snapshotted under the active shard, then staged through `ghost_corpus_ingest`
- the task-operator evidence path applies that staged snapshot into the shard-local live corpus immediately before the rerun
- provenance records include source URL, fetch time, content hash, trust class, and lineage
- support graphs surface `external_evidence` nodes plus the acquisition outcome handoff
- reruns resolve through both the staged shard-local corpus path and stable source-basename aliases such as `@corpus/docs/runbook.md`

## Persistence

Code-intel outputs persist under the selected shard:

- `code_intel/last_query.txt`
- `code_intel/last_result.json`
- `code_intel/cache/index_v1.gcix`

The cache is shard-local. The benchmark suite includes a cold-versus-warm case to keep that behavior measurable.

## Target Resolution And Grounding

Current resolution model:

- explicit `path:symbol` targets are preferred
- bare ambiguous symbols stay `unresolved`
- symbolic units can ground into bounded code or runtime targets
- if symbolic grounding ties across multiple surfaces, the result stays `unresolved`

That means Ghost can bridge from docs/config/symbolic units into code only when the support remains bounded and deterministic.

## Task Intent Grounding

`ghost_task_intent` is the narrow task-intent parser. It is also used by:

- `ghost_code_intel --intent=...`
- `ghost_patch_candidates --intent=...`

Implemented grounding:

- actions: build, implement, refactor, explain, verify, compare, plan
- targets: files, functions, modules, shards, concepts, symbols, quoted targets, path-like targets
- constraints: determinism, Linux-first, no-new-deps, API stability, performance, language hints
- output modes: patch, explanation, plan, alternatives

Dispatch is narrow and explicit:

- grounded explain and verify requests map to `code_intel`
- grounded build, implement, refactor, and plan requests map to `patch_candidates`
- alternatives requests force exploratory reasoning mode
- unsupported or ambiguous requests remain `clarification_required` or `unresolved`

## Support Graph Output

Both `ghost_code_intel` and `ghost_patch_candidates` emit a `supportGraph` object in JSON output.

Current fields:

- `permission`: final permission state
- `minimumMet`: whether the minimum bounded support threshold was met
- `flowMode`: current flow name such as `proof` or `explore_then_proof`
- `unresolvedReason`: why permission was denied when unresolved
- `nodes`: bounded support nodes
- `edges`: bounded support edges

Important behavior:

- `supported` output is only allowed when decision traces and evidence traces both exist
- if minimum support is missing, Ghost downgrades the result back to `unresolved`
- support graphs are not decorative; they are part of the output permission contract

## Phase 3 Artifact And Routing Surfaces

The Phase 3 artifact schema is domain-neutral:

- every bounded input is an artifact
- artifacts are split into fragments
- fragments produce entities and relations
- relations and schema hooks produce obligations and verifier hooks
- action surfaces describe what Ghost may attempt, but never bypass support/proof gates

Code artifacts remain one supported domain with build, test, and runtime verifier hooks. Documents, config, logs, corpus entries, pack previews, task records, and external evidence are not architectural second-class inputs; they use the same artifact/fragments/entities/relations/obligations shape when they enter Phase 3 plumbing.

Support-aware routing is also non-authorizing. Routing candidates carry deterministic upper-bound support potential plus selected/skipped/suppressed status. They can influence which artifact surfaces are inspected first, but selected routing candidates do not count as final evidence and do not directly authorize `supported`.

## Patch Candidate Flow

`ghost_patch_candidates` is proof-backed patch generation with explicit verification.

Current flow:

1. Run `code_intel` in exploratory mode to widen bounded candidate discovery.
2. Build strategy hypotheses and deterministic synthesized patch candidates.
3. Cluster candidates and queue a bounded subset for proof mode.
4. Verify queued candidates with build, test, and optional runtime workflows when Linux-native workflows are detected.
5. Re-rank verified survivors under proof mode.
6. Select the minimal verified survivor using `bounded_refactor_minimality_v1`.

Current synthesis behavior:

- Zig-first bounded rewrites emit real unified-diff hunks instead of comment scaffolds
- supported operators are explicit and serialized as `rewriteOperators`
- support traces record which rewrite operators fired and which semantic surfaces justified them
- when the semantic graph cannot justify a bounded rewrite, patch generation stays `unresolved`

The output `supportGraph.flowMode` for this workflow is `explore_then_proof`.

## Verification And Minimality

Implemented verification behavior:

- build verification
- test verification
- bounded runtime-oracle verification after build/test when a fixture provides runtime oracle support
- explicit ordered event-sequence checks in bounded runtime oracles
- explicit bounded state-transition checks in bounded runtime oracles
- runtime-unresolved results when runtime evidence is required but the oracle support is insufficient
- one bounded retry cycle
- bounded refinement traces when a smaller follow-up candidate is generated

Implemented selection behavior:

- verified survivors can still be rejected by the honesty gate
- the final winner prefers smaller verified scope, not the broadest patch
- if no candidate survives verification, final output is `unresolved`

The verifier adapter interface treats adapters as evidence producers:

- passed adapters discharge named obligations only through the support graph
- failed adapters create failure or contradiction evidence
- blocked or missing adapters leave obligations remaining
- non-code adapters such as config schema validation, document citation checks, freshness checks, and consistency checks use the same result contract as build/test/runtime adapters
- speculative scheduler traces preserve considered, selected, pruned, and failed candidates instead of deleting losing branches

## Execution Harness

Patch verification uses `src/execution.zig`.

Current guarantees:

- workspace-root confinement
- bounded `zig build` and `zig run`
- allowlisted shell tools only
- bounded output capture
- bounded timeouts
- explicit failure signals in result JSON

This harness is intentionally narrower than a general shell executor.

## Current Benchmark Reality

From the latest Linux serious-workflow report in this workspace:

- 42/42 benchmark cases passed
- verified-complete workflow rate: 100%
- external-evidence-assisted workflow rate: 100%
- runtime-verified patch workflow rate: 100%
- 13 verified supported patch or task-verification results
- patch compile-pass rate: 84% (16/19 build attempts)
- test-pass rate: 87% (14/16 test attempts)
- runtime-pass rate: 83% (5/6 runtime attempts)
- response mode distribution, response path timings, artifact schema pipeline time, verifier adapter dispatch time, and code/non-code verifier counts are reported in the serious-workflow benchmark outputs

That runtime rate is per attempted bounded runtime verification step in the current deterministic suite.

## Current Limits

- the code-intel pilot only supports `impact`, `breaks-if`, and `contradicts`
- native support is bounded, not full compiler-level understanding
- symbolic grounding is structural and support-backed, not open-ended semantic interpretation
- externally ingested corpus targets now resolve through deterministic staged paths and stable original-basename aliases, but alias coverage is still bounded to ingested corpus classes Ghost currently indexes
- draft renderers are deterministic views over bounded traces, not a second reasoning engine
- draft mode is not a verifier substitute; proof, correctness, test, verify, and patch-capable requests must use the verifier-capable path
