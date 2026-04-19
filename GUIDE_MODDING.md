# Ghost Engine: Sigil Control Plane

Ghost Engine does not currently support binary plugins, hot-loaded DLLs, or shader build hooks as a public extension surface. The supported control plane today is the Sigil Virtual Machine, plus the embedded shell's `POST /api/sigil` bridge for live scripts.

## What Is Supported

- `boot.sigil` at the repo root is the authoritative startup script for `ghost_sovereign`
- `ghost_sovereign` loads that file at boot and executes it through `src/sigil_vm.zig`
- `sigil_core` compiles `.sigil` source into `.sigbc` bytecode files
- `ghost_shell` accepts live Sigil over `POST /api/sigil` as raw text or JSON with a `script` or `sigil` field

The boot path that ships today executes `boot.sigil` source directly. There is no auto-scan of `src/`, no plugin directory contract, and no hot-reload path.

## What Is Not Supported

- Hot-loading `.dll` or `.so` modules
- Runtime plugin injection
- `zig build shaders`
- Automatic discovery of multiple Sigil scripts
- Boot-only assumptions for the live shell. `POST /api/sigil` is the supported live execution bridge.

The engine is a statically linked Sovereign Monolith by design. If a feature is not wired into `main.zig` or `shell.zig`, it is not part of the supported modding surface.

## Boot Script Location

Place the boot control script here:

```text
boot.sigil
```

At startup, `ghost_sovereign` resolves that exact path from the repo root. If the file is missing, the runtime falls back to `LOOM VULKAN_INIT`.

For live control-plane work, send scripts to:

```text
POST /api/sigil
```

That route accepts raw Sigil text or JSON with a `script` or `sigil` field.

## Live Chat Streaming

The embedded shell chat bridge now streams structured WebSocket frames over:

```text
GET /?channel=chat
```

Send prompts as JSON text frames:

```json
{"type":"input","text":"Describe the current resonance field."}
```

The server responds with structured JSON frames so the UI can render incremental output safely:

```json
{"type":"connected","content":"Ghost link established."}
{"type":"partial","content":"The current"}
{"type":"partial","content":" resonance field ..."}
{"type":"done"}
```

Streaming semantics:

- `partial` frames arrive as soon as the inference worker commits a token chunk into the live inventory
- `done` is emitted only after inference reaches a terminal stop (`STOP`, `VOID`, or end-of-sequence)
- `error` frames can arrive mid-stream if inference fails or if partial frames are dropped because the client cannot drain them quickly enough
- `POST /api/sigil` remains live during streaming, so hot-swapped mood shifts apply between inference steps without waiting for the whole reply to finish

The current repo example is:

```sigil
MOOD "focused"
LOOM VULKAN_INIT
LOCK 74
SCAN "system_memory"
```

## Opcode Reference

These are the working opcodes and keywords implemented in `sigil_core.zig` and executed by `sigil_vm.zig` today.

| Token | Kind | Effect |
|---|---|---|
| `MOOD` | User keyword | Adjusts the control-plane mood. String or identifier moods retune saturation and boredom penalties; integer form sets saturation bonus directly. |
| `LOOM` | User keyword | Chooses compute startup mode. `VULKAN_INIT` enables Vulkan if available. `CPU_ONLY` disables Vulkan for the session. Unknown commands are ignored. |
| `LOCK` | User keyword | Locks a semantic slot or hash in the active control plane. Accepts a numeric slot index or a symbolic label. |
| `SCAN` | User keyword | Queries the current runtime state. `SCAN "system_memory"` reports mapped state sizing. Other labels probe current semantic resonance. |
| `BIND` | User keyword | Binds a rune to a label and hard-locks that universal sigil in the meaning matrix. |
| `ETCH` | User keyword | Applies repeated gravity to a label-derived vector. The weight is clamped to `1..32` by the VM. |
| `VOID` | User keyword | Hard-locks a label to zero and records the hash as locked in the control plane. |
| `TEST` | User keyword | Conditionally executes a block from a literal condition parsed by the Sigil compiler. |
| `halt` | Internal opcode | Emitted automatically at the end of every compiled program. |
| `jmp_if_false` | Internal opcode | Emitted for `TEST`; jumps past the block when the condition is false. |

## Working Syntax

- Keywords are written as uppercase verbs such as `MOOD`, `LOOM`, and `ETCH`
- Strings use double quotes
- Integers can be decimal or hex
- `ETCH` weights can be written as a plain number or `@weight`
- Line comments can start with `//` or `#`

Example:

```sigil
MOOD "calm"
TEST 1 {
    LOOM CPU_ONLY
    LOCK "guardian"
    BIND 0x03A9 TO "omega"
    ETCH "omega field" @8
}
```

## Compile Workflow

Build the compiler:

```powershell
zig build -Doptimize=ReleaseFast
```

Compile a script:

```powershell
.\zig-out\bin\sigil_core.exe .\boot.sigil
```

This emits a `.sigbc` file beside the source unless you pass an explicit output path.

## Operational Notes

- `boot.sigil` is the active startup control plane for `ghost_sovereign`
- `ghost_shell` does not provide a separate plugin API
- The current runtime behavior is defined by the code in `src/sigil_core.zig`, `src/sigil_vm.zig`, `src/sigil_runtime.zig`, and `src/main.zig`

Document the shipped opcodes, the shipped boot path, and the shipped binaries. Everything else is speculation.
