# Ghost Engine

Deterministic local inference and training over memory-mapped state, with Vulkan compute when available and CPU fallback when it is not.

## What Ships Today

Ghost Engine currently builds and installs these executables from `build.zig`:

- `ghost_sovereign` - interactive inference runtime
- `ohl_trainer` - corpus-driven trainer
- `probe_inference` - inference probe utility
- `ghost_shell` - local HTTP/WebSocket dashboard with a `POST /api/sigil` bridge
- `sigil_core` - Sigil compiler

`build.zig` also exposes these named steps:

- `zig build run`
- `zig build release`
- `zig build test`
- `zig build test-parity`
- `zig build probe-unicode`
- `zig build seed`
- `zig build corpus`

## Windows Setup

### 1. Bootstrap Zig

```powershell
.\platforms\windows\sylor_forge.ps1
```

The forge installs Zig into `platforms/windows/.toolchain/zig`. It does not download the Vulkan SDK.

### 2. Seed the mapped state

```powershell
.\tools\seed_lattice.ps1
```

This creates the current Windows runtime state under `platforms/windows/x86_64/state/`:

- `unified_lattice.bin`
- `semantic_monolith.bin`
- `semantic_tags.bin`

### 3. Build from the repo root

```powershell
$env:PATH = "$(Get-Location)\platforms\windows\.toolchain\zig;" + $env:PATH
zig build -Doptimize=ReleaseFast
```

If your Windows toolchain needs Vulkan headers from a local SDK install, set `VULKAN_SDK` yourself before building. The forge does not provision one.

### 4. Copy the binaries into the packaged runtime layout

```powershell
Copy-Item .\zig-out\bin\*.exe .\platforms\windows\x86_64\bin\ -Force
```

The Windows runtime layout expected by the packaged binaries is:

- `platforms/windows/x86_64/bin/`
- `platforms/windows/x86_64/corpus/`
- `platforms/windows/x86_64/state/`

## Training

`ohl_trainer` does not take a corpus filepath on the command line. It scans the runtime `corpus/` directory for `.txt` files and trains on every file it finds.

On the packaged Windows layout, put your text files here:

```text
platforms/windows/x86_64/corpus/
```

Then run:

```powershell
.\platforms\windows\x86_64\bin\ohl_trainer.exe
```

If no corpus files are present, the trainer falls back to a synthetic benchmark stream.

## Runtime Modes

### Interactive runtime

```powershell
.\platforms\windows\x86_64\bin\ghost_sovereign.exe
```

`ghost_sovereign` maps the state files, executes `boot.sigil` from the repo root if it exists, verifies lattice checksums, and enters the REPL.
The same Sigil VM also powers the live `POST /api/sigil` bridge in the embedded shell.

### Background daemon mode

```powershell
.\platforms\windows\x86_64\bin\ghost_sovereign.exe --daemon
```

Daemon mode starts the named-pipe bridge used by the surveillance layer while keeping the main runtime alive.

### Local dashboard

```powershell
.\platforms\windows\x86_64\bin\ghost_shell.exe
```

`ghost_shell` serves a local dashboard on `http://127.0.0.1:8080` and exposes the current stats, corpus, state, probe, chat, training control, and Sigil bridge endpoints wired into `src/shell.zig`.

The live bridge accepts raw Sigil text or JSON with a `script` or `sigil` field:

```text
POST /api/sigil
```

## Sigil Control Plane

The repo-root `boot.sigil` file is the current startup control plane for `ghost_sovereign`. The runtime executes it through the Sigil VM at boot. If `boot.sigil` is missing, the runtime falls back to `LOOM VULKAN_INIT`.

For live control-plane work, use the embedded shell bridge:

```text
POST /api/sigil
```

That route accepts raw Sigil text or JSON with a `script` or `sigil` field.

To compile a Sigil source file into bytecode manually:

```powershell
.\zig-out\bin\sigil_core.exe .\boot.sigil
```

The runtime boot path currently executes `boot.sigil` source directly; it does not scan directories for scripts or plugins.

## Determinism Constraints

- Keep the core bitwise. Do not introduce floating point into the resonance path.
- Keep CPU and Vulkan behavior aligned. `src/shaders/*.comp` must match the CPU logic.
- Treat the mapped state files as live engine state, not disposable cache.

## License

See [LICENSE](LICENSE).
