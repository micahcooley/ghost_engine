# Text Generation Lab

The Ghost text generation lab is an experimental, non-authorizing draft surface.
It exists to test whether inspected artifact and corpus-like signals can produce
useful operator-facing text without changing Ghost authority.

Current behavior is deliberately small:

- deterministic template/rule-based draft generation
- short operator summary drafts from supplied claims, obligations, candidate inconsistencies, and unknowns
- bounded file-backed ingestion from explicit local corpus file paths
- in-memory, lab-local reviewed memory records proposed from explicit corpus signals
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
- `lab_memory_applied: false` unless an accepted lab memory record influenced that lab draft
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
- `fixtures/text_generation_lab/corpus/learning_seed.md`

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

## Lab-local reviewed memory

The learning trial is not model training and not trusted Ghost memory. Learning
for this lab means:

- corpus extraction can propose `LabMemoryRecord` candidates for claims,
  obligations, and unknowns
- an operator/test can explicitly accept or reject a proposed record inside an
  in-memory `LabMemoryStore`
- accepted records can add an `Accepted lab memory reminders` section to later
  lab drafts
- rejected records and unreviewed candidate records do not influence the draft
  as accepted reminders

Accepted lab memory remains experimental and lab-local. It is candidate-only,
non-authorizing, grants no proof, grants no support, mutates no trusted state,
and does not make the lab product-ready. It does not write Ghost corpus,
packs, corrections, negative knowledge, trust, support graphs, snapshots,
scratch state, project state, or production memory.

When accepted lab memory changes a later draft, the draft reports
`lab_memory_applied: true` while `training_applied` remains false. That flag
only means reviewed lab memory influenced draft wording inside this module.

Quality matters more than quantity. Bad, duplicated, noisy, or irrelevant data
should waste storage and candidate signal budget; it must not degrade Ghost's
authority boundaries or become trusted merely because it was ingested.

The explicit smoke step is:

```sh
zig build smoke-text-generation-lab
```

The smoke step runs the lab tests, including fixture corpus ingestion,
lab-memory proposal, explicit acceptance of one record, and a second draft that
shows the accepted lab memory reminder. Plain `zig build` does not run the lab
tests or any training path.

Future work may let small local models, encoders, or rankers feed draft
generation. Those components must remain candidate-only. Verifier and support
gates stay authoritative, and rendering may explain authority but cannot create
it.
