# Phase 4/5/6 Control Surfaces

This implementation exposes bounded foundations for the Phase 4/5/6 blueprint
without granting hidden authority.

## Phase 4: Autonomous Reflex

- `oracle.auto_fix` captures Zig compiler stderr, classifies deterministic
  diagnostics, and can verify temp-buffer candidate repairs for narrow cases
  such as unused local declarations.
- Source files are not mutated by this operation.
- Candidate success is reported as `verified_candidate`, not proof of broader
  correctness.
- Failed cycles are labeled `tier_5_trash_candidate` with
  `unstableCoordinates:true`.

`curiosity.status` reports CPU/load/RAM/audio-priority guards and speculative
audio candidates. It does not start a background worker or run `zig test` from
status inspection.

## Phase 5: Spectral Hive

- `hive.status` declares the local UDP gossip packet/rune contract.
- Runes are 1024-bit packets.
- Remote cache is Tier 6.
- Network join and UDP send are disabled by default.
- A remote rune is rejected unless the local Oracle proves it.

## Phase 6: Singularity Bridge

- `recursive_boot.status` measures the current `vsa.hypervector.bind` hot path.
- Hot swap is disabled by default.
- Swap eligibility requires a verified candidate, at least 5% speedup, and
  latency within the 15ms target.
- This status operation does not generate code, compile a replacement binary,
  create shared memory state transfer, or call `execve`.

All surfaces are explicit GIP calls and remain non-authorizing unless a future
reviewed apply/swap operation is added with its own verification boundary.
