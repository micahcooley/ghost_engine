# Ghost Engine: Sovereign Plugin Architecture

Welcome to the native optimization layer. This directory allows you to extend the Ghost Engine's performance without modifying the core platform-agnostic code.

## 🛠️ Native Plugins (.dll / .so)

Native plugins are compiled Zig/C shared libraries that run at the same speed as the engine. They are ideal for:
- Hardware-specific optimizations (Core Affinity, Power Plans)
- GPU Driver tweaks
- Custom telemetry and monitoring

### Plugin Interface (`plugin_api.zig`)

Every plugin must export the following standard functions:

```zig
export fn init() void;      // Called on startup
export fn optimize() void;  // Called periodically during training
export fn cleanup() void;  // Called on shutdown
```

### Enabling Plugins

To enable native plugins, pass the `--plugins` flag to the trainer:

```powershell
./ohl_trainer.exe corpus/wikitext.txt --plugins
```

## 📜 Sigil Scripts (.sigil)

This directory also contains Sigil scripts. While native plugins optimize the *hardware*, Sigils optimize the *meaning matrix* directly via bitwise resonance.

---

**Current Active Plugins:**
- `windows_beast.dll`: Seizes Windows priority, timer resolution, and core affinity.
