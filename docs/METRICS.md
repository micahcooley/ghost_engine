# Metrics

## Truth Density

Truth Density is daemon telemetry for the current resident rune set:

```text
truth_density = verified_runes / (verified_runes + shadow_runes)
```

The JSON field is emitted as `daemon.truthDensity.ratioPerMille` so it stays
integer-only and stable across CLI renderers. `1000` means every counted resident
rune is verified; `0` means no verified resident rune is currently counted.

Counted categories:

- `verifiedRunes`: resident entries with verified, axiom-locked, promoted, or
  core authority metadata.
- `shadowRunes`: resident entries with exploratory, unverified, shadow, or low
  authority metadata.

Truth Density is diagnostic telemetry only. It is not proof, does not authorize a
supported answer, and does not let GPU similarity promote evidence.

## Oracle RAM Guard

The daemon reports `ramUsedBytes` and `oraclePausedForRam`. The oracle pauses new
verification work when used system RAM exceeds 12GB, preserving the 16GB machine
boundary documented in `docs/HETEROGENEOUS_MEMORY.md`.

## Lattice Coherence

Lattice Coherence estimates how tightly nearby resident VSA runes cluster in the
current projection. `lattice_view` exports each point with a `coherence` value in
`0.0...1.0`, derived from 1024-bit hypervector similarity to its deterministic
neighbor in the active export set.

Interpretation:

- closer to `1.0`: neighboring runes are highly similar and may be forming a
  tight semantic cluster.
- near `0.5`: roughly orthogonal binary hypervectors, usually normal separation.
- closer to `0.0`: strong opposition or intentionally distant concepts.

Coherence is visualization telemetry only. It can show that `warm tape
saturation` is drifting toward `digital distortion`, but it is not proof,
support, or a verifier result.
