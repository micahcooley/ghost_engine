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
- `ghost_task_intent`

## Common Build Steps

- `zig build`
- `zig build run`
- `zig build test`
- `zig build test-parity`
- `zig build seed`
- `zig build corpus`
- `zig build bench-serious-workflows`

## State Mount Model

The runtime mounts exactly one committed shard at a time:

- core shard: `platforms/linux/x86_64/state/shards/core/core/`
- project shard: `platforms/linux/x86_64/state/shards/projects/<id>/`

It then creates one shard-local scratch overlay on top of that mount.

Each committed shard owns:

- `unified_lattice.bin`
- `semantic_monolith.bin`
- `semantic_tags.bin`
- `sigil/`
- `abstractions/`
- `code_intel/`
- `patch_candidates/`

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

## Compute

- Layer 2a GPU support is optional and bounded
- Layer 2b stays CPU-first and authoritative
- shader binaries are embedded from `src/shaders/*.spv`
- rebuild shaders on Linux with `./compile_shaders.sh`
- after shader edits, use `zig build test-parity`

## Panic Dumps

Panic dumps are implemented on Linux at:

```text
/tmp/ghost-dd-panic.bin
```

The format is deterministic and versioned. It records the last bounded reasoning trace plus scratch references when present.

## Current Limits

- current docs are Linux-first by design
- there is no broader cross-platform packaging guide yet
- the runtime is honesty-gated; exploratory mode does not bypass support requirements
