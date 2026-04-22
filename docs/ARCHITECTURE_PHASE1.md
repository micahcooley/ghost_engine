# Architecture Phase 1

This file tracks intentionally deferred work only. Nothing here should be read as current shipped behavior.

Use [README.md](../README.md), [ARCHITECTURE.md](../ARCHITECTURE.md), [GUIDE_ARCHITECTURE.md](../GUIDE_ARCHITECTURE.md), and the focused docs in this directory for the implemented stack.

## Deferred Work

- Productize a more operator-friendly runtime selector and policy UX around proof versus exploratory reasoning
- Expand the code-intel pilot beyond the current bounded `impact`, `breaks-if`, and `contradicts` queries without weakening honesty guarantees
- Add a first-party panic dump reader instead of relying on raw binary inspection
- Add richer shard administration and operator tooling around project creation, seeding, and snapshot management
- Add a positive runtime-verified patch fixture so the serious-workflow runtime-pass metric becomes non-empty
- Revisit non-Linux packaging and runtime docs after the Linux-first stack stops moving
