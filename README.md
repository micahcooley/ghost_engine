# Ghost Engine

Deterministic local inference and training over memory-mapped state, with optional Vulkan compute. The shipped stack is Linux-first, shard-aware, and bounded. Deferred work is tracked in [docs/ARCHITECTURE_PHASE1.md](docs/ARCHITECTURE_PHASE1.md); it is not current behavior.

## Current Stack

- Layer 1 is a shard-aware memory civilization: one mounted committed shard plus one shard-local scratch overlay.
- `ghost_code_intel` builds a bounded semantic code graph for Zig-first repositories, with bounded native-code indexing and symbolic ingestion for docs, config, markup, and DSL-like files.
- `ghost_patch_candidates` runs an explicit `explore_then_proof` flow: exploratory candidate generation, clustered handoff into proof mode, bounded build/test/runtime verification, then minimal verified survivor selection.
- Support output is permissioned. Final `supported` results require both decision traces and evidence traces; otherwise the result is forced back to `unresolved`.
- Abstractions, reuse, merge, prune, and replay are explicit shard-local workflows with recorded provenance and trust boundaries.

## What Ships

`build.zig` installs:

- `ghost_sovereign`
- `ohl_trainer`
- `probe_inference`
- `sigil_core`
- `ghost_code_intel`
- `ghost_patch_candidates`
- `ghost_task_intent`

Named build steps:

- `zig build`
- `zig build run`
- `zig build test`
- `zig build test-parity`
- `zig build release`
- `zig build seed`
- `zig build corpus`
- `zig build bench-serious-workflows`

## Linux Build

Dependencies:

- Zig
- `shaderc` for `glslc` when rebuilding shaders
- `libvulkan-dev` for Linux Vulkan builds and parity tests

```bash
sudo apt install shaderc libvulkan-dev
zig build seed
zig build -Doptimize=ReleaseFast
```

`zig build seed` seeds the selected committed shard. By default that is the core shard. Set `GHOST_PROJECT_SHARD=<id>` first if you want to seed a project shard instead.

Windows codepaths remain in the tree for compatibility and parity coverage, but the current setup, runtime, and workflow docs are Linux-first.

## Runtime

Run the main runtime:

```bash
./zig-out/bin/ghost_sovereign
```

Useful flags:

- `--project-shard=<id>` mounts a project shard instead of the core shard
- `--scratchpad-bytes=<n>` sizes the shard-local scratch overlay
- `--reasoning-mode=proof|exploratory` selects the control-plane reasoning mode at runtime
- `--daemon` starts the surveillance bridge thread and keeps the runtime alive
- `--no-shell` disables the embedded shell

At startup `ghost_sovereign`:

- mounts the selected committed shard
- verifies lattice checksums
- creates a shard-local scratch overlay
- installs panic dump hooks
- executes `boot.sigil` from the repo root compiled into `build_options.project_root`
- falls back to `LOOM VULKAN_INIT` when `boot.sigil` is missing

When enabled, the embedded shell listens on `http://127.0.0.1:8080`.

Current shell surface:

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

## State Layout

Layer 1 is implemented as shard-aware committed state plus scratch:

- core committed shard: `platforms/linux/x86_64/state/shards/core/core/`
- project committed shard: `platforms/linux/x86_64/state/shards/projects/<id>/`
- scratch behavior: overlay attached to the mounted committed shard, not a separate committed shard

Each committed shard owns:

- `unified_lattice.bin`
- `semantic_monolith.bin`
- `semantic_tags.bin`
- `sigil/`
- `abstractions/`
- `code_intel/`
- `patch_candidates/`

Scratch and snapshot behavior is real and shard-local through `POST /api/sigil`:

- `begin scratch`: clears the overlay, captures a shard-local baseline, and starts a discardable session
- `discard`: drops staged overlay data, restores the saved scratch baseline, clears staged abstractions and staged patch batches, and ends the session
- `commit`: applies the overlay into the mounted shard's permanent mappings, applies staged abstractions, clears staged patch batches, writes the committed snapshot, and ends the session
- `snapshot`: writes a full shard-local snapshot when no scratch session is active
- `revert` or `rollback`: restores the last snapshot when no scratch session is active

`snapshot` and `revert` are blocked while scratch is active.

## Code Intel And Patch Flow

`ghost_code_intel` is a deterministic pilot, not a general semantic understanding system.

Supported query kinds:

- `impact`
- `breaks-if`
- `contradicts`

Current implemented scope:

- Zig-first native indexing
- bounded native-code support for `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`
- symbolic ingestion for `.md`, `.txt`, `.rst`, `.toml`, `.yaml`, `.yml`, `.json`, `.ini`, `.cfg`, `.conf`, `.env`, `.xml`, `.html`, `.rules`, and `.dsl`
- cross-symbol grounding from symbolic units into bounded code or runtime targets when deterministic support exists

Persisted shard-local outputs:

- `code_intel/last_query.txt`
- `code_intel/last_result.json`
- `code_intel/cache/index_v1.gcix`

`ghost_patch_candidates` consumes the same bounded code-intel surfaces and adds:

- proof-backed patch scaffolds
- bounded execution verification
- minimal-safe-refactor planning
- explicit `explore_then_proof` handoff reporting
- support graph output with permission metadata

## Benchmark Snapshot

Latest Linux serious-workflow report in this workspace:

- suite status: 15/15 cases passed cleanly
- verified supported patch results: 5
- patch compile-pass rate: 85% (12/14 candidate build attempts)
- test-pass rate: 75% (9/12 candidate test attempts)
- runtime-pass rate: 0% (0/0 attempted runtime-verification steps)
- latency per verified result: 6940 ms
- cold start / warm start: 40 ms / 56 ms
- cold cache changed files / warm cache changed files: 11 / 0

The `runtime-pass rate` is `0/0` because the suite does not yet contain a positive runtime-verified patch fixture. It does not mean the execution harness is currently failing.

Run the suite with:

```bash
zig build bench-serious-workflows
```

The runner writes fresh reports under `benchmarks/ghost_serious_workflows/results/`.

## Docs

- [ARCHITECTURE.md](ARCHITECTURE.md): implemented stack overview
- [GUIDE_ARCHITECTURE.md](GUIDE_ARCHITECTURE.md): short operator view
- [docs/RUNTIME_SETUP.md](docs/RUNTIME_SETUP.md): build, runtime, shell, and shard setup
- [docs/CODE_INTEL_AND_PATCHING.md](docs/CODE_INTEL_AND_PATCHING.md): code-intel, task-intent, patch generation, and support graph behavior
- [docs/ABSTRACTIONS_PROVENANCE_REPLAY.md](docs/ABSTRACTIONS_PROVENANCE_REPLAY.md): abstractions, provenance, trust, reuse, merge, prune, snapshot, and replay behavior
- [docs/SERIOUS_WORKFLOWS_AND_BENCHMARKS.md](docs/SERIOUS_WORKFLOWS_AND_BENCHMARKS.md): serious-workflow suite layout and current measured scope
- [SIGIL_REFERENCE.md](SIGIL_REFERENCE.md): current Sigil and shell command surface
- [docs/ARCHITECTURE_PHASE1.md](docs/ARCHITECTURE_PHASE1.md): intentionally deferred work only

## Limits

- Layer 2a is bounded GPU assistance only. Layer 2b stays CPU-first and authoritative.
- Exploratory reasoning exists in code, but the runtime remains honesty-gated and does not ship a hype-first "best guess" mode.
- Symbolic ingestion is bounded structural grounding. It is not universal semantic understanding of arbitrary repositories.
- If a feature is staged, scaffolded, or bounded, the docs call that out directly.

## License

See [LICENSE](LICENSE).
