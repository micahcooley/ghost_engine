# Ghost Architecture Handbook

This document describes implemented behavior and operator vocabulary for the
current Ghost stack. It is not a roadmap.

## Hybrid Lens

Ghost separates fast similarity from final authority.

- The Vulkan path uses `f32` lanes for bounded approximate search. It can rank,
  cluster, and narrow candidates quickly, including SimHash-style semantic
  prefiltering.
- The CPU path keeps `u32` and structured symbolic state as the truth layer. It
  performs branch-heavy checks, obligation accounting, support routing, and final
  permission decisions.
- A high similarity score is never proof. It is a lens for finding candidates
  that still need symbolic validation.

The practical rule is: GPU similarity may suggest where to look; CPU symbolic
logic decides whether anything is supported.

## Latent Intent Inference

`intent_grounding` projects user text into a small deterministic `f32` concept
space. The current concept families are conversation, modification, retrieval,
and meta-analysis.

If a request does not cross the heavy-task confidence threshold, Ghost falls back
to conversational reasoning. In that mode it does not require a
`bind_target_artifact` obligation. Code-heavy requests still require concrete
artifact grounding before they can move toward support.

This is the Intent Fallback rule: low-confidence task routing talks first, and
only asks for paths or bindings when the user actually expresses code-heavy work.

## Authority Ranks

Ghost treats source authority as explicit metadata, not vibes.

- Rank 0, Sovereign or Zenith: local root authority. This is the highest-trust
  operator/project layer and may anchor project-specific reasoning.
- Rank 1, Verified: reviewed project or corpus material that has been promoted
  by an explicit human workflow.
- Rank 2, Public or Wiki: public corpus/reference material. It can inform
  answers but cannot outrank local sovereign project state.
- Rank 3, Shadow: retained but low-trust material. It may surface as a warning
  or contrast candidate.
- Rank 4, Trash: rejected material. Matches should be treated as falsehood or
  blocked influence, not evidence.

Authority ranks constrain support. They do not replace verifier evidence.

## Zen Mode

The CLI/TUI defaults to Zen Mode for ordinary conversation:

- user text renders in white
- Ghost text renders in blue
- obligations, ambiguity sets, missing-info sections, debug counters, and raw
  authority scaffolding are hidden

Details are explicit:

- CLI: pass `--details`
- TUI launch: pass `ghost tui --details`
- TUI runtime: run `/details on` or `/details off`
- Debug mode also enables details because it is a diagnostic path

Zen Mode changes presentation only. It does not grant support, hide engine
failures from raw JSON, or change the underlying proof contract.

## Glossary

SimHash64:
A 64-bit deterministic semantic fingerprint used for compact approximate
candidate comparison. It is useful for search narrowing, not final support.

Rune Validation:
The symbolic validation pass that checks retained text/code fragments as bounded
meaning units. Runes are inspectable units; they are not model tokens and do not
imply neural training.

Intent Fallback:
The deterministic fallback from low-confidence heavy-task routing to
conversation. It prevents casual prompts such as `hi`, `test`, or broad status
questions from failing on artifact-binding obligations.

Hybrid Lens:
The architecture pattern where `f32` Vulkan similarity finds candidates and
`u32`/structured CPU logic decides truth, rank, and support.
