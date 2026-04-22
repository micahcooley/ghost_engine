# Abstractions, Provenance, And Replay

This document covers the explicit abstraction system, trust and provenance behavior, and shard-local replay paths.

## Model

Abstractions are explicit records stored under the mounted shard. They are not implicit background learning.

Current record properties include:

- concept id
- tier and category
- lineage id and lineage version
- trust class
- decay state
- source list
- retained tokens and patterns
- bounded provenance entries

Current trust classes:

- `exploratory`
- `project`
- `promoted`
- `core`

Current decay states:

- `active`
- `stale`
- `prunable`
- `protected`

## Shell Commands

The current shell handles these abstraction commands through `POST /api/sigil`:

- `/commit_abstractions ...`
- `/reuse_abstractions ...`
- `/merge_abstractions ...`
- `/prune_abstractions ...`

The Linux shell requires an active scratch session before staging them.

## Distillation

`/commit_abstractions ...`:

- distills a bounded abstraction record from explicit source specs
- writes it to the shard-local staged abstraction catalog
- does not make it live until `commit`
- is cleared by `discard`
- is restored from the last snapshot by `revert` when scratch is inactive

## Reuse

`/reuse_abstractions ...` handles cross-shard reuse decisions.

Current behavior:

- cross-shard reuse is only available while mounted on a project shard
- source records come from the core shard
- decisions include `adopt`, `reject`, and `promote`
- local conflicts can require `promote` or `reject` instead of `adopt`

Reuse decisions are persisted separately from live abstraction records and become part of the mounted shard's state on commit.

## Merge

`/merge_abstractions ...` stages record merges across shards.

Current behavior:

- merge source can be core or another project shard
- self-merge is refused
- incompatible records are refused
- provenance and trust rules can refuse the merge
- promotion requires a strictly higher-trust destination
- exploratory or prunable content cannot be promoted into a higher-trust destination

Merges preserve or extend provenance rather than hiding source lineage.

## Prune

`/prune_abstractions ...` stages decay-state maintenance.

Current behavior:

- mark a concept `stale`
- mark a concept `prunable`
- refresh a concept back to `active`
- collect concepts that meet bounded prune rules

Prune operations append lineage and provenance entries such as `prune_mark_stale`, `prune_refresh`, and `prune_collect`.

## Provenance Behavior

Provenance is explicit and bounded.

Current properties:

- each record carries bounded provenance entries
- normalization backfills missing provenance on existing records
- merge paths preserve source provenance and add a new merge operation entry
- provenance merge can be refused by trust rules
- support references surface owner kind, owner id, lineage, trust class, resolution, and conflict state

This behavior is used by both abstraction workflows and the support traces exposed in code-intel and patch outputs.

## Replay And Snapshot Coverage

Snapshot replay is shard-local.

Current replay behavior:

- `begin scratch` captures a scratch baseline
- `discard` restores the baseline and clears staged abstraction and patch output
- `commit` applies staged abstraction output into the mounted shard and writes the committed snapshot
- `snapshot` copies the live abstraction catalog, reuse catalog, and lineage state into the shard snapshot slot
- `revert` restores those files from the saved snapshot slot when scratch is inactive

This means abstraction lineage and reuse state participate in replay for the mounted shard. Scratch-only staged work does not survive `discard`.

## Support And Provenance In Other Flows

The abstraction system feeds other shipped surfaces:

- `ghost_code_intel` uses abstraction lookups and symbolic grounding support
- `ghost_patch_candidates` includes abstraction references in support traces and benchmark coverage
- the serious-workflow suite checks provenance/support completeness and includes a case that requires abstraction references

## Current Limits

- abstractions are explicit; there is no automatic implicit semantic distillation path
- cross-shard reuse is bounded to current trust and provenance rules
- replay is shard-local, not a global multi-shard transaction system
