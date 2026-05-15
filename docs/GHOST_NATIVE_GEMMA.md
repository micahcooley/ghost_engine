# Ghost-Native Gemma Integration

This directory is the implementation ledger for Gemma 4 E2B inside Ghost.

## Current Gate

The current tree now has executable gates for all eight planned phases:
GGUF loading, numeric matmul calibration, RMS/SwiGLU kernels, rune encoding,
resonance-weighted attention, rune projection, a reference inference smoke
harness, and strict agent routing. The smoke harness is intentionally labeled
`read_only_non_authorizing_phase_harness_not_full_model`: it proves the
rune-to-rune path and contracts, but it is not yet the full Vulkan-dispatched
35-block Gemma forward pass.

The live E2B GGUF checked in locally is:

- `weights/gemma-4-E2B-it-Q8_0.gguf`
- source repo: `ggml-org/gemma-4-E2B-it-GGUF`
- architecture metadata is read from the file, not hardcoded

The web-confirmed model card reports Gemma 4 E2B as `gemma4` with 35 layers,
and the downloaded GGUF confirms:

- `gemma4.block_count = 35`
- `gemma4.embedding_length = 1536`
- `gemma4.attention.head_count = 8`
- `gemma4.attention.head_count_kv = 1`
- `gemma4.attention.key_length = 512`
- `gemma4.attention.key_length_swa = 256`
- `gemma4.attention.value_length = 512`
- `gemma4.attention.value_length_swa = 256`
- `gemma4.feed_forward_length = [6144 x 15, 12288 x 20]`
- tensor count is 601 for the Q8_0 GGUF
- `token_embd.weight` exists
- no standalone `output.weight` exists in this file

Do not hardcode the earlier 18-layer / 2048-hidden / 4-KV-head sketch. All
runtime tensor binding must derive shape from GGUF metadata and tensor inventory.

## Phase Order

1. Weight loading and tensor inventory: `src/gemma/weights.zig`.
2. Numeric matmul calibration: `src/gemma/q8_matmul.zig` for the live Q8_0 GGUF, plus `src/shaders/matmul_q4k.comp` for the Q4_K shader surface specified by the original blueprint.
3. RMS norm and SwiGLU: `src/gemma/layers/rms_norm.zig`, `src/gemma/layers/swiglu.zig`, `src/shaders/rms_norm.comp`, `src/shaders/swiglu.comp`.
4. Rune encoding/embed: `src/gemma/rune_encoder.zig`, `src/shaders/rune_embed.comp`.
5. Ghost attention: `src/gemma/context_provider.zig`, `src/gemma/layers/attention.zig`, `src/shaders/ghost_attention.comp`.
6. Transformer-block reference seam: the inference harness runs RMS, resonance attention, residual, SwiGLU, residual, and RMS over encoded rune embeddings.
7. Output rune projection: `src/gemma/layers/rune_head.zig`, `src/shaders/rune_project.comp`.
8. Agent routing: `src/gemma/agents.zig` and `ghost_gemma agent route`.
9. Vulkan forward schedule: `src/gemma/forward_schedule.zig` builds the 35-block shader sequence from GGUF metadata and tensor-derived dimensions.

## Non-Negotiable Boundaries

- No llama.cpp runtime.
- No Ollama runtime.
- No tokenizer path for Ghost-native inference.
- No KV cache.
- No softmax authority path.
- No automatic etching of Gemma output.
- Query remains read-only.
- Final authority remains `supported` or `unresolved`.

## Explicit Inspection

Use:

```bash
zig build ghost-gemma-weights
./zig-out/bin/ghost_gemma weights inspect --path weights/gemma-4-E2B-it-Q8_0.gguf
./zig-out/bin/ghost_gemma matmul calibrate --path weights/gemma-4-E2B-it-Q8_0.gguf --tensor blk.0.attn_q.weight --rows 8 --json
./zig-out/bin/ghost_gemma inference smoke --path weights/gemma-4-E2B-it-Q8_0.gguf --text "memory allocation heap pointer" --top-k 4 --json
./zig-out/bin/ghost_gemma inference plan --path weights/gemma-4-E2B-it-Q8_0.gguf --json --limit 12
./zig-out/bin/ghost_gemma agent route --intent query --subject "memory allocation" --hint memory --confidence high --needs-ghost true --resonance 0.95 --decision-trace --evidence-trace --json
```

These commands are explicit and non-authorizing unless the agent route returns
`supported`. Query routing is read-only. Etch routing exposes whether mutation
would be allowed by contract; runtime meaning-matrix mutation still belongs in
the explicit etch path, not in inspection, calibration, smoke inference,
forward-schedule inspection, or conversation.

## Verification

Use:

```bash
zig build test-gemma-weights
zig build test-gemma-native
glslc src/shaders/rune_embed.comp -o /tmp/rune_embed.spv
glslc src/shaders/matmul_q4k.comp -o /tmp/matmul_q4k.spv
glslc src/shaders/matmul_q8_0.comp -o /tmp/matmul_q8_0.spv
glslc src/shaders/rms_norm.comp -o /tmp/rms_norm.spv
glslc src/shaders/swiglu.comp -o /tmp/swiglu.spv
glslc src/shaders/ghost_attention.comp -o /tmp/ghost_attention.spv
glslc src/shaders/rune_project.comp -o /tmp/rune_project.spv
```
