# Ghost Engine: Sigil Control Plane

Ghost Engine does not currently support binary plugins, hot-loaded DLLs, or shader build hooks as a public extension surface. The supported control plane today is the Sigil Virtual Machine.

## What Is Supported

- `boot.sigil` at the repo root is the authoritative startup script for `ghost_sovereign`
- `ghost_sovereign` loads that file at boot and executes it through `src/sigil_vm.zig`
- `sigil_core` compiles `.sigil` source into `.sigbc` bytecode files

The boot path that ships today executes `boot.sigil` source directly. There is no auto-scan of `src/`, no plugin directory contract, and no hot-reload path.

## What Is Not Supported

- Hot-loading `.dll` or `.so` modules
- Runtime plugin injection
- `zig build shaders`
- Automatic discovery of multiple Sigil scripts

The engine is a statically linked Sovereign Monolith by design. If a feature is not wired into `main.zig` or `shell.zig`, it is not part of the supported modding surface.

## Boot Script Location

Place the boot control script here:

```text
boot.sigil
```

At startup, `ghost_sovereign` resolves that exact path from the repo root. If the file is missing, the runtime falls back to `LOOM VULKAN_INIT`.

The current repo example is:

```sigil
MOOD "focused"
LOOM VULKAN_INIT
LOCK 74
SCAN "system_memory"
```

## Opcode Reference

These are the working opcodes implemented in `sigil_core.zig` and executed by `sigil_vm.zig` today.

| Opcode | Effect |
|---|---|
| `MOOD` | Adjusts the control-plane mood. Named moods such as `"aggressive"`, `"focused"`, and `"calm"` retune saturation and boredom penalties. Integer form sets saturation bonus directly. |
| `LOOM` | Chooses compute startup mode. `VULKAN_INIT` enables Vulkan if available. `CPU_ONLY` disables Vulkan for the session. |
| `LOCK` | Locks a semantic slot or hash in the active control plane. Accepts a numeric slot index or a symbolic label. |
| `SCAN` | Queries the current runtime state. `SCAN "system_memory"` reports mapped state sizing. Other labels probe current semantic resonance. |
| `BIND` | Binds a rune to a label and hard-locks that universal sigil in the meaning matrix. |
| `ETCH` | Applies repeated gravity to a label-derived vector. The weight is clamped by the VM. |
| `VOID` | Hard-locks a label to zero and records the hash as locked in the control plane. |
| `TEST` | Conditionally executes a block from a literal condition parsed by the Sigil compiler. |

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
