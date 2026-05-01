# Runtime And Setup

This document covers the current Linux-first build and runtime path.

## Supported Environment

- primary documented OS: Linux
- primary architecture in-tree: `platforms/linux/x86_64`
- Windows codepaths remain in the source tree, but current setup and operator docs are Linux-first

## Build Dependencies

- Zig
- `shaderc` for `glslc` when rebuilding compute shaders
- `libvulkan-dev` for Linux Vulkan builds and parity tests

```bash
sudo apt install shaderc libvulkan-dev
zig build seed
zig build -Doptimize=ReleaseFast
```

## Installed Binaries

- `ghost_sovereign`
- `ohl_trainer`
- `probe_inference`
- `sigil_core`
- `ghost_code_intel`
- `ghost_patch_candidates`
- `ghost_panic_dump`
- `ghost_task_intent`
- `ghost_task_operator`
- `ghost_corpus_ingest`
- `ghost_intent_grounding`
- `ghost_knowledge_pack`

## Common Build Steps

- `zig build`
- `zig build run`
- `zig build test`
- `zig build test-parity`
- `zig build seed`
- `zig build corpus`
- `zig build bench-serious-workflows`
- `zig build repo-hygiene`

## Clean Regeneration

A clean clone should not need committed runtime state. Regenerate local state and reports with:

```bash
zig build seed
zig build
zig build test
zig build bench-serious-workflows
zig build repo-hygiene
```

Generated outputs are reproducible from those entrypoints and are not source, except for the canonical benchmark report pair:

- `benchmarks/ghost_serious_workflows/results/latest-linux.json`
- `benchmarks/ghost_serious_workflows/results/latest-linux.md`

Ignored local-only paths:

- `.zig-cache/`, `.ghost_zig_cache/`, fixture-local `.ghost_zig_*_cache/`, and `zig-out/`
- `state/test/`
- `platforms/<os>/<arch>/state/`
- `logs/*`
- local corpus payloads under `corpus/`

## State Mount Model

The runtime mounts exactly one committed shard at a time:

- core shard: `platforms/linux/x86_64/state/shards/core/core/`
- project shard: `platforms/linux/x86_64/state/shards/projects/<id>/`

It then creates one shard-local scratch overlay on top of that mount.

Runtime state belongs only under the selected shard root. CLI tools that persist state write through the shard path resolver into `platforms/<os>/<arch>/state/` during normal runs or `state/test/` under `zig build test`. They should not write state into `src/` or the repository root.

Each committed shard owns:

- `unified_lattice.bin`
- `semantic_monolith.bin`
- `semantic_tags.bin`
- `sigil/`
- `abstractions/`
- `corpus_ingest/`
- `code_intel/`
- `patch_candidates/`

`corpus_ingest/` is shard-local and split into:

- `staged/`
- `live/`

Each side holds:

- `manifest.json`
- `files/`

## Knowledge Pack Storage

Knowledge Packs are explicit artifacts, not background memory.

- global pack store: `platforms/linux/x86_64/state/knowledge_packs/packs/<pack-id>/<version>/`
- project mount registry: `platforms/linux/x86_64/state/shards/projects/<id>/knowledge_packs/mounts.json`
- mounted-pack source projection: `@pack/<pack-id>/<version>/...`

Exports write a pack artifact into an empty destination directory. Non-empty export destinations are refused so an export cannot delete unrelated user files.

## Seeding

`zig build seed` seeds the selected committed shard.

- default target: core shard
- project target: set `GHOST_PROJECT_SHARD=<id>` before running `zig build seed`

## Runtime Startup

Run:

```bash
./zig-out/bin/ghost_sovereign
```

Useful flags:

- `--project-shard=<id>`
- `--scratchpad-bytes=<n>`
- `--reasoning-mode=proof|exploratory`
- `--daemon`
- `--no-shell`

At startup the runtime:

- mounts the selected shard
- verifies lattice checksums
- creates the scratch overlay
- installs the panic hook
- executes `boot.sigil`
- falls back to `LOOM VULKAN_INIT` when `boot.sigil` is absent

## Shell Surface

When enabled, the embedded shell binds to `http://127.0.0.1:8080`.

Current endpoints:

- `GET /api/stats`
- `GET /api/corpora`
- `GET /api/state`
- `GET /api/probe`
- `POST /api/train`
- `POST /api/stoptrain`
- `POST /api/pause`
- `POST /api/resume`
- `POST /api/checkpoint`
- `POST /api/control`
- `POST /api/sigil`
- `GET /?channel=chat`

## Scratch And Replay

Current scratch-control flow through `POST /api/sigil`:

- `begin scratch`
- `discard`
- `commit`
- `snapshot`
- `revert`
- `rollback`

Behavior:

- `begin scratch` captures a shard-local discard baseline
- `discard` restores the baseline and clears staged abstraction and patch state
- `commit` applies scratch state into the mounted shard and writes the committed snapshot
- `snapshot` and `revert` require scratch to be inactive

Scratch is overlay state, not a separate committed shard.

## Corpus Ingestion

Run the ingestion CLI explicitly when you want to import a bounded external subset:

```bash
./zig-out/bin/ghost_corpus_ingest <corpus-path> \
  --project-shard=<id> \
  --trust-class=project \
  --source-label=<label>
```

Apply that staged corpus explicitly before expecting live-corpus readers such as `corpus.ask` to see it:

```bash
./zig-out/bin/ghost_corpus_ingest --apply-staged --project-shard=<id>
```

Important behavior:

- ingestion is Linux-first and manual only
- there are no watchers and no auto-ingest
- staged corpus data is cleared by `discard`
- manual `ghost_corpus_ingest` output stays staged until an explicit `--apply-staged` or a later `commit`
- operator-driven external evidence is different: the task-support recovery path applies the staged set into shard-local live corpus immediately before rerunning support
- live corpus data participates in shard-local `code_intel` and symbolic grounding
- `snapshot` and `revert` cover live corpus state along with the rest of the shard

## Compute

- Layer 2a GPU support is optional and bounded
- Layer 2b stays CPU-first and authoritative
- shader binaries are embedded from `src/shaders/*.spv`
- rebuild shaders on Linux with `./compile_shaders.sh`
- after shader edits, use `zig build test-parity`

## Reasoning Levels And Verifier Hooks

The normal user-facing control is `--reasoning=quick|balanced|deep|max`. It means how hard Ghost should try, not a direct response-mode selector:

- `quick` is fast and minimal effort.
- `balanced` is the default.
- `deep` is more thorough and may verify when useful.
- `max` is the most thorough setting, but it does not force deep execution when deep adds no value.

The Phase 3 response engine is a bounded control surface over grounded artifact obligations. Internal modes are automatic policy outcomes:

- `draft_mode` is unverified only. Draft results stay `unresolved`, report `verificationState=unverified`, and include assumptions or missing information.
- explicit verify/proof/test/correctness requests and patch-capable action surfaces are not allowed to complete through draft mode.
- `fast_path` requires the same explicit eligibility gate used by auto mode and does not run speculative scheduling or verifier hooks.
- `deep_path` is the verifier-capable path. Verifier hook outputs are evidence; they do not directly authorize final support without the support graph and obligation gates.
- budget exhaustion remains a first-class stop reason and is not collapsed into ordinary unresolved output.

Trace JSON continues to report `requested_reasoning_level`, `effective_compute_budget_tier`, `selected_response_mode`, and `mode_selection_reason` so advanced inspection can see the automatic selection without exposing mode choice as the normal UX.

## Panic Dumps

Panic dumps are implemented on Linux at:

```text
/tmp/ghost-dd-panic.bin
```

The format is deterministic and versioned. It records the last bounded reasoning trace plus scratch references when present.

Inspect and replay them with:

```bash
./zig-out/bin/ghost_panic_dump read /tmp/ghost-dd-panic.bin
./zig-out/bin/ghost_panic_dump replay /tmp/ghost-dd-panic.bin
./zig-out/bin/ghost_panic_dump replay /tmp/ghost-dd-panic.bin --render=json
./zig-out/bin/ghost_panic_dump replay /tmp/ghost-dd-panic.bin --render=report
```

`ghost_patch_candidates` can also emit a deterministic dump snapshot after a bounded run without mutating live state:

```bash
./zig-out/bin/ghost_patch_candidates breaks-if src/api/service.zig:compute --repo=/abs/repo --emit-panic-dump
```

`ghost_task_operator` reuses the same replay surface from recorded task state:

```bash
./zig-out/bin/ghost_task_operator replay --task-id=<task-id> --render=report
```

## Current Limits

- current docs are Linux-first by design
- there is no broader cross-platform packaging guide yet
- the runtime is honesty-gated; exploratory mode does not bypass support requirements
