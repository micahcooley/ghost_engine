# Sigil Reference

This file is the quick source-backed reference for the Sigil compiler and VM in this repository.

## Runtime Keywords

| Token | Kind | Notes |
|---|---|---|
| `MOOD` | User keyword | Accepts a string, identifier, or integer. Named moods retune saturation and boredom penalties. Integer form sets the saturation bonus directly. |
| `LOOM` | User keyword | Accepts an identifier. `VULKAN_INIT` enables Vulkan if available. `CPU_ONLY` disables Vulkan for the session. Unknown values compile to `none` and are ignored at runtime. |
| `LOCK` | User keyword | Accepts a number for a slot index or a string/identifier for a symbolic hash lock. |
| `SCAN` | User keyword | Accepts a string or identifier target. `system_memory` reports mapped state sizing. |
| `BIND` | User keyword | Accepts a rune number, optional `TO`, then a string or identifier label. |
| `ETCH` | User keyword | Accepts a string or identifier payload, plus an optional weight literal or number. The VM clamps the weight to `1..32`. |
| `VOID` | User keyword | Accepts a string or identifier payload and hard-locks it to zero. |
| `TEST` | User keyword | Accepts a literal condition, then a `{ ... }` block. |

## Internal Opcodes

| Opcode | Role | Notes |
|---|---|---|
| `halt` | Internal | Emitted automatically at the end of each compiled program. |
| `jmp_if_false` | Internal | Emitted by `TEST` to skip the block when the condition is false. |

## Operand Modes

The compiler currently emits these operand modes:

| Mode | Meaning |
|---|---|
| `none` | No operand payload. |
| `string` | String table reference. |
| `integer` | Signed integer payload. |
| `rune_and_string` | Rune value plus a string table reference. |
| `loom_command` | Encoded `LOOM` command. |
| `immediate_bool` | Immediate boolean used by `TEST`. |

## Supported `LOOM` Commands

| Command | Effect |
|---|---|
| `VULKAN_INIT` | Enables Vulkan if it is available. |
| `CPU_ONLY` | Forces the session into CPU-only mode. |

## Syntax Notes

- Strings use double quotes.
- Integers can be decimal or hex.
- Comments can start with `//` or `#`.
- `ETCH` weights can be written as a plain number or `@weight`.
- `TEST` uses braces for its block body.

## Live Execution

The embedded shell accepts live Sigil through:

```text
POST /api/sigil
```

That route accepts either raw Sigil text or JSON with a `script` or `sigil` field.
