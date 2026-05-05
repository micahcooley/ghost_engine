# Text Generation Lab

The Ghost text generation lab is an experimental, non-authorizing draft surface.
It exists to test whether inspected artifact and corpus-like signals can produce
useful operator-facing text without changing Ghost authority.

Current behavior is deliberately small:

- deterministic template/rule-based draft generation
- short operator summary drafts from supplied claims, obligations, candidate inconsistencies, and unknowns
- tiny in-memory training-example summaries, including example counts and token counts
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

The explicit smoke step is:

```sh
zig build smoke-text-generation-lab
```

Plain `zig build` does not run the lab tests or any training path.

Future work may let small local models, encoders, or rankers feed draft
generation. Those components must remain candidate-only. Verifier and support
gates stay authoritative, and rendering may explain authority but cannot create
it.
