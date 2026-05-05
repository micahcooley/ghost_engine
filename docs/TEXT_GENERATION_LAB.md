# Text Generation Lab

The Ghost text generation lab is an experimental, non-authorizing draft surface.
It exists to test whether inspected artifact and corpus-like signals can produce
useful operator-facing text without changing Ghost authority.

Current behavior is deliberately small:

- deterministic template/rule-based draft generation
- short operator summary drafts from supplied claims, obligations, candidate inconsistencies, and unknowns
- bounded file-backed ingestion from explicit local corpus file paths
- tiny in-memory training-example summaries, including example counts and rune counts
- no persistent training
- no model, LLM, GPU, Vulkan, Python, dependency, network, shell, verifier, or command execution

Every result keeps the safety boundary explicit:

- `candidate_only: true`
- `non_authorizing: true`
- `support_granted: false`
- `proof_granted: false`
- `mutates_state: false`
- `training_applied: false`
- `product_ready: false`

Generated text is not proof, not support, not evidence, and not verifier output.
It must not mutate corpus, packs, corrections, negative knowledge, trust,
support graphs, snapshots, scratch state, or project state. Unknowns remain
unknowns; no evidence is not negative evidence.

## File-backed corpus fixture

The first file-backed trial is lab-local only. It reads explicit relative file
paths under a caller-provided workspace root and never scans recursively. The
fixture corpus lives at:

- `fixtures/text_generation_lab/corpus/doc_claims.md`
- `fixtures/text_generation_lab/corpus/runbook.md`
- `fixtures/text_generation_lab/corpus/noisy_notes.md`

The reader rejects empty paths, absolute paths, `..` traversal, directories,
symlinks on supported hosts, too many files, oversized files, and oversized
total input. It extracts only simple deterministic line signals:

- lines containing `claim:` become detected claims
- lines containing `obligation:` or `must` become detected obligations
- lines containing `unknown:` or `todo:` become unknowns
- duplicate exact lines are counted and suppressed from the draft

The ingested lines are candidate material only. They do not enter Ghost's
trusted corpus store, trusted memory, packs, corrections, negative knowledge,
trust graph, support graph, snapshots, or project state. More corpus data can
produce more candidate signals and more unknowns, but it cannot create proof,
support, verifier output, or authority.

The lab also reports an in-memory training-example summary for ingested corpus
signals. `training_applied` remains false, and no persistent model state is
created.

Quality matters more than quantity. Bad, duplicated, noisy, or irrelevant data
should waste storage and candidate signal budget; it must not degrade Ghost's
authority boundaries or become trusted merely because it was ingested.

The explicit smoke step is:

```sh
zig build smoke-text-generation-lab
```

The smoke step runs the lab tests, including the fixture corpus ingestion path.
Plain `zig build` does not run the lab tests or any training path.

Future work may let small local models, encoders, or rankers feed draft
generation. Those components must remain candidate-only. Verifier and support
gates stay authoritative, and rendering may explain authority but cannot create
it.
