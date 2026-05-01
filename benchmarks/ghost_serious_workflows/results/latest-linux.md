# Ghost Serious Workflow Benchmarks (linux)

- total cases: 42
- passed cases: 42
- failed cases: 0
- total benchmark wall time: 136848 ms
- code impact correctness rate: 100%
- contradiction detection correctness rate: 100%
- unresolved-vs-unsupported correctness rate: 100%
- minimal-safe-refactor correctness rate: 100%
- execution-loop handling rate: 100%
- provenance/support completeness rate: 96%
- support/provenance completeness: 27/28
- verified-complete workflow rate: 100%
- blocked workflow rate: 100%
- unresolved workflow rate: 100%
- replay-from-task workflow rate: 100%
- external-evidence-assisted workflow rate: 100%
- runtime-verified patch workflow rate: 100%
- verified supported patch results: 13
- patch compile-pass rate: 84% (16/19)
- test-pass rate: 87% (14/16)
- runtime-pass rate: 83% (5/6)
- verifier adapters: runs=38, passed=32, failed=6, blocked=0, skipped=0, budget_exhausted=0
- verifier domains: code=36, non_code=2
- latency per verified result: 7074 ms
- cold start / warm start: 267 ms / 336 ms
- cold cache changed files / warm cache changed files: 15 / 0
- workflow cases: 7; passing workflow cases: 7
- task-state distribution: planned=0, running=0, blocked=2, unresolved=1, verified_complete=4, failed=0
- replay coverage: 1/1 replay workflow case(s) fully replayable
- external evidence outcomes: not_needed=5, requested=0, fetched=0, ingested=2, conflicting=0, insufficient=0
- partial-finding preservation rate: 100% (5/5)
- ambiguity preservation rate: 100% (1/1)
- suppressed-noise count: 46
- reinforcement event count: 3
- reinforcement reuse hit count: 3
- reinforcement reuse hit rate after reinforcement: 100%
- draft intent resolution improvement: 7% measurable event coverage
- unsupported proof-admission block count: 3
- measured repo scan / cache refresh / index materialize: 825 / 4011 / 507 ms
- measured support-aware routing index build: 171 ms; considered / selected / skipped / suppressed / cap_hits: 12 / 12 / 0 / 0 / 0
- discovery signals: retained_token=0, retained_pattern=0, schema_entity=4, schema_relation=0, obligation=8, anchor=4, verifier_hint=3, fallback_used=0
- universal hypotheses: generated=9, selected=3, suppressed=7, budget_hits=1, rules_fired=2, code=8, non_code=1
- hypothesis triage: selected=3, suppressed=6, duplicates=0, budget_hits=0, selected_code=2, selected_non_code=1
- hypothesis verifier handoff: eligible=3, scheduled=1, completed=0, blocked=1, skipped=1, budget_exhausted=1, code_jobs=1, non_code_jobs=2
- verifier candidates: proposed=2, blocked=0, accepted=0, materialized=1, rejected=0, materialization_blocked=0, budget_hits=0, code=1, non_code=1
- measured pack mount resolve / manifest preview load / pack routing / pack catalog load: 1372 / 1124 / 245 / 1720 ms
- measured pack candidate surfaces / activated packs / skipped packs: 21 / 25 / 24
- measured pack budget cap hits / local-truth wins: 4 / 1
- measured support graph build: 163 ms
- response mode distribution: draft=1, fast=1, deep=1
- measured response mode selection / draft path / fast path / deep path: 0 / 2 / 1 / 2 ms
- measured artifact schema pipeline / verifier adapter dispatch: 7 / 8 ms
- measured artifact json render / persist / panic capture: 0 / 0 / 0 ms
- measured verification workspace / build / test / runtime: 4032 / 66085 / 11233 / 6214 ms
- measured task artifact writes: 7 ms across 30 writes
- measured task session saves: 22 ms across 25 saves
- verifier candidate execution: 0 eligible, 0 scheduled, 0 completed, 0 failed, 0 blocked, 0 budget-hit
- correction events: 0; correction summaries: 0; correction rendered: 0; negative knowledge candidates: 0
- negative knowledge rendering: influence_summaries=0, applied_rendered=0, stronger_verifier_rendered=0, exact_repeat_suppression_rendered=0
- epistemic rendering: corrections=0, negative_knowledge=0, verifier_requirements=0, suppressions=0
- negative knowledge lifecycle: accepted=0, rejected=0, influence_matches=0, triage_penalties=0, verifier_requirements=0, verifier_blocked=0, verifier_strengthened=0, trust_decay_candidates=0

Notes:
- patch compile-pass and test-pass rates are per attempted candidate verification step, not per benchmark case.
- runtime-pass rate is per attempted bounded runtime-oracle step after build/test verification.
- cold versus warm cache measurements are reported factually; the suite checks shard-local cache behavior, not a guarantee that warm latency is always lower.

## Pack Scaling

- small vs large pack manifest preview / routing / catalog load delta: 152 / 32 / 246 ms
- small vs large pack peak candidate surfaces / peak activated / skipped delta: 3 / 2 / -4
- tier comparison:
  low -> peak_activated=1, peak_candidate_surfaces=2, cap_hits=4, routing_ms=26
  high -> peak_activated=3, peak_candidate_surfaces=5, cap_hits=0, routing_ms=52
  max -> peak_activated=3, peak_candidate_surfaces=5, cap_hits=0, routing_ms=68

## Case Results

- `impact_widget_to_service`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=9; packs=0/0/0; pack_candidates=0; cap_hits=0
- `contradiction_call_site`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=10; packs=0/0/0; pack_candidates=0; cap_hits=0
- `contradiction_signature`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=10; packs=0/0/0; pack_candidates=0; cap_hits=0
- `contradiction_ownership`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=2; support_nodes=13; packs=0/0/0; pack_candidates=0; cap_hits=0
- `ambiguous_target_unresolved`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=2; ambiguities=1; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=unresolved; tier=medium; evidence=0; support_nodes=39; packs=0/0/0; pack_candidates=0; cap_hits=0
- `cold_warm_code_intel_start`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; cold=267ms warm=336ms cold_changed=15 warm_changed=0
- `pack_active_runtime_grounding`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=16; packs=2/6/0; pack_candidates=1; cap_hits=0
- `pack_large_runtime_grounding`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=8; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=27; packs=6/2/0; pack_candidates=4; cap_hits=0
- `pack_irrelevant_skipped_bounded`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=15; packs=0/8/0; pack_candidates=0; cap_hits=0
- `pack_large_low_tier_bounded`: pass; expected `supported_success` got `supported_success`; tier=low; pack_caps=4; local_truth=0; partials=0; ambiguities=0; suppressed_noise=3; reuse_hits=0; proof_blocks=0; status=supported; tier=low; evidence=1; support_nodes=24; packs=2/2/0; pack_candidates=2; cap_hits=4
- `pack_large_high_tier_bounded`: pass; expected `supported_success` got `supported_success`; tier=high; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=9; reuse_hits=0; proof_blocks=0; status=supported; tier=high; evidence=1; support_nodes=27; packs=6/2/0; pack_candidates=5; cap_hits=0
- `pack_large_max_tier_bounded`: pass; expected `supported_success` got `supported_success`; tier=max; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=10; reuse_hits=0; proof_blocks=0; status=supported; tier=max; evidence=1; support_nodes=27; packs=6/2/0; pack_candidates=5; cap_hits=0
- `pack_trust_conflict_visibility`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=1; partials=0; ambiguities=0; suppressed_noise=8; reuse_hits=0; proof_blocks=0; status=supported; tier=medium; evidence=1; support_nodes=27; packs=3/2/3; pack_candidates=4; cap_hits=0
- `tank_malformed_symbolic_partial`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=2; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=unresolved; tier=medium; evidence=0; support_nodes=23; packs=0/0/0; pack_candidates=0; cap_hits=0
- `tank_mixed_stacktrace_partial`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=2; ambiguities=0; suppressed_noise=2; reuse_hits=0; proof_blocks=0; status=unresolved; tier=medium; evidence=0; support_nodes=24; packs=0/0/0; pack_candidates=0; cap_hits=0
- `tank_noisy_anchor_suppression`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=2; ambiguities=1; suppressed_noise=4; reuse_hits=0; proof_blocks=0; status=unresolved; tier=medium; evidence=0; support_nodes=35; packs=0/0/0; pack_candidates=0; cap_hits=0
- `tank_reinforced_grounding_reuse`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=1; proof_blocks=0; status=supported; tier=medium; evidence=0; support_nodes=7; packs=0/0/0; pack_candidates=0; cap_hits=0
- `patch_verified_success`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=0/0; repairs=0/0
- `patch_minimal_refactor_selection`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=0/0; repairs=1/1
- `patch_retry_failure_handling`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=0/0; repairs=1/1
- `patch_refinement_retry`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=2/2; test=1/2; runtime=0/0; repairs=1/1
- `patch_dispatch_repair`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=0/0; repairs=1/1
- `patch_multifile_expanded_verified`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=2/2; test=1/2; runtime=0/0; repairs=0/0
- `patch_all_fail_unresolved`: pass; expected `failed_verification_or_runtime` got `failed_verification_or_runtime`; tier=medium; pack_caps=0; local_truth=0; partials=6; ambiguities=0; suppressed_noise=2; reuse_hits=0; proof_blocks=0; status=unresolved; verified=0; build=0/3; test=0/0; runtime=0/0; repairs=0/1
- `patch_abstraction_support`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=0/0; repairs=0/0
- `patch_runtime_oracle_verified`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=1/1; repairs=0/0
- `patch_runtime_oracle_failed`: pass; expected `failed_verification_or_runtime` got `failed_verification_or_runtime`; tier=medium; pack_caps=0; local_truth=0; partials=6; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=unresolved; verified=0; build=1/1; test=1/1; runtime=0/1; repairs=0/1
- `patch_runtime_oracle_worker_verified`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=1/1; repairs=0/0
- `patch_runtime_oracle_sequence_verified`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=1/1; repairs=0/0
- `patch_runtime_oracle_transition_verified`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; status=supported; verified=1; build=1/1; test=1/1; runtime=1/1; repairs=0/0
- `execution_zig_run_success`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; signal=none; exit=0
- `execution_blocked_shell_refusal`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; signal=disallowed_command; exit=none
- `execution_timeout_is_bounded`: pass; expected `failed_verification_or_runtime` got `failed_verification_or_runtime`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; signal=timed_out; exit=-15
- `operator_workflow_verified_complete`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=verified_complete; evidence_state=not_needed; build=1/1; test=1/1; runtime=0/0; replay_ready=false
- `operator_workflow_blocked`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=blocked; evidence_state=not_needed; build=0/0; test=0/0; runtime=0/0; replay_ready=false
- `operator_workflow_unresolved`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=unresolved; evidence_state=not_needed; build=0/0; test=0/0; runtime=0/0; replay_ready=false
- `operator_workflow_replay_from_task`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=blocked; evidence_state=not_needed; build=0/0; test=0/0; runtime=0/0; replay_ready=true
- `operator_workflow_external_evidence_assisted`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=verified_complete; evidence_state=ingested; build=0/0; test=0/0; runtime=0/0; replay_ready=false
- `operator_workflow_external_evidence_alias`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=verified_complete; evidence_state=ingested; build=0/0; test=0/0; runtime=0/0; replay_ready=false
- `operator_workflow_runtime_verified_patch`: pass; expected `supported_success` got `supported_success`; tier=medium; pack_caps=0; local_truth=0; partials=0; ambiguities=0; suppressed_noise=0; reuse_hits=0; proof_blocks=0; task_status=verified_complete; evidence_state=not_needed; build=1/1; test=1/1; runtime=1/1; replay_ready=false
- `tank_patch_partial_proof_gate`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=5; ambiguities=0; suppressed_noise=0; reuse_hits=2; proof_blocks=2; status=unresolved; verified=0; build=0/0; test=0/0; runtime=0/0; repairs=0/0
- `tank_patch_ambiguous_unresolved`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; tier=medium; pack_caps=0; local_truth=0; partials=3; ambiguities=1; suppressed_noise=0; reuse_hits=0; proof_blocks=1; status=unresolved; verified=0; build=0/0; test=0/0; runtime=0/0; repairs=0/0
