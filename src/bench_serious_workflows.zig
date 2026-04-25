const std = @import("std");
const builtin = @import("builtin");
const core = @import("ghost_core");
const abstractions = core.abstractions;
const artifact_schema = core.artifact_schema;
const code_intel = core.code_intel;
const compute_budget = core.compute_budget;
const config = core.config;
const execution = core.execution;
const external_evidence = core.external_evidence;
const feedback = core.feedback;
const hypothesis_core = core.hypothesis_core;
const intent_grounding = core.intent_grounding;
const knowledge_packs = core.knowledge_packs;
const mc = core.inference;
const operator_workflow = core.operator_workflow;
const panic_dump = core.panic_dump;
const patch_candidates = core.patch_candidates;
const response_engine = core.response_engine;
const shards = core.shards;
const sys = core.sys;
const task_sessions = core.task_sessions;
const verifier_adapter = core.verifier_adapter;
const repo_hygiene = core.repo_hygiene;

const Category = enum {
    code_impact_correctness,
    contradiction_detection_correctness,
    unresolved_vs_unsupported_behavior,
    patch_compile_pass_rate,
    test_pass_rate,
    minimal_safe_refactor_correctness,
    cold_vs_warm_project_start,
    latency_per_verified_result,
    execution_loop_success_failure_handling,
    provenance_support_completeness,
    operator_verified_complete_workflow,
    operator_blocked_workflow,
    operator_unresolved_workflow,
    operator_replay_workflow,
    external_evidence_assisted_workflow,
    runtime_verified_patch_workflow,
};

const ReinforcementScenario = enum {
    runtime_contract_grounding,
    ambiguous_patch_grounding,
};

const PackScenario = enum {
    runtime_small_activation_with_skips,
    runtime_large_mixed_relevant,
    runtime_large_irrelevant_only,
    runtime_large_trust_local_truth,
};

const OutcomeBucket = enum {
    supported_success,
    correct_unresolved_or_refused,
    failed_verification_or_runtime,
};

const CodeIntelCase = struct {
    fixture_rel: []const u8,
    project_shard: ?[]const u8 = null,
    query_kind: code_intel.QueryKind,
    target: []const u8,
    other_target: ?[]const u8 = null,
    max_items: usize = 8,
    persist: bool = false,
    cache_persist: bool = false,
    expect_status: code_intel.Status,
    expect_stop_reason: mc.StopReason,
    expect_contradiction_kind: ?[]const u8 = null,
    expect_primary_kind: ?[]const u8 = null,
    expect_evidence_rel_path: ?[]const u8 = null,
    require_support_completeness: bool = false,
    reinforcement_scenario: ?ReinforcementScenario = null,
    compare_after_reinforcement: bool = false,
    expect_partial_findings_min: usize = 0,
    expect_ambiguity_sets_min: usize = 0,
    expect_suppressed_noise_min: usize = 0,
    expect_reuse_hits_min: usize = 0,
    pack_scenario: ?PackScenario = null,
    compute_budget_request: compute_budget.Request = .{},
    pack_conflict_policy: abstractions.PackConflictPolicy = .{},
    compare_without_packs: bool = false,
    expect_pack_activated_min: usize = 0,
    expect_pack_activated_max: ?usize = null,
    expect_pack_skipped_min: usize = 0,
    expect_pack_trust_blocked_min: usize = 0,
    expect_pack_conflict_refused_min: usize = 0,
    expect_pack_candidate_surfaces_min: usize = 0,
    expect_pack_candidate_surfaces_max: ?usize = null,
    expect_pack_budget_caps_hit_min: usize = 0,
    expect_local_truth_wins_min: usize = 0,
    require_pack_traceability: bool = false,
    seed_abstraction_catalog_body: ?[]const u8 = null,
};

const ColdWarmCase = struct {
    fixture_rel: []const u8,
    project_shard: []const u8,
    query_kind: code_intel.QueryKind,
    target: []const u8,
    other_target: ?[]const u8 = null,
    max_items: usize = 8,
};

const PatchCase = struct {
    fixture_rel: []const u8,
    project_shard: ?[]const u8 = null,
    query_kind: code_intel.QueryKind = .breaks_if,
    target: []const u8,
    other_target: ?[]const u8 = null,
    request_label: ?[]const u8 = null,
    caps: patch_candidates.Caps = .{},
    shim_rel: ?[]const u8 = null,
    seed_abstraction_catalog: bool = false,
    expect_status: code_intel.Status,
    expect_stop_reason: mc.StopReason,
    expect_refactor_plan_status: patch_candidates.RefactorPlanStatus,
    require_selected_candidate: bool = false,
    require_support_completeness: bool = false,
    expect_any_repair_plan: bool = false,
    expect_any_repair_recovery: bool = false,
    expect_any_repair_failed: bool = false,
    expect_any_refinement: bool = false,
    expect_candidate0_test_failed: bool = false,
    expect_any_retry: bool = false,
    expect_any_build_failed: bool = false,
    expect_any_runtime_failed: bool = false,
    expect_any_runtime_passed: bool = false,
    expect_selected_runtime_verified: bool = false,
    expect_abstraction_refs_min: usize = 0,
    expect_selected_scope_smaller_than_expanded: bool = false,
    reinforcement_scenario: ?ReinforcementScenario = null,
    use_tank_benchmark: bool = false,
    expect_partial_findings_min: usize = 0,
    expect_ambiguity_sets_min: usize = 0,
    expect_suppressed_noise_min: usize = 0,
    expect_reuse_hits_min: usize = 0,
    expect_proof_admission_blocks_min: u32 = 0,
    expect_candidate_count_min: usize = 0,
    expect_preserved_novel_min: u32 = 0,
};

const ExecutionCase = struct {
    fixture_rel: []const u8,
    step: execution.Step,
    expect_signal: execution.FailureSignal,
    expect_success: bool = false,
};

const TaskWorkflowCase = struct {
    fixture_rel: []const u8,
    project_shard: []const u8,
    intent_text: []const u8,
    max_steps: u32,
    emit_panic_dump: bool = false,
    evidence_fixture_rel: ?[]const u8 = null,
    evidence_files: []const []const u8 = &.{},
    seed_worker_sync_abstractions: bool = false,
    expect_status: task_sessions.Status,
    expect_evidence_state: ?external_evidence.AcquisitionState = null,
    expect_patch_result: bool = false,
    expect_code_intel_result: bool = false,
    expect_external_evidence_result: bool = false,
    expect_panic_dump: bool = false,
    expect_support_completeness: bool = false,
    expect_runtime_verified_patch: bool = false,
    expect_replay_from_task: bool = false,
    expect_status_detail_substring: ?[]const u8 = null,
};

const CaseSpec = struct {
    id: []const u8,
    title: []const u8,
    metric_tags: []const Category,
    expected_bucket: OutcomeBucket,
    runner: union(enum) {
        code_intel: CodeIntelCase,
        cold_warm: ColdWarmCase,
        patch: PatchCase,
        execution: ExecutionCase,
        task_workflow: TaskWorkflowCase,
    },
};

const CaseResult = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    metric_tags: []const Category,
    expected_bucket: OutcomeBucket,
    actual_bucket: OutcomeBucket,
    passed: bool,
    duration_ms: u64,
    detail: []u8,
    ghost_status: ?[]u8 = null,
    stop_reason: ?[]u8 = null,
    cache_lifecycle: ?[]u8 = null,
    contradiction_kind: ?[]u8 = null,
    selected_refactor_scope: ?[]u8 = null,
    selected_verification_state: ?[]u8 = null,
    unresolved_detail: ?[]u8 = null,
    support_complete: bool = false,
    support_graph_minimum_met: bool = false,
    support_node_count: usize = 0,
    support_edge_count: usize = 0,
    evidence_count: usize = 0,
    abstraction_ref_count: usize = 0,
    verified_supported_count: u32 = 0,
    build_attempted: u32 = 0,
    build_passed: u32 = 0,
    test_attempted: u32 = 0,
    test_passed: u32 = 0,
    runtime_attempted: u32 = 0,
    runtime_passed: u32 = 0,
    repair_plan_count: u32 = 0,
    repair_recovered_count: u32 = 0,
    repair_failed_count: u32 = 0,
    retrying_candidate_count: u32 = 0,
    refinement_count: u32 = 0,
    cold_duration_ms: u64 = 0,
    warm_duration_ms: u64 = 0,
    cold_cache_changed_files: u32 = 0,
    warm_cache_changed_files: u32 = 0,
    support_relevant: bool = false,
    task_status: ?[]u8 = null,
    evidence_state: ?[]u8 = null,
    replay_ready: bool = false,
    replay_class: ?[]u8 = null,
    replay_source: ?[]u8 = null,
    partial_finding_count: u32 = 0,
    ambiguity_set_count: u32 = 0,
    suppressed_noise_count: u32 = 0,
    reinforcement_reuse_hit_count: u32 = 0,
    reinforcement_event_count: u32 = 0,
    proof_admission_blocked_count: u32 = 0,
    preserved_novel_count: u32 = 0,
    candidate_count: u32 = 0,
    repo_scan_ms: u64 = 0,
    cache_refresh_ms: u64 = 0,
    index_materialize_ms: u64 = 0,
    routing_index_build_ms: u64 = 0,
    routing_considered_count: u32 = 0,
    routing_selected_count: u32 = 0,
    routing_skipped_count: u32 = 0,
    routing_suppressed_count: u32 = 0,
    routing_budget_cap_hit_count: u32 = 0,
    retained_token_signal_count: u32 = 0,
    retained_pattern_signal_count: u32 = 0,
    schema_entity_signal_count: u32 = 0,
    schema_relation_signal_count: u32 = 0,
    obligation_signal_count: u32 = 0,
    anchor_signal_count: u32 = 0,
    verifier_hint_signal_count: u32 = 0,
    fallback_signal_used_count: u32 = 0,
    generated_hypothesis_count: u32 = 0,
    selected_hypothesis_count: u32 = 0,
    suppressed_hypothesis_count: u32 = 0,
    hypothesis_triage_selected_count: u32 = 0,
    hypothesis_triage_suppressed_count: u32 = 0,
    hypothesis_duplicate_count: u32 = 0,
    hypothesis_budget_hit_count: u32 = 0,
    selected_code_hypothesis_count: u32 = 0,
    selected_non_code_hypothesis_count: u32 = 0,
    top_selected_hypothesis_kinds: [@typeInfo(hypothesis_core.HypothesisKind).@"enum".fields.len]u32 = [_]u32{0} ** @typeInfo(hypothesis_core.HypothesisKind).@"enum".fields.len,
    hypothesis_generation_budget_hit_count: u32 = 0,
    hypothesis_generation_rules_fired: u32 = 0,
    non_code_hypothesis_count: u32 = 0,
    code_hypothesis_count: u32 = 0,
    hypothesis_verifier_eligible_count: u32 = 0,
    hypothesis_verifier_scheduled_count: u32 = 0,
    hypothesis_verifier_completed_count: u32 = 0,
    hypothesis_verifier_blocked_count: u32 = 0,
    hypothesis_verifier_skipped_count: u32 = 0,
    hypothesis_verifier_budget_exhausted_count: u32 = 0,
    code_hypothesis_verifier_job_count: u32 = 0,
    non_code_hypothesis_verifier_job_count: u32 = 0,
    verifier_candidate_proposed_count: u32 = 0,
    verifier_candidate_blocked_count: u32 = 0,
    verifier_candidate_accepted_count: u32 = 0,
    verifier_candidate_materialized_count: u32 = 0,
    verifier_candidate_rejected_count: u32 = 0,
    verifier_candidate_materialization_blocked_count: u32 = 0,
    verifier_candidate_budget_hit_count: u32 = 0,
    code_verifier_candidate_count: u32 = 0,
    non_code_verifier_candidate_count: u32 = 0,
    pack_mount_resolve_ms: u64 = 0,
    pack_manifest_preview_load_ms: u64 = 0,
    pack_routing_ms: u64 = 0,
    pack_catalog_load_ms: u64 = 0,
    pack_candidate_surface_count: u32 = 0,
    pack_peak_candidate_surface_count: u32 = 0,
    pack_activated_count: u32 = 0,
    pack_peak_activated_count: u32 = 0,
    pack_skipped_count: u32 = 0,
    pack_peak_skipped_count: u32 = 0,
    pack_suppressed_count: u32 = 0,
    pack_peak_suppressed_count: u32 = 0,
    pack_conflict_refused_count: u32 = 0,
    pack_trust_blocked_count: u32 = 0,
    pack_stale_blocked_count: u32 = 0,
    pack_budget_caps_hit_count: u32 = 0,
    pack_local_truth_win_count: u32 = 0,
    requested_compute_tier: []const u8 = "auto",
    effective_compute_tier: []const u8 = "medium",
    budget_exhausted: bool = false,
    budget_limit: ?[]u8 = null,
    budget_stage: ?[]u8 = null,
    support_graph_build_ms: u64 = 0,
    response_mode_selection_ms: u64 = 0,
    response_draft_mode_count: u32 = 0,
    response_fast_path_count: u32 = 0,
    response_deep_path_count: u32 = 0,
    response_draft_path_ms: u64 = 0,
    response_fast_path_ms: u64 = 0,
    response_deep_path_ms: u64 = 0,
    artifact_schema_pipeline_ms: u64 = 0,
    verifier_adapter_dispatch_ms: u64 = 0,
    artifact_json_render_ms: u64 = 0,
    artifact_persist_ms: u64 = 0,
    panic_dump_capture_ms: u64 = 0,
    verification_workspace_ms: u64 = 0,
    verification_build_exec_ms: u64 = 0,
    verification_test_exec_ms: u64 = 0,
    verification_runtime_exec_ms: u64 = 0,
    verifier_adapter_run_count: u32 = 0,
    verifier_adapter_passed_count: u32 = 0,
    verifier_adapter_failed_count: u32 = 0,
    verifier_adapter_blocked_count: u32 = 0,
    verifier_adapter_skipped_count: u32 = 0,
    verifier_budget_exhaustion_count: u32 = 0,
    code_verifier_count: u32 = 0,
    non_code_verifier_count: u32 = 0,
    task_artifact_write_ms: u64 = 0,
    task_artifact_write_count: u32 = 0,
    task_session_save_ms: u64 = 0,
    task_session_save_count: u32 = 0,

    fn deinit(self: *CaseResult) void {
        self.allocator.free(self.detail);
        freeOptional(self.allocator, self.ghost_status);
        freeOptional(self.allocator, self.stop_reason);
        freeOptional(self.allocator, self.cache_lifecycle);
        freeOptional(self.allocator, self.contradiction_kind);
        freeOptional(self.allocator, self.selected_refactor_scope);
        freeOptional(self.allocator, self.selected_verification_state);
        freeOptional(self.allocator, self.unresolved_detail);
        freeOptional(self.allocator, self.task_status);
        freeOptional(self.allocator, self.evidence_state);
        freeOptional(self.allocator, self.replay_class);
        freeOptional(self.allocator, self.replay_source);
        freeOptional(self.allocator, self.budget_limit);
        freeOptional(self.allocator, self.budget_stage);
        self.* = undefined;
    }
};

const Metrics = struct {
    total_cases: u32 = 0,
    passed_cases: u32 = 0,
    failed_cases: u32 = 0,
    bucket_expected_supported_success: u32 = 0,
    bucket_expected_correct_unresolved_or_refused: u32 = 0,
    bucket_expected_failed_verification_or_runtime: u32 = 0,
    bucket_actual_supported_success: u32 = 0,
    bucket_actual_correct_unresolved_or_refused: u32 = 0,
    bucket_actual_failed_verification_or_runtime: u32 = 0,
    category_totals: [@typeInfo(Category).@"enum".fields.len]u32 = [_]u32{0} ** @typeInfo(Category).@"enum".fields.len,
    category_passed: [@typeInfo(Category).@"enum".fields.len]u32 = [_]u32{0} ** @typeInfo(Category).@"enum".fields.len,
    patch_build_attempted: u32 = 0,
    patch_build_passed: u32 = 0,
    patch_test_attempted: u32 = 0,
    patch_test_passed: u32 = 0,
    patch_runtime_attempted: u32 = 0,
    patch_runtime_passed: u32 = 0,
    verified_result_count: u32 = 0,
    total_verified_latency_ms: u64 = 0,
    support_relevant_cases: u32 = 0,
    support_complete_cases: u32 = 0,
    cold_start_ms: u64 = 0,
    warm_start_ms: u64 = 0,
    cold_cache_changed_files: u32 = 0,
    warm_cache_changed_files: u32 = 0,
    workflow_cases: u32 = 0,
    workflow_passed_cases: u32 = 0,
    task_state_planned: u32 = 0,
    task_state_running: u32 = 0,
    task_state_blocked: u32 = 0,
    task_state_unresolved: u32 = 0,
    task_state_verified_complete: u32 = 0,
    task_state_failed: u32 = 0,
    replay_cases: u32 = 0,
    replay_ready_cases: u32 = 0,
    external_evidence_cases: u32 = 0,
    evidence_state_not_needed: u32 = 0,
    evidence_state_requested: u32 = 0,
    evidence_state_fetched: u32 = 0,
    evidence_state_ingested: u32 = 0,
    evidence_state_conflicting: u32 = 0,
    evidence_state_insufficient: u32 = 0,
    partial_finding_cases: u32 = 0,
    partial_finding_preserved_cases: u32 = 0,
    ambiguity_cases: u32 = 0,
    ambiguity_preserved_cases: u32 = 0,
    suppressed_noise_count: u32 = 0,
    reinforcement_reuse_hit_count: u32 = 0,
    reinforcement_event_count: u32 = 0,
    unsupported_proof_admission_block_count: u32 = 0,
    total_benchmark_wall_time_ms: u64 = 0,
    repo_scan_ms: u64 = 0,
    cache_refresh_ms: u64 = 0,
    index_materialize_ms: u64 = 0,
    routing_index_build_ms: u64 = 0,
    routing_considered_count: u32 = 0,
    routing_selected_count: u32 = 0,
    routing_skipped_count: u32 = 0,
    routing_suppressed_count: u32 = 0,
    routing_budget_cap_hit_count: u32 = 0,
    retained_token_signal_count: u32 = 0,
    retained_pattern_signal_count: u32 = 0,
    schema_entity_signal_count: u32 = 0,
    schema_relation_signal_count: u32 = 0,
    obligation_signal_count: u32 = 0,
    anchor_signal_count: u32 = 0,
    verifier_hint_signal_count: u32 = 0,
    fallback_signal_used_count: u32 = 0,
    generated_hypothesis_count: u32 = 0,
    selected_hypothesis_count: u32 = 0,
    suppressed_hypothesis_count: u32 = 0,
    hypothesis_triage_selected_count: u32 = 0,
    hypothesis_triage_suppressed_count: u32 = 0,
    hypothesis_duplicate_count: u32 = 0,
    hypothesis_budget_hit_count: u32 = 0,
    selected_code_hypothesis_count: u32 = 0,
    selected_non_code_hypothesis_count: u32 = 0,
    top_selected_hypothesis_kinds: [@typeInfo(hypothesis_core.HypothesisKind).@"enum".fields.len]u32 = [_]u32{0} ** @typeInfo(hypothesis_core.HypothesisKind).@"enum".fields.len,
    hypothesis_generation_budget_hit_count: u32 = 0,
    hypothesis_generation_rules_fired: u32 = 0,
    non_code_hypothesis_count: u32 = 0,
    code_hypothesis_count: u32 = 0,
    hypothesis_verifier_eligible_count: u32 = 0,
    hypothesis_verifier_scheduled_count: u32 = 0,
    hypothesis_verifier_completed_count: u32 = 0,
    hypothesis_verifier_blocked_count: u32 = 0,
    hypothesis_verifier_skipped_count: u32 = 0,
    hypothesis_verifier_budget_exhausted_count: u32 = 0,
    code_hypothesis_verifier_job_count: u32 = 0,
    non_code_hypothesis_verifier_job_count: u32 = 0,
    verifier_candidate_proposed_count: u32 = 0,
    verifier_candidate_blocked_count: u32 = 0,
    verifier_candidate_accepted_count: u32 = 0,
    verifier_candidate_materialized_count: u32 = 0,
    verifier_candidate_rejected_count: u32 = 0,
    verifier_candidate_materialization_blocked_count: u32 = 0,
    verifier_candidate_budget_hit_count: u32 = 0,
    code_verifier_candidate_count: u32 = 0,
    non_code_verifier_candidate_count: u32 = 0,
    pack_mount_resolve_ms: u64 = 0,
    pack_manifest_preview_load_ms: u64 = 0,
    pack_routing_ms: u64 = 0,
    pack_catalog_load_ms: u64 = 0,
    pack_candidate_surface_count: u32 = 0,
    pack_peak_candidate_surface_count: u32 = 0,
    pack_activated_count: u32 = 0,
    pack_peak_activated_count: u32 = 0,
    pack_skipped_count: u32 = 0,
    pack_peak_skipped_count: u32 = 0,
    pack_budget_caps_hit_count: u32 = 0,
    pack_local_truth_win_count: u32 = 0,
    support_graph_build_ms: u64 = 0,
    response_mode_selection_ms: u64 = 0,
    response_draft_mode_count: u32 = 0,
    response_fast_path_count: u32 = 0,
    response_deep_path_count: u32 = 0,
    response_draft_path_ms: u64 = 0,
    response_fast_path_ms: u64 = 0,
    response_deep_path_ms: u64 = 0,
    artifact_schema_pipeline_ms: u64 = 0,
    verifier_adapter_dispatch_ms: u64 = 0,
    artifact_json_render_ms: u64 = 0,
    artifact_persist_ms: u64 = 0,
    panic_dump_capture_ms: u64 = 0,
    verification_workspace_ms: u64 = 0,
    verification_build_exec_ms: u64 = 0,
    verification_test_exec_ms: u64 = 0,
    verification_runtime_exec_ms: u64 = 0,
    verifier_adapter_run_count: u32 = 0,
    verifier_adapter_passed_count: u32 = 0,
    verifier_adapter_failed_count: u32 = 0,
    verifier_adapter_blocked_count: u32 = 0,
    verifier_adapter_skipped_count: u32 = 0,
    verifier_budget_exhaustion_count: u32 = 0,
    code_verifier_count: u32 = 0,
    non_code_verifier_count: u32 = 0,
    task_artifact_write_ms: u64 = 0,
    task_artifact_write_count: u32 = 0,
    task_session_save_ms: u64 = 0,
    task_session_save_count: u32 = 0,
};

const ABSTRACTION_CATALOG =
    \\GABS1
    \\concept compute_guard
    \\examples 2
    \\threshold 2
    \\retained_tokens 2
    \\retained_patterns 2
    \\average_resonance 700
    \\min_resonance 700
    \\consensus_hash 42
    \\valid 1
    \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\source region:src/api/service.zig:1-10
    \\pattern compute
    \\pattern hydrate
    \\end
;

const WORKER_SYNC_ABSTRACTION_CATALOG =
    \\GABS1
    \\concept runtime_worker_sync
    \\tier mechanism
    \\category data_flow
    \\examples 3
    \\threshold 2
    \\retained_tokens 2
    \\retained_patterns 1
    \\average_resonance 760
    \\min_resonance 740
    \\quality_score 880
    \\confidence_score 860
    \\reuse_score 200
    \\support_score 300
    \\promotion_ready 1
    \\consensus_hash 401
    \\valid 1
    \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\source region:src/runtime/worker.zig:1-4
    \\token worker
    \\token sync
    \\pattern worker_sync
    \\end
    \\concept ui_worker_sync
    \\tier mechanism
    \\category data_flow
    \\examples 3
    \\threshold 2
    \\retained_tokens 2
    \\retained_patterns 1
    \\average_resonance 760
    \\min_resonance 740
    \\quality_score 880
    \\confidence_score 860
    \\reuse_score 200
    \\support_score 300
    \\promotion_ready 1
    \\consensus_hash 402
    \\valid 1
    \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\source region:src/ui/render.zig:1-4
    \\token worker
    \\token sync
    \\pattern worker_sync
    \\end
;

const PackFixtureKind = enum {
    runtime_core,
    runtime_config,
    runtime_logs,
    ui_noise,
};

const PackFixtureSpec = struct {
    root_rel: []const u8,
    corpus_files: []const []const u8,
};

fn packFixtureSpec(kind: PackFixtureKind) PackFixtureSpec {
    return switch (kind) {
        .runtime_core => .{
            .root_rel = "benchmarks/ghost_serious_workflows/fixtures/pack_scaling/runtime_core",
            .corpus_files = &.{
                "configs/runtime.toml",
                "docs/runtime_contracts.md",
                "docs/worker_recovery.md",
                "logs/sync_trace.log",
                "notes/noise.md",
            },
        },
        .runtime_config => .{
            .root_rel = "benchmarks/ghost_serious_workflows/fixtures/pack_scaling/runtime_config",
            .corpus_files = &.{
                "configs/runtime_budget.toml",
                "configs/worker_sync.toml",
                "docs/budget_guards.md",
                "logs/config_reload.log",
                "notes/ops.md",
            },
        },
        .runtime_logs => .{
            .root_rel = "benchmarks/ghost_serious_workflows/fixtures/pack_scaling/runtime_logs",
            .corpus_files = &.{
                "configs/retry_budget.toml",
                "docs/incident.md",
                "logs/replay_window.log",
                "logs/worker_sync.log",
                "notes/sidebar.md",
            },
        },
        .ui_noise => .{
            .root_rel = "benchmarks/ghost_serious_workflows/fixtures/pack_scaling/ui_noise",
            .corpus_files = &.{
                "configs/ui.toml",
                "docs/render_guide.md",
                "docs/theme_notes.md",
                "logs/render_loop.log",
                "notes/noise.md",
            },
        },
    };
}

const CASES = [_]CaseSpec{
    .{
        .id = "impact_widget_to_service",
        .title = "Code impact correctness follows type relationships",
        .metric_tags = &.{ .code_impact_correctness, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .query_kind = .impact,
            .target = "src/model/types.zig:Widget",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_primary_kind = "type",
            .expect_evidence_rel_path = "src/api/service.zig",
            .require_support_completeness = true,
        } },
    },
    .{
        .id = "contradiction_call_site",
        .title = "Contradiction detection catches call-site incompatibility",
        .metric_tags = &.{.contradiction_detection_correctness},
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .query_kind = .contradicts,
            .target = "src/api/service.zig:compute",
            .other_target = "src/ui/render.zig:draw",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_contradiction_kind = "incompatible_call_site_expectation",
        } },
    },
    .{
        .id = "contradiction_signature",
        .title = "Contradiction detection catches signature incompatibility",
        .metric_tags = &.{.contradiction_detection_correctness},
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .query_kind = .contradicts,
            .target = "src/api/service.zig:compute",
            .other_target = "src/model/types.zig:Widget",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_contradiction_kind = "signature_incompatibility",
        } },
    },
    .{
        .id = "contradiction_ownership",
        .title = "Contradiction detection catches ownership-state assumptions",
        .metric_tags = &.{.contradiction_detection_correctness},
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .query_kind = .contradicts,
            .target = "src/runtime/state.zig:counter",
            .other_target = "src/runtime/state.zig:tick",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_contradiction_kind = "ownership_state_assumption",
        } },
    },
    .{
        .id = "ambiguous_target_unresolved",
        .title = "Ambiguous target stays unresolved instead of guessed",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .query_kind = .impact,
            .target = "run",
            .expect_status = .unresolved,
            .expect_stop_reason = .contradiction,
        } },
    },
    .{
        .id = "cold_warm_code_intel_start",
        .title = "Cold vs warm project start stays measurable and shard-local",
        .metric_tags = &.{.cold_vs_warm_project_start},
        .expected_bucket = .supported_success,
        .runner = .{ .cold_warm = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-cold-warm-base-service",
            .query_kind = .impact,
            .target = "src/api/service.zig:compute",
        } },
    },
    .{
        .id = "pack_active_runtime_grounding",
        .title = "Small mounted runtime pack activates and establishes the pack-overhead baseline",
        .metric_tags = &.{ .code_impact_correctness, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-active-runtime-grounding",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .require_support_completeness = true,
            .pack_scenario = .runtime_small_activation_with_skips,
            .compare_without_packs = true,
            .expect_pack_activated_min = 1,
            .expect_pack_skipped_min = 2,
            .expect_pack_candidate_surfaces_min = 1,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "pack_large_runtime_grounding",
        .title = "Large valid mounted packs improve a relevant query while keeping routing and catalog costs explicit",
        .metric_tags = &.{ .code_impact_correctness, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-large-runtime-grounding",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .require_support_completeness = true,
            .pack_scenario = .runtime_large_mixed_relevant,
            .compare_without_packs = true,
            .expect_pack_activated_min = 2,
            .expect_pack_skipped_min = 1,
            .expect_pack_candidate_surfaces_min = 4,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "pack_irrelevant_skipped_bounded",
        .title = "Irrelevant larger mounted packs stay skipped with bounded, traceable overhead",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-irrelevant-skipped",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .pack_scenario = .runtime_large_irrelevant_only,
            .expect_pack_skipped_min = 4,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "pack_large_low_tier_bounded",
        .title = "Low compute tier activates fewer large packs and reports cap pressure explicitly",
        .metric_tags = &.{ .code_impact_correctness, .unresolved_vs_unsupported_behavior },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-large-low-tier",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .pack_scenario = .runtime_large_mixed_relevant,
            .compute_budget_request = .{ .tier = .low },
            .expect_pack_activated_min = 1,
            .expect_pack_activated_max = 1,
            .expect_pack_skipped_min = 1,
            .expect_pack_candidate_surfaces_min = 2,
            .expect_pack_candidate_surfaces_max = 2,
            .expect_pack_budget_caps_hit_min = 2,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "pack_large_high_tier_bounded",
        .title = "High compute tier explores more mounted-pack surfaces while staying bounded",
        .metric_tags = &.{ .code_impact_correctness, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-large-high-tier",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .require_support_completeness = true,
            .pack_scenario = .runtime_large_mixed_relevant,
            .compute_budget_request = .{ .tier = .high },
            .expect_pack_activated_min = 3,
            .expect_pack_candidate_surfaces_min = 5,
            .expect_pack_candidate_surfaces_max = 5,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "pack_large_max_tier_bounded",
        .title = "Max compute tier preserves deepest bounded pack caps without inventing extra surfaces",
        .metric_tags = &.{ .code_impact_correctness, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-large-max-tier",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .require_support_completeness = true,
            .pack_scenario = .runtime_large_mixed_relevant,
            .compute_budget_request = .{ .tier = .max },
            .expect_pack_activated_min = 3,
            .expect_pack_candidate_surfaces_min = 5,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "pack_trust_conflict_visibility",
        .title = "Pack trust conflicts stay explicit under load and local project truth still wins",
        .metric_tags = &.{ .contradiction_detection_correctness, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-pack-trust-conflict",
            .query_kind = .impact,
            .target = "src/runtime/worker.zig:sync",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .pack_scenario = .runtime_large_trust_local_truth,
            .seed_abstraction_catalog_body = WORKER_SYNC_ABSTRACTION_CATALOG,
            .pack_conflict_policy = .{ .competition = .prefer_higher_trust_only },
            .expect_pack_activated_min = 1,
            .expect_pack_trust_blocked_min = 1,
            .expect_pack_conflict_refused_min = 1,
            .expect_local_truth_wins_min = 1,
            .expect_pack_candidate_surfaces_min = 1,
            .require_support_completeness = true,
            .require_pack_traceability = true,
        } },
    },
    .{
        .id = "tank_malformed_symbolic_partial",
        .title = "Weak-structure config ingestion preserves useful partial findings without authorizing output",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/tank_malformed_symbolic",
            .query_kind = .impact,
            .target = "worker_mode",
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_partial_findings_min = 2,
        } },
    },
    .{
        .id = "tank_mixed_stacktrace_partial",
        .title = "Mixed docs and stack-trace input stays unresolved while preserving bounded partial anchors",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/tank_mixed_stacktrace",
            .query_kind = .impact,
            .target = "sync",
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_partial_findings_min = 2,
        } },
    },
    .{
        .id = "tank_noisy_anchor_suppression",
        .title = "Noisy symbolic material is suppressed while one anchored surface survives bounded analysis",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/tank_noisy_anchor",
            .query_kind = .impact,
            .target = "alpha",
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_partial_findings_min = 2,
            .expect_suppressed_noise_min = 1,
        } },
    },
    .{
        .id = "tank_reinforced_grounding_reuse",
        .title = "Reinforced weak-structure grounding patterns improve later runs deterministically",
        .metric_tags = &.{ .unresolved_vs_unsupported_behavior, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .code_intel = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/tank_patch_weak",
            .project_shard = "bench-tank-reinforced-grounding",
            .query_kind = .impact,
            .target = "docs/runbook.md:heading:runtime_contracts@1",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .reinforcement_scenario = .runtime_contract_grounding,
            .compare_after_reinforcement = true,
            .expect_reuse_hits_min = 1,
        } },
    },
    .{
        .id = "patch_verified_success",
        .title = "Patch candidates verify against real build and test workflows",
        .metric_tags = &.{ .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .request_label = "bench compute guard",
            .caps = .{
                .max_candidates = 2,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
        } },
    },
    .{
        .id = "patch_minimal_refactor_selection",
        .title = "Minimal safe refactor beats broader verified scope",
        .metric_tags = &.{ .minimal_safe_refactor_correctness, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .caps = .{
                .max_candidates = 4,
                .max_files = 4,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/scripted_verification/bin",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .expect_selected_scope_smaller_than_expanded = true,
        } },
    },
    .{
        .id = "patch_retry_failure_handling",
        .title = "Verification loop preserves failure lineage and can recover a bounded candidate without bypassing proof selection",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .caps = .{
                .max_candidates = 2,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/scripted_verification/bin",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .expect_any_retry = true,
            .expect_any_repair_recovery = true,
        } },
    },
    .{
        .id = "patch_refinement_retry",
        .title = "Explicit repair planning recovers a failing candidate via a bounded descendant",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .caps = .{
                .max_candidates = 3,
                .max_files = 3,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/repair_success/bin",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .expect_any_repair_plan = true,
            .expect_any_repair_recovery = true,
            .expect_any_refinement = true,
        } },
    },
    .{
        .id = "patch_dispatch_repair",
        .title = "Dispatch-boundary repair normalizes a wrapper descendant without hiding the original failure",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .caps = .{
                .max_candidates = 4,
                .max_files = 4,
                .max_hunks_per_candidate = 3,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/dispatch_repair/bin",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .expect_any_repair_plan = true,
            .expect_any_repair_recovery = true,
            .expect_any_retry = true,
        } },
    },
    .{
        .id = "patch_multifile_expanded_verified",
        .title = "Expanded synthesis can adapt multiple bounded dependent surfaces when proof-backed support is sufficient",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .caps = .{
                .max_candidates = 4,
                .max_files = 4,
                .max_hunks_per_candidate = 3,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/multifile_expanded/bin",
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
        } },
    },
    .{
        .id = "patch_all_fail_unresolved",
        .title = "Verification failure paths stay separated from supported success",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate },
        .expected_bucket = .failed_verification_or_runtime,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .target = "src/api/service.zig:compute",
            .caps = .{
                .max_candidates = 3,
                .max_files = 3,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/always_fail/bin",
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_refactor_plan_status = .unresolved,
            .expect_any_build_failed = true,
            .expect_any_repair_plan = true,
            .expect_any_repair_failed = true,
        } },
    },
    .{
        .id = "patch_abstraction_support",
        .title = "Support and provenance completeness includes abstraction references",
        .metric_tags = &.{ .provenance_support_completeness, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-abstraction-support",
            .target = "src/api/service.zig:compute",
            .seed_abstraction_catalog = true,
            .caps = .{
                .max_candidates = 2,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
            .expect_abstraction_refs_min = 1,
        } },
    },
    .{
        .id = "patch_runtime_oracle_verified",
        .title = "Patch candidates become runtime-verified when a bounded oracle confirms runtime evidence",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/runtime_oracle_positive",
            .target = "src/api/service.zig:compute",
            .request_label = "bench runtime oracle positive",
            .caps = .{
                .max_candidates = 1,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
            .expect_any_runtime_passed = true,
            .expect_selected_runtime_verified = true,
        } },
    },
    .{
        .id = "patch_runtime_oracle_failed",
        .title = "Runtime oracle rejects bad runtime behavior cleanly after build and test pass",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate },
        .expected_bucket = .failed_verification_or_runtime,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/runtime_oracle_negative",
            .target = "src/api/service.zig:compute",
            .request_label = "bench runtime oracle negative",
            .caps = .{
                .max_candidates = 1,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_refactor_plan_status = .unresolved,
            .expect_any_runtime_failed = true,
        } },
    },
    .{
        .id = "patch_runtime_oracle_worker_verified",
        .title = "A second positive runtime oracle path verifies a different real patch target",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/runtime_oracle_worker_positive",
            .target = "src/runtime/worker.zig:sync",
            .request_label = "bench runtime oracle worker positive",
            .caps = .{
                .max_candidates = 1,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
            .expect_any_runtime_passed = true,
            .expect_selected_runtime_verified = true,
        } },
    },
    .{
        .id = "patch_runtime_oracle_sequence_verified",
        .title = "Runtime oracles can verify ordered event sequences and multiple state assertions in one bounded run",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/runtime_oracle_sequence_positive",
            .target = "src/api/service.zig:compute",
            .request_label = "bench runtime oracle sequence positive",
            .caps = .{
                .max_candidates = 1,
                .max_files = 3,
                .max_hunks_per_candidate = 3,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
            .expect_any_runtime_passed = true,
            .expect_selected_runtime_verified = true,
        } },
    },
    .{
        .id = "patch_runtime_oracle_transition_verified",
        .title = "Runtime oracles can verify bounded state transitions across repeated actions in one run",
        .metric_tags = &.{ .execution_loop_success_failure_handling, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/runtime_oracle_transition_positive",
            .target = "src/runtime/worker.zig:sync",
            .request_label = "bench runtime oracle transition positive",
            .caps = .{
                .max_candidates = 1,
                .max_files = 3,
                .max_hunks_per_candidate = 3,
                .max_lines_per_hunk = 6,
            },
            .expect_status = .supported,
            .expect_stop_reason = .none,
            .expect_refactor_plan_status = .verified_supported,
            .require_selected_candidate = true,
            .require_support_completeness = true,
            .expect_any_runtime_passed = true,
            .expect_selected_runtime_verified = true,
        } },
    },
    .{
        .id = "execution_zig_run_success",
        .title = "Execution harness succeeds on bounded zig run",
        .metric_tags = &.{.execution_loop_success_failure_handling},
        .expected_bucket = .supported_success,
        .runner = .{ .execution = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .step = .{
                .label = "zig_run_main",
                .kind = .zig_run,
                .phase = .run,
                .argv = &.{ "zig", "run", "src/main.zig" },
                .expectations = &.{.{ .success = {} }},
                .timeout_ms = 8_000,
            },
            .expect_signal = .none,
            .expect_success = true,
        } },
    },
    .{
        .id = "execution_blocked_shell_refusal",
        .title = "Execution harness refuses unrestricted shell commands",
        .metric_tags = &.{.execution_loop_success_failure_handling},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .execution = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .step = .{
                .label = "blocked_shell",
                .kind = .shell,
                .phase = .invariant,
                .argv = &.{ "bash", "-c", "echo hi" },
                .timeout_ms = 500,
            },
            .expect_signal = .disallowed_command,
        } },
    },
    .{
        .id = "execution_timeout_is_bounded",
        .title = "Execution harness times out bounded workspace scripts",
        .metric_tags = &.{.execution_loop_success_failure_handling},
        .expected_bucket = .failed_verification_or_runtime,
        .runner = .{ .execution = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/execution_timeout",
            .step = .{
                .label = "hang_script",
                .kind = .shell,
                .phase = .invariant,
                .argv = &.{"./scripts/hang.sh"},
                .timeout_ms = 100,
            },
            .expect_signal = .timed_out,
        } },
    },
    .{
        .id = "operator_workflow_verified_complete",
        .title = "Integrated task operator reaches verified completion on the patch workflow",
        .metric_tags = &.{ .operator_verified_complete_workflow, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-operator-verified-workflow",
            .intent_text = "refactor src/api/service.zig:compute but keep the API stable",
            .max_steps = 3,
            .expect_status = .verified_complete,
            .expect_patch_result = true,
            .expect_support_completeness = true,
        } },
    },
    .{
        .id = "operator_workflow_blocked",
        .title = "Integrated task operator stops blocked when no Linux-native build workflow exists",
        .metric_tags = &.{.operator_blocked_workflow},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/operator_blocked_simple",
            .project_shard = "bench-operator-blocked-workflow",
            .intent_text = "refactor src/solo.zig:compute",
            .max_steps = 3,
            .emit_panic_dump = true,
            .expect_status = .blocked,
            .expect_patch_result = true,
            .expect_panic_dump = true,
            .expect_status_detail_substring = "no Linux-native build workflow was detected",
        } },
    },
    .{
        .id = "operator_workflow_unresolved",
        .title = "Integrated task operator preserves unresolved support stops for ambiguous grounding",
        .metric_tags = &.{.operator_unresolved_workflow},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-operator-unresolved-workflow",
            .intent_text = "explain notes/ops.md:paragraph:worker_sync@2",
            .max_steps = 2,
            .seed_worker_sync_abstractions = true,
            .expect_status = .unresolved,
            .expect_code_intel_result = true,
            .expect_status_detail_substring = "equally supported mappings",
        } },
    },
    .{
        .id = "operator_workflow_replay_from_task",
        .title = "Replay works directly from a blocked task without manual stitching",
        .metric_tags = &.{.operator_replay_workflow},
        .expected_bucket = .supported_success,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/operator_blocked_simple",
            .project_shard = "bench-operator-replay-workflow",
            .intent_text = "refactor src/solo.zig:compute",
            .max_steps = 3,
            .emit_panic_dump = true,
            .expect_status = .blocked,
            .expect_patch_result = true,
            .expect_panic_dump = true,
            .expect_replay_from_task = true,
        } },
    },
    .{
        .id = "operator_workflow_external_evidence_assisted",
        .title = "External evidence can be ingested and turned into proof-backed support",
        .metric_tags = &.{ .external_evidence_assisted_workflow, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-operator-external-evidence-assisted",
            .intent_text = "explain @corpus/docs/01-runbook.md:heading:runtime_contracts@1",
            .max_steps = 2,
            .evidence_fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/external_evidence_support",
            .evidence_files = &.{ "runbook.md", "runtime.toml", "worker.zig" },
            .expect_status = .verified_complete,
            .expect_evidence_state = .ingested,
            .expect_code_intel_result = true,
            .expect_external_evidence_result = true,
            .expect_support_completeness = true,
        } },
    },
    .{
        .id = "operator_workflow_external_evidence_alias",
        .title = "External evidence becomes addressable through stable corpus source-path aliases",
        .metric_tags = &.{ .external_evidence_assisted_workflow, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-operator-external-evidence-alias",
            .intent_text = "explain @corpus/docs/runbook.md:heading:runtime_contracts@1",
            .max_steps = 2,
            .evidence_fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/external_evidence_support",
            .evidence_files = &.{ "runbook.md", "runtime.toml", "worker.zig" },
            .expect_status = .verified_complete,
            .expect_evidence_state = .ingested,
            .expect_code_intel_result = true,
            .expect_external_evidence_result = true,
            .expect_support_completeness = true,
        } },
    },
    .{
        .id = "operator_workflow_runtime_verified_patch",
        .title = "Integrated task operator records runtime-verified patch completion when the oracle passes",
        .metric_tags = &.{ .runtime_verified_patch_workflow, .patch_compile_pass_rate, .test_pass_rate, .latency_per_verified_result, .provenance_support_completeness },
        .expected_bucket = .supported_success,
        .runner = .{ .task_workflow = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/runtime_oracle_positive",
            .project_shard = "bench-operator-runtime-verified-workflow",
            .intent_text = "refactor src/api/service.zig:compute but keep the API stable",
            .max_steps = 3,
            .expect_status = .verified_complete,
            .expect_patch_result = true,
            .expect_support_completeness = true,
            .expect_runtime_verified_patch = true,
        } },
    },
    .{
        .id = "tank_patch_partial_proof_gate",
        .title = "Weak patch rationale improves exploration but still cannot enter bounded proof admission",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/tank_patch_weak",
            .project_shard = "bench-tank-patch-weak",
            .target = "src/runtime/worker.zig:sync",
            .request_label = "weak runtime contract patch rationale",
            .caps = .{
                .max_candidates = 3,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .reinforcement_scenario = .runtime_contract_grounding,
            .use_tank_benchmark = true,
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_refactor_plan_status = .unresolved,
            .expect_partial_findings_min = 1,
            .expect_proof_admission_blocks_min = 1,
            .expect_candidate_count_min = 1,
            .expect_preserved_novel_min = 1,
        } },
    },
    .{
        .id = "tank_patch_ambiguous_unresolved",
        .title = "Ambiguous patch rationale stays unresolved with structured ambiguity data preserved",
        .metric_tags = &.{.unresolved_vs_unsupported_behavior},
        .expected_bucket = .correct_unresolved_or_refused,
        .runner = .{ .patch = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/tank_patch_ambiguous",
            .project_shard = "bench-tank-patch-ambiguous",
            .target = "src/runtime/worker.zig:sync",
            .request_label = "ambiguous patch rationale",
            .caps = .{
                .max_candidates = 3,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .reinforcement_scenario = .ambiguous_patch_grounding,
            .use_tank_benchmark = true,
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_refactor_plan_status = .unresolved,
            .expect_partial_findings_min = 1,
            .expect_ambiguity_sets_min = 1,
        } },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const bench_started = sys.getMilliTick();

    var results = std.ArrayList(CaseResult).init(allocator);
    defer {
        for (results.items) |*item| item.deinit();
        results.deinit();
    }

    var metrics = Metrics{};
    try measurePhase3LatencyProbes(allocator, &metrics);

    for (CASES) |spec| {
        const result = try runCase(allocator, spec);
        try results.append(result);
        accumulateMetrics(&metrics, spec, &results.items[results.items.len - 1]);
    }
    metrics.total_benchmark_wall_time_ms = sys.getMilliTick() - bench_started;

    const results_dir = try absolutePath(allocator, repo_hygiene.benchmark_results_rel_dir);
    defer allocator.free(results_dir);
    try sys.makePath(allocator, results_dir);

    const json_path = try outputPath(allocator, "json");
    defer allocator.free(json_path);
    const md_path = try outputPath(allocator, "md");
    defer allocator.free(md_path);

    const rendered_json = try renderJsonReport(allocator, &metrics, results.items);
    defer allocator.free(rendered_json);
    try writeAbsoluteFile(allocator, json_path, rendered_json);

    const rendered_md = try renderMarkdownReport(allocator, &metrics, results.items);
    defer allocator.free(rendered_md);
    try writeAbsoluteFile(allocator, md_path, rendered_md);

    sys.print("{s}\n", .{rendered_md});

    if (metrics.failed_cases != 0) return error.BenchmarkFailures;
}

fn measurePhase3LatencyProbes(allocator: std.mem.Allocator, metrics: *Metrics) !void {
    var draft_intent = try intent_grounding.ground(allocator, "explain src/main.zig", .{});
    defer draft_intent.deinit();

    const draft_started = sys.getMilliTick();
    var draft_result = try response_engine.execute(allocator, &draft_intent, .autoPath());
    defer draft_result.deinit();
    metrics.response_mode_selection_ms += draft_result.latency.eligibility_check_us / 1000 + draft_result.latency.escalation_us / 1000;
    metrics.response_draft_path_ms += @max(sys.getMilliTick() - draft_started, draft_result.latency.draft_path_us / 1000);
    countResponseMode(metrics, draft_result.selected_mode);

    var fast_intent = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer fast_intent.deinit();

    const fast_started = sys.getMilliTick();
    var fast_result = try response_engine.execute(allocator, &fast_intent, .autoPath());
    defer fast_result.deinit();
    metrics.response_mode_selection_ms += fast_result.latency.eligibility_check_us / 1000 + fast_result.latency.escalation_us / 1000;
    metrics.response_fast_path_ms += @max(sys.getMilliTick() - fast_started, fast_result.latency.fast_path_us / 1000);
    countResponseMode(metrics, fast_result.selected_mode);

    var deep_intent = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer deep_intent.deinit();

    const deep_started = sys.getMilliTick();
    var deep_result = try response_engine.execute(allocator, &deep_intent, .autoPath());
    defer deep_result.deinit();
    metrics.response_mode_selection_ms += deep_result.latency.eligibility_check_us / 1000 + deep_result.latency.escalation_us / 1000;
    metrics.response_deep_path_ms += @max(sys.getMilliTick() - deep_started, deep_result.latency.deep_path_us / 1000);
    countResponseMode(metrics, deep_result.selected_mode);

    var schema_registry = artifact_schema.SchemaRegistry.init(allocator);
    defer schema_registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&schema_registry);
    var artifact = try artifact_schema.Artifact.init(
        allocator,
        "phase3-latency-probe",
        .repo,
        .file,
        "bench_phase3_latency_probe",
        .project,
        "zig",
        "src/main.zig",
        null,
    );
    defer artifact.deinit(allocator);
    const pipeline_options = artifact_schema.PipelineOptions{ .registry = &schema_registry };
    const pipeline_started = sys.getMilliTick();
    var pipeline = try artifact_schema.ingestArtifact(
        allocator,
        &artifact,
        "const std = @import(\"std\");\npub fn main() void {}\n",
        &pipeline_options,
    );
    defer pipeline.deinit();
    metrics.artifact_schema_pipeline_ms += sys.getMilliTick() - pipeline_started;
    metrics.retained_token_signal_count += pipeline.discovery_signals.retained_token_signal_count;
    metrics.retained_pattern_signal_count += pipeline.discovery_signals.retained_pattern_signal_count;
    metrics.schema_entity_signal_count += pipeline.discovery_signals.schema_entity_signal_count;
    metrics.schema_relation_signal_count += pipeline.discovery_signals.schema_relation_signal_count;
    metrics.obligation_signal_count += pipeline.discovery_signals.obligation_signal_count;
    metrics.anchor_signal_count += pipeline.discovery_signals.anchor_signal_count;
    metrics.verifier_hint_signal_count += pipeline.discovery_signals.verifier_hint_signal_count;
    if (pipeline.discovery_signals.fallback_signal_used) metrics.fallback_signal_used_count += 1;
    recordPipelineHypotheses(metrics, &pipeline);

    var doc_artifact = try artifact_schema.Artifact.init(
        allocator,
        "phase3-hypothesis-doc",
        .repo,
        .document,
        "bench_phase3_hypothesis_doc",
        .project,
        "md",
        "docs/contract.md",
        null,
    );
    defer doc_artifact.deinit(allocator);
    var doc_pipeline = try artifact_schema.ingestArtifact(
        allocator,
        &doc_artifact,
        "# Runtime Contract\n\nThis contract says the observed retry window must match the configured retry window.\n",
        &pipeline_options,
    );
    defer doc_pipeline.deinit();
    recordPipelineHypotheses(metrics, &doc_pipeline);

    var registry = verifier_adapter.Registry.init(allocator);
    defer registry.deinit();
    try verifier_adapter.registerBuiltinAdapters(&registry);
    const dispatch_started = sys.getMilliTick();
    _ = registry.lookup("code_artifact_schema", .build, "build");
    _ = registry.lookup("code_artifact_schema", .build, "build");
    _ = registry.lookup("code_artifact_schema", .@"test", "test");
    _ = registry.lookup("config_schema", .schema_validation, "schema_validation");
    _ = registry.lookup("document_schema", .citation_check, "citation_check");
    metrics.verifier_adapter_dispatch_ms += sys.getMilliTick() - dispatch_started;

    var tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const config_entities = [_]artifact_schema.Entity{
        .{ .id = "cfg_key", .entity_type = "key", .fragment_index = 0, .label = "port", .provenance = "phase3-latency-probe", .artifact_id = "phase3-config" },
        .{ .id = "cfg_value", .entity_type = "value", .fragment_index = 0, .label = "3000", .provenance = "phase3-latency-probe", .artifact_id = "phase3-config" },
    };
    const adapter_run_started = sys.getMilliTick();
    var config_result = try verifier_adapter.run(allocator, &tracker, .{
        .adapter = verifier_adapter.configSchemaValidationAdapter(),
        .artifact = &artifact,
        .entities = &config_entities,
        .provenance = "phase3_latency_probe",
    });
    metrics.verifier_adapter_dispatch_ms += sys.getMilliTick() - adapter_run_started;
    recordPhase3VerifierResult(metrics, &config_result);
    config_result.deinit();

    const link_entity = artifact_schema.Entity{
        .id = "doc_link",
        .entity_type = "link",
        .fragment_index = 0,
        .label = "https://example.test/reference",
        .provenance = "phase3-latency-probe",
        .artifact_id = "phase3-doc",
    };
    const doc_run_started = sys.getMilliTick();
    var doc_result = try verifier_adapter.run(allocator, &tracker, .{
        .adapter = verifier_adapter.documentCitationCheckAdapter(),
        .entities = &.{link_entity},
        .provenance = "phase3_latency_probe",
    });
    metrics.verifier_adapter_dispatch_ms += sys.getMilliTick() - doc_run_started;
    recordPhase3VerifierResult(metrics, &doc_result);
    doc_result.deinit();
}

fn countResponseMode(metrics: *Metrics, mode: response_engine.ResponseMode) void {
    switch (mode) {
        .draft_mode => metrics.response_draft_mode_count += 1,
        .fast_path => metrics.response_fast_path_count += 1,
        .deep_path => metrics.response_deep_path_count += 1,
        .auto_path => {},
    }
}

fn recordPipelineHypotheses(metrics: *Metrics, pipeline: *const artifact_schema.PipelineResult) void {
    const summary = hypothesis_core.counts(pipeline.hypotheses);
    metrics.generated_hypothesis_count += @intCast(summary.total_count);
    if (pipeline.hypothesis_budget_exhaustion != null) {
        metrics.hypothesis_generation_budget_hit_count += 1;
        metrics.suppressed_hypothesis_count += 1;
    }
    var triage_result = hypothesis_core.triage(std.heap.page_allocator, pipeline.hypotheses, .{
        .max_hypotheses_selected = 3,
        .max_hypotheses_per_artifact = 2,
        .max_hypotheses_per_kind = 2,
        .max_duplicate_groups_traced = 8,
    }) catch null;
    if (triage_result) |*triaged| {
        defer triaged.deinit();
        metrics.selected_hypothesis_count += @intCast(triaged.selected);
        metrics.suppressed_hypothesis_count += @intCast(triaged.suppressed + triaged.duplicates + triaged.blocked + triaged.deferred);
        metrics.hypothesis_triage_selected_count += @intCast(triaged.selected);
        metrics.hypothesis_triage_suppressed_count += @intCast(triaged.suppressed + triaged.blocked + triaged.deferred);
        metrics.hypothesis_duplicate_count += @intCast(triaged.duplicates);
        metrics.hypothesis_budget_hit_count += @intCast(triaged.budget_hits);
        metrics.selected_code_hypothesis_count += @intCast(triaged.selected_code_count);
        metrics.selected_non_code_hypothesis_count += @intCast(triaged.selected_non_code_count);
        for (triaged.items, 0..) |item, idx| {
            if (!item.selected_for_next_stage) continue;
            const kind_idx = @intFromEnum(pipeline.hypotheses[idx].hypothesis_kind);
            metrics.top_selected_hypothesis_kinds[kind_idx] += 1;
        }
        var registry = verifier_adapter.Registry.init(std.heap.page_allocator);
        defer registry.deinit();
        verifier_adapter.registerBuiltinAdapters(&registry) catch {};
        var tracker = verifier_adapter.BudgetTracker.init(std.heap.page_allocator, compute_budget.resolve(.{ .tier = .medium }));
        const artifact: ?*const artifact_schema.Artifact = if (pipeline.artifacts.len > 0) &pipeline.artifacts[0] else null;
        var handoff = verifier_adapter.handoffSelectedHypotheses(
            std.heap.page_allocator,
            &registry,
            &tracker,
            pipeline.hypotheses,
            triaged.*,
            .{
                .artifact = artifact,
                .entities = pipeline.entities,
                .relations = pipeline.relations,
                .obligations = pipeline.obligations,
                .fragments = pipeline.fragments,
            },
            .deep,
        ) catch null;
        if (handoff) |*value| {
            defer value.deinit();
            metrics.hypothesis_verifier_eligible_count += @intCast(value.eligible_count);
            metrics.hypothesis_verifier_scheduled_count += @intCast(value.scheduled_count);
            metrics.hypothesis_verifier_completed_count += @intCast(value.completed_count);
            metrics.hypothesis_verifier_blocked_count += @intCast(value.blocked_count);
            metrics.hypothesis_verifier_skipped_count += @intCast(value.skipped_count);
            metrics.hypothesis_verifier_budget_exhausted_count += @intCast(value.budget_exhausted_count);
            metrics.code_hypothesis_verifier_job_count += @intCast(value.code_job_count);
            metrics.non_code_hypothesis_verifier_job_count += @intCast(value.non_code_job_count);
            metrics.verifier_candidate_proposed_count += @intCast(value.verifier_candidate_proposed_count);
            metrics.verifier_candidate_blocked_count += @intCast(value.verifier_candidate_blocked_count);
            metrics.verifier_candidate_accepted_count += @intCast(value.verifier_candidate_accepted_count);
            metrics.verifier_candidate_materialized_count += @intCast(value.verifier_candidate_materialized_count);
            metrics.verifier_candidate_rejected_count += @intCast(value.verifier_candidate_rejected_count);
            metrics.verifier_candidate_materialization_blocked_count += @intCast(value.verifier_candidate_materialization_blocked_count);
            metrics.verifier_candidate_budget_hit_count += @intCast(value.verifier_candidate_budget_exhausted_count);
            metrics.code_verifier_candidate_count += @intCast(value.code_verifier_candidate_count);
            metrics.non_code_verifier_candidate_count += @intCast(value.non_code_verifier_candidate_count);
        }
    } else {
        metrics.selected_hypothesis_count += @intCast(summary.selected_count);
    }
    metrics.hypothesis_generation_rules_fired += @intCast(countPipelineHypothesisRulesFired(pipeline.hypotheses));
    for (pipeline.hypotheses) |hypothesis| {
        if (std.mem.eql(u8, hypothesis.schema_name, "code_artifact_schema")) {
            metrics.code_hypothesis_count += 1;
        } else {
            metrics.non_code_hypothesis_count += 1;
        }
    }
}

fn countPipelineHypothesisRulesFired(hypotheses: []const hypothesis_core.Hypothesis) usize {
    var count: usize = 0;
    for (hypotheses, 0..) |item, idx| {
        var seen = false;
        for (hypotheses[0..idx]) |prior| {
            if (std.mem.eql(u8, item.source_rule, prior.source_rule)) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

fn recordPhase3VerifierResult(metrics: *Metrics, result: *const verifier_adapter.Result) void {
    metrics.verifier_adapter_run_count += 1;
    switch (result.status) {
        .passed => metrics.verifier_adapter_passed_count += 1,
        .failed => metrics.verifier_adapter_failed_count += 1,
        .blocked => metrics.verifier_adapter_blocked_count += 1,
        .skipped => metrics.verifier_adapter_skipped_count += 1,
        .budget_exhausted => metrics.verifier_budget_exhaustion_count += 1,
    }
    if (std.mem.startsWith(u8, result.adapter_id, "code.")) {
        metrics.code_verifier_count += 1;
    } else {
        metrics.non_code_verifier_count += 1;
    }
}

fn runCase(allocator: std.mem.Allocator, spec: CaseSpec) !CaseResult {
    return switch (spec.runner) {
        .code_intel => |case| runCodeIntelCase(allocator, spec, case),
        .cold_warm => |case| runColdWarmCase(allocator, spec, case),
        .patch => |case| runPatchCase(allocator, spec, case),
        .execution => |case| runExecutionCase(allocator, spec, case),
        .task_workflow => |case| runTaskWorkflowCase(allocator, spec, case),
    };
}

const PackBenchmarkSetup = struct {
    allocator: std.mem.Allocator,
    project_shard: []const u8,
    pack_ids: [][]u8 = &.{},
    pack_versions: [][]u8 = &.{},
    corpus_roots: [][]u8 = &.{},

    fn deinit(self: *PackBenchmarkSetup) void {
        for (self.pack_ids, self.pack_versions) |pack_id, pack_version| {
            knowledge_packs.setMountedState(self.allocator, self.project_shard, pack_id, pack_version, false, false) catch {};
            knowledge_packs.removePack(self.allocator, pack_id, pack_version) catch {};
            self.allocator.free(pack_id);
            self.allocator.free(pack_version);
        }
        if (self.pack_ids.len != 0) self.allocator.free(self.pack_ids);
        if (self.pack_versions.len != 0) self.allocator.free(self.pack_versions);
        for (self.corpus_roots) |root| {
            deleteTreeIfExistsAbsolute(root) catch {};
            self.allocator.free(root);
        }
        if (self.corpus_roots.len != 0) self.allocator.free(self.corpus_roots);
        self.* = undefined;
    }
};

fn setupPackScenario(allocator: std.mem.Allocator, project_shard: []const u8, scenario: PackScenario) !PackBenchmarkSetup {
    var setup = PackBenchmarkSetup{ .allocator = allocator, .project_shard = project_shard };
    errdefer setup.deinit();
    switch (scenario) {
        .runtime_small_activation_with_skips => {
            try addBenchmarkPack(allocator, &setup, "bench-pack-runtime-active", "v1", "runtime", "project", "active runtime pack", &.{
                .{ .rel_path = "runbook.md", .body = runtimeCorpusBody() },
            }, WORKER_SYNC_ABSTRACTION_CATALOG);
            try addBenchmarkPack(allocator, &setup, "bench-pack-docs-skip-a", "v1", "docs", "project", "irrelevant docs pack a", &.{
                .{ .rel_path = "guide.md", .body = docsCorpusBody("guide a") },
            }, null);
            try addBenchmarkPack(allocator, &setup, "bench-pack-docs-skip-b", "v1", "docs", "project", "irrelevant docs pack b", &.{
                .{ .rel_path = "guide.md", .body = docsCorpusBody("guide b") },
            }, null);
            try addBenchmarkPack(allocator, &setup, "bench-pack-config-skip-c", "v1", "configs", "project", "irrelevant config pack", &.{
                .{ .rel_path = "runtime.toml", .body = "mode = \"docs\"\nowner = \"ui\"\n" },
            }, null);
        },
        .runtime_large_mixed_relevant => {
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-runtime-core", "v1", "runtime", "project", "large runtime core pack", .runtime_core, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-runtime-config", "v1", "runtime", "project", "large runtime config pack", .runtime_config, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-runtime-logs", "v1", "runtime", "project", "large runtime logs pack", .runtime_logs, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-ui-noise", "v1", "ui", "project", "large ui noise pack", .ui_noise, null);
        },
        .runtime_large_irrelevant_only => {
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-ui-skip-1", "v1", "ui", "project", "irrelevant ui pack 1", .ui_noise, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-ui-skip-2", "v1", "ui", "project", "irrelevant ui pack 2", .ui_noise, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-ui-skip-3", "v1", "ui", "project", "irrelevant ui pack 3", .ui_noise, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-large-ui-skip-4", "v1", "ui", "project", "irrelevant ui pack 4", .ui_noise, null);
        },
        .runtime_large_trust_local_truth => {
            const conflicting_catalog = try mutatedRuntimeCoreConflictCatalog(allocator);
            defer allocator.free(conflicting_catalog);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-runtime-low-trust", "v1", "runtime", "exploratory", "lower trust conflicting runtime pack", .runtime_core, conflicting_catalog);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-runtime-high-trust", "v1", "runtime", "promoted", "higher trust conflicting runtime pack", .runtime_core, conflicting_catalog);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-runtime-config-support", "v1", "runtime", "project", "runtime config support pack", .runtime_config, null);
            try addFixtureBackedPack(allocator, &setup, "bench-pack-runtime-ui-noise", "v1", "ui", "project", "runtime ui noise pack", .ui_noise, null);
        },
    }
    return setup;
}

const PackCorpusFile = struct {
    rel_path: []const u8,
    body: []const u8,
};

fn addBenchmarkPack(
    allocator: std.mem.Allocator,
    setup: *PackBenchmarkSetup,
    pack_id_text: []const u8,
    pack_version_text: []const u8,
    domain_family: []const u8,
    trust_class: []const u8,
    source_summary: []const u8,
    files: []const PackCorpusFile,
    catalog_override: ?[]const u8,
) !void {
    const pack_id = try allocator.dupe(u8, pack_id_text);
    errdefer allocator.free(pack_id);
    const pack_version = try allocator.dupe(u8, pack_version_text);
    errdefer allocator.free(pack_version);
    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    const corpus_root = try benchmarkPackCorpusRoot(allocator, setup.project_shard, pack_id);
    errdefer {
        deleteTreeIfExistsAbsolute(corpus_root) catch {};
        allocator.free(corpus_root);
    }
    try deleteTreeIfExistsAbsolute(corpus_root);
    try sys.makePath(allocator, corpus_root);
    for (files) |file| {
        const abs_path = try std.fs.path.join(allocator, &.{ corpus_root, file.rel_path });
        defer allocator.free(abs_path);
        try writeAbsoluteFile(allocator, abs_path, file.body);
    }

    var pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = domain_family,
        .trust_class = trust_class,
        .source_summary = source_summary,
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = pack_id,
    });
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    if (catalog_override) |body| {
        const catalog_path = try std.fs.path.join(allocator, &.{ pack.root_abs_path, "abstractions", "abstractions.gabs" });
        defer allocator.free(catalog_path);
        try writeAbsoluteFile(allocator, catalog_path, body);
        try knowledge_packs.refreshPackManifestContent(allocator, pack_id, pack_version);
    }

    try knowledge_packs.setMountedState(allocator, setup.project_shard, pack_id, pack_version, true, true);
    setup.pack_ids = try appendOwnedString(allocator, setup.pack_ids, pack_id);
    setup.pack_versions = try appendOwnedString(allocator, setup.pack_versions, pack_version);
    setup.corpus_roots = try appendOwnedString(allocator, setup.corpus_roots, corpus_root);
}

fn appendOwnedString(allocator: std.mem.Allocator, items: [][]u8, value: []u8) ![][]u8 {
    var out = try allocator.alloc([]u8, items.len + 1);
    @memcpy(out[0..items.len], items);
    out[items.len] = value;
    if (items.len != 0) allocator.free(items);
    return out;
}

fn benchmarkPackCorpusRoot(allocator: std.mem.Allocator, project_shard: []const u8, pack_id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ "/tmp", "ghost_bench_packs", project_shard, pack_id });
}

fn runtimeCorpusBody() []const u8 {
    return 
    \\# Runtime Contracts
    \\worker.zig sync path defines the runtime contract and compute guard.
    \\Keep runtime worker sync aligned with service compute transitions.
    \\
    ;
}

fn docsCorpusBody(label: []const u8) []const u8 {
    _ = label;
    return 
    \\# UI Guide
    \\render.html owns the interface guide and does not describe runtime worker sync.
    \\
    ;
}

fn addFixtureBackedPack(
    allocator: std.mem.Allocator,
    setup: *PackBenchmarkSetup,
    pack_id_text: []const u8,
    pack_version_text: []const u8,
    domain_family: []const u8,
    trust_class: []const u8,
    source_summary: []const u8,
    fixture_kind: PackFixtureKind,
    catalog_override: ?[]const u8,
) !void {
    const fixture = packFixtureSpec(fixture_kind);
    var files = try allocator.alloc(PackCorpusFile, fixture.corpus_files.len);
    defer {
        for (files) |file| allocator.free(file.body);
        allocator.free(files);
    }

    for (fixture.corpus_files, 0..) |rel_path, idx| {
        const fixture_rel = try std.fs.path.join(allocator, &.{ fixture.root_rel, "corpus", rel_path });
        defer allocator.free(fixture_rel);
        files[idx] = .{
            .rel_path = rel_path,
            .body = try readFixtureFile(allocator, fixture_rel),
        };
    }

    const catalog_body = if (catalog_override) |body|
        try allocator.dupe(u8, body)
    else blk: {
        const fixture_rel = try std.fs.path.join(allocator, &.{ fixture.root_rel, "abstractions", "abstractions.gabs" });
        defer allocator.free(fixture_rel);
        break :blk try readFixtureFile(allocator, fixture_rel);
    };
    defer allocator.free(catalog_body);

    try addBenchmarkPack(allocator, setup, pack_id_text, pack_version_text, domain_family, trust_class, source_summary, files, catalog_body);
}

fn readFixtureFile(allocator: std.mem.Allocator, fixture_rel: []const u8) ![]u8 {
    const abs_path = try absolutePath(allocator, fixture_rel);
    defer allocator.free(abs_path);
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 512 * 1024);
}

fn mutatedRuntimeCoreConflictCatalog(allocator: std.mem.Allocator) ![]u8 {
    const fixture = packFixtureSpec(.runtime_core);
    const fixture_rel = try std.fs.path.join(allocator, &.{ fixture.root_rel, "abstractions", "abstractions.gabs" });
    defer allocator.free(fixture_rel);
    const body = try readFixtureFile(allocator, fixture_rel);
    errdefer allocator.free(body);
    const needle = "consensus_hash 601";
    const replacement = "consensus_hash 961";
    const idx = std.mem.indexOf(u8, body, needle) orelse return error.InvalidAbstractionCatalog;
    @memcpy(body[idx .. idx + replacement.len], replacement);
    return body;
}

fn countPackRoutingStatus(traces: []const abstractions.PackRoutingTrace, status: abstractions.PackRoutingStatus) usize {
    var count: usize = 0;
    for (traces) |item| {
        if (item.status == status) count += 1;
    }
    return count;
}

const PackCapStats = struct {
    total_cap_hits: usize = 0,
    candidate_surface_cap_hits: usize = 0,
    local_truth_win_count: usize = 0,
};

const PackStageStats = struct {
    peak_candidate_surface_count: usize = 0,
    peak_activated_count: usize = 0,
    peak_skipped_count: usize = 0,
    peak_suppressed_count: usize = 0,
};

fn collectPackCapStats(traces: []const abstractions.PackRoutingTrace) PackCapStats {
    var stats = PackCapStats{};
    for (traces) |trace| {
        if (std.mem.indexOf(u8, trace.reason, "preselection cap reached") != null) stats.total_cap_hits += 1;
        if (std.mem.indexOf(u8, trace.reason, "activation cap reached") != null) stats.total_cap_hits += 1;
        if (trace.suppressed_candidates > 0) {
            stats.total_cap_hits += 1;
            stats.candidate_surface_cap_hits += 1;
        }
        if (trace.local_truth_won) stats.local_truth_win_count += 1;
    }
    return stats;
}

fn collectPackStageStats(traces: []const abstractions.PackRoutingTrace) PackStageStats {
    var candidate_surfaces = std.AutoHashMap(u16, usize).init(std.heap.page_allocator);
    defer candidate_surfaces.deinit();
    var activated = std.AutoHashMap(u16, usize).init(std.heap.page_allocator);
    defer activated.deinit();
    var skipped = std.AutoHashMap(u16, usize).init(std.heap.page_allocator);
    defer skipped.deinit();
    var suppressed = std.AutoHashMap(u16, usize).init(std.heap.page_allocator);
    defer suppressed.deinit();

    for (traces) |trace| {
        const call_id = trace.call_id;
        const candidate_entry = candidate_surfaces.get(call_id) orelse 0;
        candidate_surfaces.put(call_id, candidate_entry + trace.candidate_surfaces) catch {};
        switch (trace.status) {
            .activated => {
                const entry = activated.get(call_id) orelse 0;
                activated.put(call_id, entry + 1) catch {};
            },
            .skipped => {
                const entry = skipped.get(call_id) orelse 0;
                skipped.put(call_id, entry + 1) catch {};
            },
            .suppressed => {
                const entry = suppressed.get(call_id) orelse 0;
                suppressed.put(call_id, entry + 1) catch {};
            },
            .conflict_refused, .stale_blocked, .trust_blocked => {},
        }
    }

    var stats = PackStageStats{};
    var candidate_iter = candidate_surfaces.valueIterator();
    while (candidate_iter.next()) |value| stats.peak_candidate_surface_count = @max(stats.peak_candidate_surface_count, value.*);
    var activated_iter = activated.valueIterator();
    while (activated_iter.next()) |value| stats.peak_activated_count = @max(stats.peak_activated_count, value.*);
    var skipped_iter = skipped.valueIterator();
    while (skipped_iter.next()) |value| stats.peak_skipped_count = @max(stats.peak_skipped_count, value.*);
    var suppressed_iter = suppressed.valueIterator();
    while (suppressed_iter.next()) |value| stats.peak_suppressed_count = @max(stats.peak_suppressed_count, value.*);
    return stats;
}

fn runCodeIntelCase(allocator: std.mem.Allocator, spec: CaseSpec, case: CodeIntelCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    if (case.project_shard) |project_shard| {
        try clearShardState(allocator, project_shard, if (case.reinforcement_scenario != null) .full_patch else .code_intel_only);
        if (case.seed_abstraction_catalog_body) |body| {
            try seedAbstractionsFromBody(allocator, project_shard, body);
        }
    }
    var pack_setup: ?PackBenchmarkSetup = null;
    defer if (pack_setup) |*setup| setup.deinit();
    if (case.pack_scenario) |scenario| {
        pack_setup = try setupPackScenario(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
    }
    var before_reinforcement: ?TankCaseCounters = null;
    var before_lookup_reuse_hits: usize = 0;
    var baseline_without_packs: ?code_intel.Result = null;
    defer if (baseline_without_packs) |*baseline| baseline.deinit();

    if (case.compare_without_packs) {
        if (pack_setup) |*setup| setup.deinit();
        pack_setup = null;
        baseline_without_packs = try code_intel.run(allocator, .{
            .repo_root = fixture_root,
            .project_shard = case.project_shard,
            .compute_budget_request = case.compute_budget_request,
            .pack_conflict_policy = case.pack_conflict_policy,
            .query_kind = case.query_kind,
            .target = case.target,
            .other_target = case.other_target,
            .max_items = case.max_items,
            .persist = case.persist,
            .cache_persist = case.cache_persist,
        });
        if (case.pack_scenario) |scenario| {
            pack_setup = try setupPackScenario(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
        }
    }

    if (case.compare_after_reinforcement) {
        var first = try code_intel.run(allocator, .{
            .repo_root = fixture_root,
            .project_shard = case.project_shard,
            .compute_budget_request = case.compute_budget_request,
            .pack_conflict_policy = case.pack_conflict_policy,
            .query_kind = case.query_kind,
            .target = case.target,
            .other_target = case.other_target,
            .max_items = case.max_items,
            .persist = case.persist,
            .cache_persist = case.cache_persist,
        });
        before_reinforcement = collectCodeIntelTankCounters(&first);
        if (case.reinforcement_scenario) |scenario| {
            before_lookup_reuse_hits = try lookupReinforcementScenarioHits(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
        }
        first.deinit();
        if (case.reinforcement_scenario) |scenario| {
            try applyReinforcementScenario(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
        }
    } else if (case.reinforcement_scenario) |scenario| {
        try applyReinforcementScenario(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
    }

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture_root,
        .project_shard = case.project_shard,
        .compute_budget_request = case.compute_budget_request,
        .pack_conflict_policy = case.pack_conflict_policy,
        .query_kind = case.query_kind,
        .target = case.target,
        .other_target = case.other_target,
        .max_items = case.max_items,
        .persist = case.persist,
        .cache_persist = case.cache_persist,
    });
    defer result.deinit();

    var failures = std.ArrayList([]u8).init(allocator);
    defer freeStringList(allocator, &failures);

    if (result.status != case.expect_status) try appendFailuref(allocator, &failures, "status expected {s} got {s}", .{ @tagName(case.expect_status), @tagName(result.status) });
    if (result.stop_reason != case.expect_stop_reason) try appendFailuref(allocator, &failures, "stop_reason expected {s} got {s}", .{ @tagName(case.expect_stop_reason), @tagName(result.stop_reason) });
    if (case.expect_contradiction_kind) |kind| {
        if (result.contradiction_kind == null or !std.mem.eql(u8, result.contradiction_kind.?, kind)) {
            try appendFailuref(allocator, &failures, "contradiction_kind expected {s}", .{kind});
        }
    }
    if (case.expect_primary_kind) |kind| {
        if (result.primary == null or !std.mem.eql(u8, result.primary.?.kind_name, kind)) {
            try appendFailuref(allocator, &failures, "primary kind expected {s}", .{kind});
        }
    }
    if (case.expect_evidence_rel_path) |rel_path| {
        if (result.evidence.len == 0 or !std.mem.eql(u8, result.evidence[0].rel_path, rel_path)) {
            try appendFailuref(allocator, &failures, "first evidence expected {s}", .{rel_path});
        }
    }

    const support_complete = codeIntelSupportComplete(&result);
    if (case.require_support_completeness and !support_complete) {
        try appendFailure(allocator, &failures, "support completeness check failed");
    }
    const pack_stats = code_intel.collectPackInfluenceStats(result.evidence, result.abstraction_traces, result.pack_routing_traces, result.grounding_traces, result.reverse_grounding_traces);
    const pack_cap_stats = collectPackCapStats(result.pack_routing_traces);
    const pack_stage_stats = collectPackStageStats(result.pack_routing_traces);
    if (pack_stage_stats.peak_activated_count < case.expect_pack_activated_min) try appendFailuref(allocator, &failures, "expected at least {d} activated packs in a routing stage", .{case.expect_pack_activated_min});
    if (case.expect_pack_activated_max) |max| {
        if (pack_stage_stats.peak_activated_count > max) try appendFailuref(allocator, &failures, "expected at most {d} activated packs in a routing stage", .{max});
    }
    if (pack_stats.skipped_count < case.expect_pack_skipped_min) try appendFailuref(allocator, &failures, "expected at least {d} skipped packs", .{case.expect_pack_skipped_min});
    if (pack_stats.trust_blocked_count < case.expect_pack_trust_blocked_min) try appendFailuref(allocator, &failures, "expected at least {d} trust-blocked packs", .{case.expect_pack_trust_blocked_min});
    if (pack_stats.conflict_refused_count < case.expect_pack_conflict_refused_min) try appendFailuref(allocator, &failures, "expected at least {d} conflict-refused packs", .{case.expect_pack_conflict_refused_min});
    if (pack_stage_stats.peak_candidate_surface_count < case.expect_pack_candidate_surfaces_min) try appendFailuref(allocator, &failures, "expected at least {d} pack candidate surfaces in a routing stage", .{case.expect_pack_candidate_surfaces_min});
    if (case.expect_pack_candidate_surfaces_max) |max| {
        if (pack_stage_stats.peak_candidate_surface_count > max) try appendFailuref(allocator, &failures, "expected at most {d} pack candidate surfaces in a routing stage", .{max});
    }
    if (pack_cap_stats.total_cap_hits < case.expect_pack_budget_caps_hit_min) try appendFailuref(allocator, &failures, "expected at least {d} visible pack budget cap hits", .{case.expect_pack_budget_caps_hit_min});
    if (pack_cap_stats.local_truth_win_count < case.expect_local_truth_wins_min) try appendFailuref(allocator, &failures, "expected at least {d} local-truth wins over mounted packs", .{case.expect_local_truth_wins_min});
    if (case.require_pack_traceability) {
        const rendered = try code_intel.renderJson(allocator, &result);
        defer allocator.free(rendered);
        if (std.mem.indexOf(u8, rendered, "\"packInfluence\":") == null) try appendFailure(allocator, &failures, "packInfluence summary missing from code_intel json");
        if (std.mem.indexOf(u8, rendered, "\"packRouting\":") == null) try appendFailure(allocator, &failures, "pack routing trace missing from code_intel json");
        if (std.mem.indexOf(u8, rendered, "\"computeBudget\":") == null) try appendFailure(allocator, &failures, "compute budget summary missing from code_intel json");
    }
    if (baseline_without_packs) |*baseline| {
        if (result.support_graph.nodes.len <= baseline.support_graph.nodes.len and pack_stats.abstraction_count == 0 and pack_stats.grounding_count == 0 and pack_stats.reverse_grounding_count == 0) {
            try appendFailure(allocator, &failures, "mounted packs did not improve visible support or add pack-derived abstraction/grounding traces");
        }
    }

    var tank = collectCodeIntelTankCounters(&result);
    if (case.reinforcement_scenario) |scenario| {
        const lookup_hits = try lookupReinforcementScenarioHits(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
        if (lookup_hits > tank.reinforcement_reuse_hit_count) tank.reinforcement_reuse_hit_count = lookup_hits;
    }
    if (tank.partial_finding_count < case.expect_partial_findings_min) try appendFailuref(allocator, &failures, "expected at least {d} partial findings", .{case.expect_partial_findings_min});
    if (tank.ambiguity_set_count < case.expect_ambiguity_sets_min) try appendFailuref(allocator, &failures, "expected at least {d} ambiguity sets", .{case.expect_ambiguity_sets_min});
    if (tank.suppressed_noise_count < case.expect_suppressed_noise_min) try appendFailuref(allocator, &failures, "expected at least {d} suppressed-noise items", .{case.expect_suppressed_noise_min});
    if (tank.reinforcement_reuse_hit_count < case.expect_reuse_hits_min) try appendFailuref(allocator, &failures, "expected at least {d} reinforcement reuse hits", .{case.expect_reuse_hits_min});
    if (before_reinforcement) |before| {
        if (tank.reinforcement_reuse_hit_count <= @max(before.reinforcement_reuse_hit_count, before_lookup_reuse_hits)) {
            try appendFailure(allocator, &failures, "reinforced rerun did not improve reuse hits");
        }
    }

    const actual_bucket = classifyCodeIntelBucket(&result);
    if (actual_bucket != spec.expected_bucket) {
        try appendFailuref(allocator, &failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
    }

    const detail = if (failures.items.len == 0)
        try std.fmt.allocPrint(allocator, "status={s}; tier={s}; evidence={d}; support_nodes={d}; packs={d}/{d}/{d}; pack_candidates={d}; cap_hits={d}", .{
            @tagName(result.status),
            compute_budget.tierName(result.effective_budget.effective_tier),
            result.evidence.len,
            result.support_graph.nodes.len,
            pack_stats.activated_count,
            pack_stats.skipped_count,
            pack_stats.trust_blocked_count + pack_stats.conflict_refused_count,
            pack_stats.candidate_surface_count,
            pack_cap_stats.total_cap_hits,
        })
    else
        try joinFailures(allocator, failures.items);

    return .{
        .allocator = allocator,
        .id = spec.id,
        .title = spec.title,
        .metric_tags = spec.metric_tags,
        .expected_bucket = spec.expected_bucket,
        .actual_bucket = actual_bucket,
        .passed = failures.items.len == 0,
        .duration_ms = 0,
        .detail = detail,
        .ghost_status = try allocator.dupe(u8, @tagName(result.status)),
        .stop_reason = try allocator.dupe(u8, @tagName(result.stop_reason)),
        .cache_lifecycle = try allocator.dupe(u8, @tagName(result.cache_lifecycle)),
        .contradiction_kind = try dupeOptional(allocator, result.contradiction_kind),
        .unresolved_detail = try dupeOptional(allocator, result.unresolved_detail),
        .support_complete = support_complete,
        .support_graph_minimum_met = result.support_graph.minimum_met,
        .support_node_count = result.support_graph.nodes.len,
        .support_edge_count = result.support_graph.edges.len,
        .evidence_count = result.evidence.len + result.contradiction_traces.len + result.refactor_path.len + result.overlap.len,
        .support_relevant = result.status == .supported,
        .partial_finding_count = @intCast(tank.partial_finding_count),
        .ambiguity_set_count = @intCast(tank.ambiguity_set_count),
        .suppressed_noise_count = @intCast(tank.suppressed_noise_count),
        .reinforcement_reuse_hit_count = @intCast(tank.reinforcement_reuse_hit_count),
        .repo_scan_ms = result.profile.repo_scan_ms,
        .cache_refresh_ms = result.profile.cache_refresh_ms,
        .index_materialize_ms = result.profile.index_materialize_ms,
        .routing_index_build_ms = result.profile.routing_index_build_ms,
        .routing_considered_count = @intCast(result.routing_trace.considered_count),
        .routing_selected_count = @intCast(result.routing_trace.selected_count),
        .routing_skipped_count = @intCast(result.routing_trace.skipped_count),
        .routing_suppressed_count = @intCast(result.routing_trace.suppressed_count),
        .routing_budget_cap_hit_count = if (result.routing_trace.budget_cap_hit) 1 else 0,
        .pack_mount_resolve_ms = result.profile.pack_mount_resolve_ms,
        .pack_manifest_preview_load_ms = result.profile.pack_manifest_preview_load_ms,
        .pack_routing_ms = result.profile.pack_routing_ms,
        .pack_catalog_load_ms = result.profile.pack_catalog_load_ms,
        .pack_candidate_surface_count = pack_stats.candidate_surface_count,
        .pack_peak_candidate_surface_count = @intCast(pack_stage_stats.peak_candidate_surface_count),
        .pack_activated_count = pack_stats.activated_count,
        .pack_peak_activated_count = @intCast(pack_stage_stats.peak_activated_count),
        .pack_skipped_count = pack_stats.skipped_count,
        .pack_peak_skipped_count = @intCast(pack_stage_stats.peak_skipped_count),
        .pack_suppressed_count = pack_stats.suppressed_count,
        .pack_peak_suppressed_count = @intCast(pack_stage_stats.peak_suppressed_count),
        .pack_conflict_refused_count = pack_stats.conflict_refused_count,
        .pack_trust_blocked_count = pack_stats.trust_blocked_count,
        .pack_stale_blocked_count = pack_stats.stale_blocked_count,
        .pack_budget_caps_hit_count = @intCast(pack_cap_stats.total_cap_hits),
        .pack_local_truth_win_count = @intCast(pack_cap_stats.local_truth_win_count),
        .requested_compute_tier = compute_budget.tierName(case.compute_budget_request.tier),
        .effective_compute_tier = compute_budget.tierName(result.effective_budget.effective_tier),
        .budget_exhausted = result.budget_exhaustion != null,
        .budget_limit = if (result.budget_exhaustion) |value| try allocator.dupe(u8, compute_budget.limitName(value.limit)) else null,
        .budget_stage = if (result.budget_exhaustion) |value| try allocator.dupe(u8, compute_budget.stageName(value.stage)) else null,
        .support_graph_build_ms = result.profile.support_graph_ms,
        .artifact_json_render_ms = result.profile.json_render_ms,
        .artifact_persist_ms = result.profile.persist_ms,
        .panic_dump_capture_ms = result.profile.panic_dump_ms,
    };
}

fn runColdWarmCase(allocator: std.mem.Allocator, spec: CaseSpec, case: ColdWarmCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    try clearShardState(allocator, case.project_shard, .code_intel_only);

    const cold_started = sys.getMilliTick();
    var first = try code_intel.run(allocator, .{
        .repo_root = fixture_root,
        .project_shard = case.project_shard,
        .query_kind = case.query_kind,
        .target = case.target,
        .other_target = case.other_target,
        .max_items = case.max_items,
        .persist = true,
        .cache_persist = true,
    });
    defer first.deinit();
    const cold_duration_ms = sys.getMilliTick() - cold_started;

    const warm_started = sys.getMilliTick();
    var second = try code_intel.run(allocator, .{
        .repo_root = fixture_root,
        .project_shard = case.project_shard,
        .query_kind = case.query_kind,
        .target = case.target,
        .other_target = case.other_target,
        .max_items = case.max_items,
        .persist = true,
        .cache_persist = true,
    });
    defer second.deinit();
    const warm_duration_ms = sys.getMilliTick() - warm_started;

    var failures = std.ArrayList([]u8).init(allocator);
    defer freeStringList(allocator, &failures);

    if (first.status != .supported) try appendFailure(allocator, &failures, "cold run was not supported");
    if (second.status != .supported) try appendFailure(allocator, &failures, "warm run was not supported");
    if (first.cache_lifecycle != .cold_build) try appendFailuref(allocator, &failures, "cold lifecycle expected cold_build got {s}", .{@tagName(first.cache_lifecycle)});
    if (second.cache_lifecycle != .warm_load) try appendFailuref(allocator, &failures, "warm lifecycle expected warm_load got {s}", .{@tagName(second.cache_lifecycle)});

    const actual_bucket: OutcomeBucket = if (first.status == .supported and second.status == .supported) .supported_success else .correct_unresolved_or_refused;
    if (actual_bucket != spec.expected_bucket) {
        try appendFailuref(allocator, &failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
    }

    const detail = if (failures.items.len == 0)
        try std.fmt.allocPrint(allocator, "cold={d}ms warm={d}ms cold_changed={d} warm_changed={d}", .{
            cold_duration_ms,
            warm_duration_ms,
            first.cache_changed_files,
            second.cache_changed_files,
        })
    else
        try joinFailures(allocator, failures.items);

    return .{
        .allocator = allocator,
        .id = spec.id,
        .title = spec.title,
        .metric_tags = spec.metric_tags,
        .expected_bucket = spec.expected_bucket,
        .actual_bucket = actual_bucket,
        .passed = failures.items.len == 0,
        .duration_ms = 0,
        .detail = detail,
        .ghost_status = try allocator.dupe(u8, "supported"),
        .stop_reason = try allocator.dupe(u8, @tagName(second.stop_reason)),
        .cache_lifecycle = try allocator.dupe(u8, "cold_build->warm_load"),
        .support_complete = codeIntelSupportComplete(&second),
        .support_graph_minimum_met = second.support_graph.minimum_met,
        .support_node_count = second.support_graph.nodes.len,
        .support_edge_count = second.support_graph.edges.len,
        .evidence_count = second.evidence.len + second.contradiction_traces.len + second.refactor_path.len + second.overlap.len,
        .cold_duration_ms = cold_duration_ms,
        .warm_duration_ms = warm_duration_ms,
        .cold_cache_changed_files = first.cache_changed_files,
        .warm_cache_changed_files = second.cache_changed_files,
        .support_relevant = true,
    };
}

fn runPatchCase(allocator: std.mem.Allocator, spec: CaseSpec, case: PatchCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    if (case.project_shard) |project_shard| try clearShardState(allocator, project_shard, .full_patch);
    if (case.seed_abstraction_catalog and case.project_shard != null) {
        try seedAbstractions(allocator, case.project_shard.?);
    }
    if (case.reinforcement_scenario) |scenario| {
        try applyReinforcementScenario(allocator, case.project_shard orelse return error.InvalidArguments, scenario);
    }
    if (case.shim_rel) |shim_rel| try clearShimState(allocator, shim_rel);

    const shim_path = if (case.shim_rel) |shim_rel|
        try absolutePath(allocator, shim_rel)
    else
        null;
    defer if (shim_path) |path| allocator.free(path);

    const started = sys.getMilliTick();
    const options: patch_candidates.Options = .{
        .repo_root = fixture_root,
        .project_shard = case.project_shard,
        .query_kind = case.query_kind,
        .target = case.target,
        .other_target = case.other_target,
        .request_label = case.request_label,
        .caps = case.caps,
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = shim_path,
    };
    var synthetic_intel: ?code_intel.Result = null;
    defer if (synthetic_intel) |*intel| intel.deinit();
    var result = blk: {
        if (case.use_tank_benchmark) {
            synthetic_intel = try buildSyntheticTankIntel(allocator, fixture_root, case);
            break :blk try patch_candidates.runTankBenchmarkFromIntel(allocator, options, &synthetic_intel.?);
        }
        break :blk try patch_candidates.run(allocator, options);
    };
    defer result.deinit();
    const duration_ms = sys.getMilliTick() - started;

    var failures = std.ArrayList([]u8).init(allocator);
    defer freeStringList(allocator, &failures);

    if (result.status != case.expect_status) try appendFailuref(allocator, &failures, "status expected {s} got {s}", .{ @tagName(case.expect_status), @tagName(result.status) });
    if (result.stop_reason != case.expect_stop_reason) try appendFailuref(allocator, &failures, "stop_reason expected {s} got {s}", .{ @tagName(case.expect_stop_reason), @tagName(result.stop_reason) });
    if (result.refactor_plan_status != case.expect_refactor_plan_status) try appendFailuref(allocator, &failures, "refactor_plan_status expected {s} got {s}", .{ @tagName(case.expect_refactor_plan_status), @tagName(result.refactor_plan_status) });
    if (case.require_selected_candidate and result.selected_candidate_id == null) try appendFailure(allocator, &failures, "selected candidate was required");

    const stats = collectPatchStats(&result);
    if (case.require_support_completeness and !stats.support_complete) try appendFailure(allocator, &failures, "support completeness check failed");
    if (case.expect_any_repair_plan and stats.repair_plan_count == 0) {
        const summary = try summarizePatchCandidates(allocator, &result);
        defer allocator.free(summary);
        try appendFailuref(allocator, &failures, "expected at least one repair plan; candidates={s}", .{summary});
    }
    if (case.expect_any_repair_recovery and stats.repair_recovered_count == 0) try appendFailure(allocator, &failures, "expected at least one repair-recovered candidate lineage");
    if (case.expect_any_repair_failed and stats.repair_failed_count == 0) try appendFailure(allocator, &failures, "expected at least one failed repair lineage");
    if (case.expect_any_refinement and stats.refinement_count == 0) {
        const summary = try summarizePatchCandidates(allocator, &result);
        defer allocator.free(summary);
        try appendFailuref(allocator, &failures, "expected at least one refinement trace; candidates={s}", .{summary});
    }
    if (case.expect_any_retry and stats.retrying_candidate_count == 0) try appendFailure(allocator, &failures, "expected at least one retrying candidate");
    if (case.expect_any_build_failed and !stats.any_build_failed) try appendFailure(allocator, &failures, "expected at least one build_failed candidate");
    if (case.expect_any_runtime_failed and !stats.any_runtime_failed) try appendFailure(allocator, &failures, "expected at least one runtime_failed candidate");
    if (case.expect_any_runtime_passed and stats.runtime_passed == 0) try appendFailure(allocator, &failures, "expected at least one runtime verification pass");
    if (case.expect_abstraction_refs_min > result.abstraction_refs.len) try appendFailuref(allocator, &failures, "expected at least {d} abstraction refs", .{case.expect_abstraction_refs_min});
    if (case.expect_selected_runtime_verified and (patch_candidates.selectedValidationState(&result) orelse .draft_unvalidated) != .runtime_verified) {
        try appendFailure(allocator, &failures, "selected survivor was expected to be runtime_verified");
    }

    if (case.expect_candidate0_test_failed) {
        if (result.candidates.len == 0 or result.candidates[0].validation_state != .test_failed) {
            try appendFailure(allocator, &failures, "candidate_1 was expected to fail test verification");
        }
    }
    if (case.expect_selected_scope_smaller_than_expanded) {
        if (!winnerSmallerThanExpanded(&result)) try appendFailure(allocator, &failures, "selected survivor was not smaller than expanded_neighbor_surface");
    }

    const tank = collectPatchTankCounters(&result);
    const feedback_event_count = if (case.project_shard) |project_shard| try countFeedbackEventsForShard(allocator, project_shard) else 0;
    const pack_stats = code_intel.collectPackInfluenceStats(result.source_pack_evidence, result.source_abstraction_traces, result.pack_routing_traces, result.grounding_traces, result.reverse_grounding_traces);
    if (tank.partial_finding_count < case.expect_partial_findings_min) try appendFailuref(allocator, &failures, "expected at least {d} patch partial findings", .{case.expect_partial_findings_min});
    if (tank.ambiguity_set_count < case.expect_ambiguity_sets_min) try appendFailuref(allocator, &failures, "expected at least {d} patch ambiguity sets", .{case.expect_ambiguity_sets_min});
    if (tank.suppressed_noise_count < case.expect_suppressed_noise_min) try appendFailuref(allocator, &failures, "expected at least {d} patch suppressed-noise items", .{case.expect_suppressed_noise_min});
    if (tank.reinforcement_reuse_hit_count < case.expect_reuse_hits_min) try appendFailuref(allocator, &failures, "expected at least {d} patch reuse hits", .{case.expect_reuse_hits_min});
    if (tank.proof_admission_blocked_count < case.expect_proof_admission_blocks_min) try appendFailuref(allocator, &failures, "expected at least {d} proof-admission blocks", .{case.expect_proof_admission_blocks_min});
    if (tank.candidate_count < case.expect_candidate_count_min) try appendFailuref(allocator, &failures, "expected at least {d} generated candidates", .{case.expect_candidate_count_min});
    if (tank.preserved_novel_count < case.expect_preserved_novel_min) try appendFailuref(allocator, &failures, "expected at least {d} preserved novel candidates", .{case.expect_preserved_novel_min});

    const actual_bucket = classifyPatchBucket(&result);
    if (actual_bucket != spec.expected_bucket) {
        try appendFailuref(allocator, &failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
    }

    const detail = if (failures.items.len == 0)
        try std.fmt.allocPrint(allocator, "status={s}; verified={d}; build={d}/{d}; test={d}/{d}; runtime={d}/{d}; repairs={d}/{d}", .{
            @tagName(result.status),
            stats.verified_supported_count,
            stats.build_passed,
            stats.build_attempted,
            stats.test_passed,
            stats.test_attempted,
            stats.runtime_passed,
            stats.runtime_attempted,
            stats.repair_recovered_count,
            stats.repair_plan_count,
        })
    else
        try joinFailures(allocator, failures.items);

    return .{
        .allocator = allocator,
        .id = spec.id,
        .title = spec.title,
        .metric_tags = spec.metric_tags,
        .expected_bucket = spec.expected_bucket,
        .actual_bucket = actual_bucket,
        .passed = failures.items.len == 0,
        .duration_ms = duration_ms,
        .detail = detail,
        .ghost_status = try allocator.dupe(u8, @tagName(result.status)),
        .stop_reason = try allocator.dupe(u8, @tagName(result.stop_reason)),
        .selected_refactor_scope = try dupeOptional(allocator, result.selected_refactor_scope),
        .selected_verification_state = if (patch_candidates.selectedValidationState(&result)) |state|
            try allocator.dupe(u8, @tagName(state))
        else
            null,
        .unresolved_detail = try dupeOptional(allocator, result.unresolved_detail),
        .support_complete = stats.support_complete,
        .support_graph_minimum_met = result.support_graph.minimum_met,
        .support_node_count = result.support_graph.nodes.len,
        .support_edge_count = result.support_graph.edges.len,
        .evidence_count = result.invariant_evidence.len + result.contradiction_evidence.len,
        .abstraction_ref_count = result.abstraction_refs.len,
        .verified_supported_count = stats.verified_supported_count,
        .build_attempted = stats.build_attempted,
        .build_passed = stats.build_passed,
        .test_attempted = stats.test_attempted,
        .test_passed = stats.test_passed,
        .runtime_attempted = stats.runtime_attempted,
        .runtime_passed = stats.runtime_passed,
        .repair_plan_count = stats.repair_plan_count,
        .repair_recovered_count = stats.repair_recovered_count,
        .repair_failed_count = stats.repair_failed_count,
        .retrying_candidate_count = stats.retrying_candidate_count,
        .refinement_count = stats.refinement_count,
        .support_relevant = result.status == .supported,
        .partial_finding_count = @intCast(tank.partial_finding_count),
        .ambiguity_set_count = @intCast(tank.ambiguity_set_count),
        .suppressed_noise_count = @intCast(tank.suppressed_noise_count),
        .reinforcement_reuse_hit_count = @intCast(tank.reinforcement_reuse_hit_count),
        .reinforcement_event_count = @intCast(feedback_event_count),
        .proof_admission_blocked_count = tank.proof_admission_blocked_count,
        .preserved_novel_count = tank.preserved_novel_count,
        .candidate_count = @intCast(tank.candidate_count),
        .pack_mount_resolve_ms = result.profile.pack_mount_resolve_ms,
        .pack_manifest_preview_load_ms = result.profile.pack_manifest_preview_load_ms,
        .pack_routing_ms = result.profile.pack_routing_ms,
        .pack_catalog_load_ms = result.profile.pack_catalog_load_ms,
        .pack_candidate_surface_count = pack_stats.candidate_surface_count,
        .pack_activated_count = pack_stats.activated_count,
        .pack_skipped_count = pack_stats.skipped_count,
        .pack_suppressed_count = pack_stats.suppressed_count,
        .pack_conflict_refused_count = pack_stats.conflict_refused_count,
        .pack_trust_blocked_count = pack_stats.trust_blocked_count,
        .pack_stale_blocked_count = pack_stats.stale_blocked_count,
        .support_graph_build_ms = result.profile.support_graph_ms,
        .verifier_adapter_dispatch_ms = result.profile.verifier_adapter_dispatch_ms,
        .artifact_json_render_ms = result.profile.json_render_ms,
        .panic_dump_capture_ms = result.profile.panic_dump_ms,
        .verification_workspace_ms = result.profile.workspace_prepare_ms,
        .verification_build_exec_ms = result.profile.build_exec_ms,
        .verification_test_exec_ms = result.profile.test_exec_ms,
        .verification_runtime_exec_ms = result.profile.runtime_exec_ms,
        .verifier_adapter_run_count = stats.verifier_adapter_run_count,
        .verifier_adapter_passed_count = stats.verifier_adapter_passed_count,
        .verifier_adapter_failed_count = stats.verifier_adapter_failed_count,
        .verifier_adapter_blocked_count = stats.verifier_adapter_blocked_count,
        .verifier_adapter_skipped_count = stats.verifier_adapter_skipped_count,
        .verifier_budget_exhaustion_count = stats.verifier_budget_exhaustion_count,
        .code_verifier_count = stats.code_verifier_count,
        .non_code_verifier_count = stats.non_code_verifier_count,
    };
}

fn runExecutionCase(allocator: std.mem.Allocator, spec: CaseSpec, case: ExecutionCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    const started = sys.getMilliTick();
    var result = try execution.run(allocator, .{
        .workspace_root = fixture_root,
        .cwd = fixture_root,
    }, case.step);
    defer result.deinit(allocator);
    const duration_ms = sys.getMilliTick() - started;

    var failures = std.ArrayList([]u8).init(allocator);
    defer freeStringList(allocator, &failures);

    if (result.failure_signal != case.expect_signal) try appendFailuref(allocator, &failures, "failure_signal expected {s} got {s}", .{ execution.failureSignalName(case.expect_signal), execution.failureSignalName(result.failure_signal) });
    if (case.expect_success and !result.succeeded()) try appendFailure(allocator, &failures, "expected execution success");

    const actual_bucket = classifyExecutionBucket(&result);
    if (actual_bucket != spec.expected_bucket) {
        try appendFailuref(allocator, &failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
    }

    const detail = blk: {
        if (failures.items.len != 0) break :blk try joinFailures(allocator, failures.items);
        const exit_text = if (result.exit_code) |code|
            try std.fmt.allocPrint(allocator, "{d}", .{code})
        else
            try allocator.dupe(u8, "none");
        defer allocator.free(exit_text);
        break :blk try std.fmt.allocPrint(allocator, "signal={s}; exit={s}", .{
            execution.failureSignalName(result.failure_signal),
            exit_text,
        });
    };

    return .{
        .allocator = allocator,
        .id = spec.id,
        .title = spec.title,
        .metric_tags = spec.metric_tags,
        .expected_bucket = spec.expected_bucket,
        .actual_bucket = actual_bucket,
        .passed = failures.items.len == 0,
        .duration_ms = duration_ms,
        .detail = detail,
        .ghost_status = try allocator.dupe(u8, if (result.succeeded()) "supported" else "unresolved"),
        .stop_reason = try allocator.dupe(u8, execution.failureSignalName(result.failure_signal)),
    };
}

fn runTaskWorkflowCase(allocator: std.mem.Allocator, spec: CaseSpec, case: TaskWorkflowCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    try clearShardState(allocator, case.project_shard, .full_task);
    if (case.seed_worker_sync_abstractions) {
        try seedAbstractionsFromBody(allocator, case.project_shard, WORKER_SYNC_ABSTRACTION_CATALOG);
    }

    var evidence_request_input: ?external_evidence.RequestInput = null;
    var evidence_owned_urls: ?[][]u8 = null;
    defer if (evidence_owned_urls) |urls| {
        for (urls) |value| allocator.free(value);
        allocator.free(urls);
    };
    var evidence_urls = std.ArrayList([]u8).init(allocator);
    defer {
        for (evidence_urls.items) |value| allocator.free(value);
        evidence_urls.deinit();
    }

    if (case.evidence_fixture_rel) |evidence_fixture_rel| {
        const evidence_root = try absolutePath(allocator, evidence_fixture_rel);
        defer allocator.free(evidence_root);
        for (case.evidence_files) |rel_path| {
            const abs_path = try std.fs.path.join(allocator, &.{ evidence_root, rel_path });
            defer allocator.free(abs_path);
            try evidence_urls.append(try fileUrlForPath(allocator, abs_path));
        }
        const owned_urls = try evidence_urls.toOwnedSlice();
        evidence_owned_urls = owned_urls;
        evidence_request_input = .{
            .urls = owned_urls,
            .max_sources = @intCast(owned_urls.len),
            .trust_class = .exploratory,
        };
    }

    const started = sys.getMilliTick();
    var session = try operator_workflow.runTask(allocator, .{
        .repo_root = fixture_root,
        .project_shard = case.project_shard,
        .intent_text = case.intent_text,
        .evidence_request = evidence_request_input,
        .max_steps = case.max_steps,
        .emit_panic_dump = case.emit_panic_dump,
    });
    defer session.deinit();
    const duration_ms = sys.getMilliTick() - started;

    var failures = std.ArrayList([]u8).init(allocator);
    defer freeStringList(allocator, &failures);

    if (session.status != case.expect_status) {
        try appendFailuref(allocator, &failures, "task status expected {s} got {s}", .{ @tagName(case.expect_status), @tagName(session.status) });
    }
    if (case.expect_evidence_state) |state| {
        if (session.evidence_state != state) {
            try appendFailuref(allocator, &failures, "evidence_state expected {s} got {s}", .{ external_evidence.acquisitionStateName(state), external_evidence.acquisitionStateName(session.evidence_state) });
        }
    }
    if (case.expect_patch_result and (session.last_patch_candidates_result_path == null or !fileExistsAbsolute(session.last_patch_candidates_result_path.?))) {
        try appendFailure(allocator, &failures, "expected task patch result artifact");
    }
    if (case.expect_code_intel_result and (session.last_code_intel_result_path == null or !fileExistsAbsolute(session.last_code_intel_result_path.?))) {
        try appendFailure(allocator, &failures, "expected task code-intel result artifact");
    }
    if (case.expect_external_evidence_result and (session.last_external_evidence_result_path == null or !fileExistsAbsolute(session.last_external_evidence_result_path.?))) {
        try appendFailure(allocator, &failures, "expected external evidence result artifact");
    }
    if (case.expect_panic_dump and (session.last_panic_dump_path == null or !fileExistsAbsolute(session.last_panic_dump_path.?))) {
        try appendFailure(allocator, &failures, "expected panic dump artifact");
    }

    const support_complete = taskSupportComplete(&session);
    if (case.expect_support_completeness and !support_complete) {
        try appendFailure(allocator, &failures, "task support completeness check failed");
    }
    if (case.expect_runtime_verified_patch) {
        const patch_path = session.last_patch_candidates_result_path orelse "";
        if (patch_path.len == 0 or !try patchArtifactContains(allocator, patch_path, "\"runtime_verified\"")) {
            try appendFailure(allocator, &failures, "expected runtime_verified patch artifact");
        }
    }
    if (case.expect_status_detail_substring) |substring| {
        if (session.status_detail == null or std.mem.indexOf(u8, session.status_detail.?, substring) == null) {
            try appendFailuref(allocator, &failures, "status detail expected to contain {s}", .{substring});
        }
    }

    var replay_ready = false;
    var replay_class_text: ?[]u8 = null;
    var replay_source_text: ?[]u8 = null;
    if (case.expect_replay_from_task) {
        var replay = operator_workflow.replayTask(allocator, case.project_shard, session.task_id, false) catch |err| {
            try appendFailuref(allocator, &failures, "replay-from-task failed: {s}", .{@errorName(err)});
            return finalizeTaskWorkflowCase(
                allocator,
                spec,
                case,
                &session,
                duration_ms,
                support_complete,
                false,
                null,
                null,
                failures.items,
            );
        };
        defer replay.deinit();
        replay_ready = replay.inspection.class == .fully_replayable;
        replay_class_text = try allocator.dupe(u8, replayClassName(replay.inspection.class));
        replay_source_text = try allocator.dupe(u8, replaySourceName(replay.inspection.source));
        if (!replay_ready) try appendFailure(allocator, &failures, "replay inspection was not fully replayable");
    }

    return finalizeTaskWorkflowCase(
        allocator,
        spec,
        case,
        &session,
        duration_ms,
        support_complete,
        replay_ready,
        replay_class_text,
        replay_source_text,
        failures.items,
    );
}

fn finalizeTaskWorkflowCase(
    allocator: std.mem.Allocator,
    spec: CaseSpec,
    case: TaskWorkflowCase,
    session: *const task_sessions.Session,
    duration_ms: u64,
    support_complete: bool,
    replay_ready: bool,
    replay_class_text: ?[]u8,
    replay_source_text: ?[]u8,
    failures: []const []u8,
) !CaseResult {
    const actual_bucket = classifyTaskBucket(session.status, case.expect_replay_from_task, replay_ready);
    const owned_replay_class = replay_class_text;
    errdefer freeOptional(allocator, owned_replay_class);
    const owned_replay_source = replay_source_text;
    errdefer freeOptional(allocator, owned_replay_source);

    if (actual_bucket != spec.expected_bucket) {
        var mutable_failures = std.ArrayList([]u8).init(allocator);
        defer {
            for (mutable_failures.items) |item| allocator.free(item);
            mutable_failures.deinit();
        }
        for (failures) |failure| try mutable_failures.append(try allocator.dupe(u8, failure));
        try appendFailuref(allocator, &mutable_failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
        const detail = try joinFailures(allocator, mutable_failures.items);
        return buildTaskCaseResult(allocator, spec, case, session, duration_ms, detail, support_complete, actual_bucket, false, replay_ready, owned_replay_class, owned_replay_source);
    }

    const detail = if (failures.len == 0)
        try std.fmt.allocPrint(allocator, "task_status={s}; evidence_state={s}; build={d}/{d}; test={d}/{d}; runtime={d}/{d}; replay_ready={s}", .{
            @tagName(session.status),
            external_evidence.acquisitionStateName(session.evidence_state),
            if (session.latest_support) |support| support.build_passed else 0,
            if (session.latest_support) |support| support.build_attempted else 0,
            if (session.latest_support) |support| support.test_passed else 0,
            if (session.latest_support) |support| support.test_attempted else 0,
            if (session.latest_support) |support| support.runtime_passed else 0,
            if (session.latest_support) |support| support.runtime_attempted else 0,
            if (replay_ready) "true" else "false",
        })
    else
        try joinFailures(allocator, failures);

    return buildTaskCaseResult(allocator, spec, case, session, duration_ms, detail, support_complete, actual_bucket, failures.len == 0, replay_ready, owned_replay_class, owned_replay_source);
}

fn buildTaskCaseResult(
    allocator: std.mem.Allocator,
    spec: CaseSpec,
    case: TaskWorkflowCase,
    session: *const task_sessions.Session,
    duration_ms: u64,
    detail: []u8,
    support_complete: bool,
    actual_bucket: OutcomeBucket,
    passed: bool,
    replay_ready: bool,
    replay_class_text: ?[]u8,
    replay_source_text: ?[]u8,
) !CaseResult {
    const feedback_event_count = try countFeedbackEventsForShard(allocator, case.project_shard);
    return .{
        .allocator = allocator,
        .id = spec.id,
        .title = spec.title,
        .metric_tags = spec.metric_tags,
        .expected_bucket = spec.expected_bucket,
        .actual_bucket = actual_bucket,
        .passed = passed,
        .duration_ms = duration_ms,
        .detail = detail,
        .ghost_status = try allocator.dupe(u8, @tagName(session.status)),
        .stop_reason = if (session.status_detail) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, "none"),
        .unresolved_detail = try dupeOptional(allocator, session.status_detail),
        .support_complete = support_complete,
        .support_graph_minimum_met = if (session.latest_support) |support| support.minimum_met else false,
        .support_node_count = if (session.latest_support) |support| support.node_count else 0,
        .support_edge_count = if (session.latest_support) |support| support.edge_count else 0,
        .evidence_count = if (session.latest_support) |support| support.evidence_count else 0,
        .abstraction_ref_count = if (session.latest_support) |support| support.abstraction_ref_count else 0,
        .verified_supported_count = if (session.latest_support) |support| support.verified_candidate_count else 0,
        .build_attempted = if (session.latest_support) |support| support.build_attempted else 0,
        .build_passed = if (session.latest_support) |support| support.build_passed else 0,
        .test_attempted = if (session.latest_support) |support| support.test_attempted else 0,
        .test_passed = if (session.latest_support) |support| support.test_passed else 0,
        .runtime_attempted = if (session.latest_support) |support| support.runtime_attempted else 0,
        .runtime_passed = if (session.latest_support) |support| support.runtime_passed else 0,
        .repair_recovered_count = if (session.latest_support) |support| support.repair_recovered_count else 0,
        .repair_failed_count = if (session.latest_support) |support| support.repair_failed_count else 0,
        .reinforcement_event_count = @intCast(feedback_event_count),
        .support_relevant = session.status == .verified_complete,
        .task_status = try allocator.dupe(u8, @tagName(session.status)),
        .evidence_state = try allocator.dupe(u8, external_evidence.acquisitionStateName(session.evidence_state)),
        .replay_ready = replay_ready,
        .replay_class = replay_class_text,
        .replay_source = replay_source_text,
        .task_artifact_write_ms = session.profile.artifact_write_ms,
        .task_artifact_write_count = session.profile.artifact_write_count,
        .task_session_save_ms = session.profile.session_save_ms,
        .task_session_save_count = session.profile.session_save_count,
    };
}

const PatchStats = struct {
    support_complete: bool,
    verified_supported_count: u32,
    build_attempted: u32,
    build_passed: u32,
    test_attempted: u32,
    test_passed: u32,
    runtime_attempted: u32,
    runtime_passed: u32,
    repair_plan_count: u32,
    repair_recovered_count: u32,
    repair_failed_count: u32,
    retrying_candidate_count: u32,
    refinement_count: u32,
    any_build_failed: bool,
    any_runtime_failed: bool,
    verifier_adapter_run_count: u32,
    verifier_adapter_passed_count: u32,
    verifier_adapter_failed_count: u32,
    verifier_adapter_blocked_count: u32,
    verifier_adapter_skipped_count: u32,
    verifier_budget_exhaustion_count: u32,
    code_verifier_count: u32,
    non_code_verifier_count: u32,
};

const TankCaseCounters = struct {
    partial_finding_count: usize = 0,
    ambiguity_set_count: usize = 0,
    suppressed_noise_count: usize = 0,
    reinforcement_reuse_hit_count: usize = 0,
    proof_admission_blocked_count: u32 = 0,
    preserved_novel_count: u32 = 0,
    candidate_count: usize = 0,
};

fn collectPatchStats(result: *const patch_candidates.Result) PatchStats {
    var stats = PatchStats{
        .support_complete = patchSupportComplete(result),
        .verified_supported_count = 0,
        .build_attempted = 0,
        .build_passed = 0,
        .test_attempted = 0,
        .test_passed = 0,
        .runtime_attempted = 0,
        .runtime_passed = 0,
        .repair_plan_count = 0,
        .repair_recovered_count = 0,
        .repair_failed_count = 0,
        .retrying_candidate_count = 0,
        .refinement_count = 0,
        .any_build_failed = false,
        .any_runtime_failed = false,
        .verifier_adapter_run_count = 0,
        .verifier_adapter_passed_count = 0,
        .verifier_adapter_failed_count = 0,
        .verifier_adapter_blocked_count = 0,
        .verifier_adapter_skipped_count = 0,
        .verifier_budget_exhaustion_count = 0,
        .code_verifier_count = 0,
        .non_code_verifier_count = 0,
    };
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        if (candidate.status == .supported and (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified)) {
            stats.verified_supported_count += 1;
        }
        if (candidate.validation_state == .build_failed) stats.any_build_failed = true;
        if (candidate.validation_state == .runtime_failed) stats.any_runtime_failed = true;
        stats.repair_plan_count += @intCast(candidate.verification.repair_plans.len);
        for (candidate.verification.repair_plans) |plan| {
            if (plan.outcome == .improved) stats.repair_recovered_count += 1;
            if (plan.outcome == .failed) stats.repair_failed_count += 1;
        }
        if (candidate.verification.retry_count > 0) stats.retrying_candidate_count += 1;
        stats.refinement_count += @intCast(candidate.verification.refinements.len);
        if (candidate.verification.build.state != .unavailable) {
            stats.build_attempted += 1;
            if (candidate.verification.build.state == .passed) stats.build_passed += 1;
            collectVerifierStepStats(&stats, candidate.verification.build);
        }
        if (candidate.verification.test_step.state != .unavailable) {
            stats.test_attempted += 1;
            if (candidate.verification.test_step.state == .passed) stats.test_passed += 1;
            collectVerifierStepStats(&stats, candidate.verification.test_step);
        }
        if (candidate.verification.runtime_step.state != .unavailable) {
            stats.runtime_attempted += 1;
            if (candidate.verification.runtime_step.state == .passed) stats.runtime_passed += 1;
            collectVerifierStepStats(&stats, candidate.verification.runtime_step);
        }
    }
    return stats;
}

fn collectVerifierStepStats(stats: *PatchStats, step: patch_candidates.VerificationStep) void {
    stats.verifier_adapter_run_count += 1;
    switch (step.state) {
        .passed => stats.verifier_adapter_passed_count += 1,
        .failed => stats.verifier_adapter_failed_count += 1,
        .unavailable => stats.verifier_adapter_skipped_count += 1,
    }
    if (step.adapter_id) |adapter_id| {
        if (std.mem.startsWith(u8, adapter_id, "code.")) {
            stats.code_verifier_count += 1;
        } else {
            stats.non_code_verifier_count += 1;
        }
    }
}

fn collectCodeIntelTankCounters(result: *const code_intel.Result) TankCaseCounters {
    var counters = TankCaseCounters{
        .partial_finding_count = result.unresolved.partial_findings.len,
        .ambiguity_set_count = result.unresolved.ambiguity_sets.len,
        .suppressed_noise_count = result.unresolved.suppressed_noise.len + result.routing_suppressed.len,
    };
    for (result.grounding_traces) |trace| {
        if (trace.selection_mode == .promoted) counters.reinforcement_reuse_hit_count += 1;
    }
    for (result.reverse_grounding_traces) |trace| {
        if (trace.selection_mode == .promoted) counters.reinforcement_reuse_hit_count += 1;
    }
    for (result.abstraction_traces) |trace| {
        if (trace.selection_mode == .promoted) counters.reinforcement_reuse_hit_count += 1;
    }
    for (result.routing_suppressed) |item| {
        if (std.mem.indexOf(u8, item.reason, "reinforced") != null) counters.reinforcement_reuse_hit_count += 1;
    }
    return counters;
}

fn collectPatchTankCounters(result: *const patch_candidates.Result) TankCaseCounters {
    var counters = TankCaseCounters{
        .partial_finding_count = result.unresolved.partial_findings.len,
        .ambiguity_set_count = result.unresolved.ambiguity_sets.len,
        .suppressed_noise_count = result.unresolved.suppressed_noise.len,
        .proof_admission_blocked_count = result.handoff.proof.admission_blocked_count,
        .preserved_novel_count = result.handoff.exploration.preserved_novel_count,
        .candidate_count = result.candidates.len,
    };
    for (result.candidates) |candidate| {
        for (candidate.trace) |trace| {
            if (trace.kind == .grounding_schema_anchor) counters.reinforcement_reuse_hit_count += 1;
        }
    }
    return counters;
}

fn buildSyntheticTankIntel(allocator: std.mem.Allocator, fixture_root: []const u8, case: PatchCase) !code_intel.Result {
    const shard_id = case.project_shard orelse "bench-tank-synthetic";
    var result = code_intel.Result{
        .allocator = allocator,
        .status = .unresolved,
        .query_kind = case.query_kind,
        .query_target = try allocator.dupe(u8, case.target),
        .query_other_target = if (case.other_target) |value| try allocator.dupe(u8, value) else null,
        .repo_root = try allocator.dupe(u8, fixture_root),
        .shard_root = try allocator.dupe(u8, fixture_root),
        .shard_id = try allocator.dupe(u8, shard_id),
        .shard_kind = if (case.project_shard != null) .project else .core,
        .cache_lifecycle = .cold_build,
        .reasoning_mode = .exploratory,
        .stop_reason = .low_confidence,
        .confidence = 0,
        .partial_support = .{},
        .unresolved = .{ .allocator = allocator },
        .support_graph = .{ .allocator = allocator },
    };
    errdefer result.deinit();

    if (std.mem.eql(u8, case.fixture_rel, "benchmarks/ghost_serious_workflows/fixtures/tank_patch_weak")) {
        result.primary = .{
            .name = try allocator.dupe(u8, "sync"),
            .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
            .line = 1,
            .kind_name = "function",
            .subsystem = "runtime",
        };
        result.partial_support = .{
            .lattice = .scoped,
            .blocking = .{ .insufficient = true },
        };
        result.unresolved.partial_findings = try allocator.alloc(code_intel.PartialFinding, 1);
        result.unresolved.partial_findings[0] = .{
            .kind = .scoped_claim,
            .label = try allocator.dupe(u8, "heading:runtime_contracts@1"),
            .scope = try allocator.dupe(u8, "sync"),
            .provenance = try allocator.dupe(u8, "symbolic_ingest"),
            .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
            .line = 1,
            .detail = try allocator.dupe(u8, "weak symbolic fragment narrowed the patch surface"),
        };
        result.grounding_traces = try allocator.alloc(code_intel.GroundingTrace, 1);
        result.grounding_traces[0] = .{
            .direction = .symbolic_to_code,
            .surface = try allocator.dupe(u8, "sync"),
            .concept = try allocator.dupe(u8, "heading:runtime_contracts@1"),
            .source_spec = try allocator.dupe(u8, "region:docs/runbook.md:1-1"),
            .selection_mode = .promoted,
            .owner_kind = .project,
            .owner_id = try allocator.dupe(u8, shard_id),
            .relation = try allocator.dupe(u8, "symbolic_unit_to_internal_concept"),
            .lookup_score = 320,
            .confidence_score = 320,
            .trust_class = .project,
            .lineage_id = try allocator.dupe(u8, "project:tank_patch_weak:grounding_schema:runtime_contracts"),
            .lineage_version = 1,
            .token_support_count = 2,
            .pattern_support_count = 2,
            .source_support_count = 1,
            .mapping_score = 360,
            .usable = true,
            .ambiguous = false,
            .resolution = .local,
            .conflict_kind = .none,
            .target_label = try allocator.dupe(u8, "sync"),
            .target_rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
            .target_line = 1,
            .target_kind = try allocator.dupe(u8, "function"),
            .detail = try allocator.dupe(u8, "usable grounding anchor"),
        };
        return result;
    }

    if (std.mem.eql(u8, case.fixture_rel, "benchmarks/ghost_serious_workflows/fixtures/tank_patch_ambiguous")) {
        result.primary = .{
            .name = try allocator.dupe(u8, "sync"),
            .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
            .line = 1,
            .kind_name = "function",
            .subsystem = "runtime",
        };
        result.partial_support = .{
            .lattice = .scoped,
            .blocking = .{ .ambiguous = true, .insufficient = true },
        };
        result.unresolved.partial_findings = try allocator.alloc(code_intel.PartialFinding, 1);
        result.unresolved.partial_findings[0] = .{
            .kind = .scoped_claim,
            .label = try allocator.dupe(u8, "heading:patch_rationale@1"),
            .scope = try allocator.dupe(u8, "sync"),
            .provenance = try allocator.dupe(u8, "grounding:test"),
            .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
            .line = 1,
            .detail = try allocator.dupe(u8, "equally plausible symbolic anchors remain"),
        };
        result.unresolved.ambiguity_sets = try allocator.alloc(code_intel.AmbiguitySet, 1);
        result.unresolved.ambiguity_sets[0] = .{
            .label = try allocator.dupe(u8, "grounding_ambiguity"),
            .scope = try allocator.dupe(u8, "sync"),
            .reason = try allocator.dupe(u8, "equally supported mappings"),
            .options = try allocator.alloc(code_intel.AmbiguityOption, 2),
        };
        result.unresolved.ambiguity_sets[0].options[0] = .{
            .label = try allocator.dupe(u8, "src/runtime/worker.zig:sync"),
            .rel_path = try allocator.dupe(u8, "src/runtime/worker.zig"),
            .line = 1,
            .detail = try allocator.dupe(u8, "runtime worker candidate"),
        };
        result.unresolved.ambiguity_sets[0].options[1] = .{
            .label = try allocator.dupe(u8, "src/ui/worker.zig:sync"),
            .rel_path = try allocator.dupe(u8, "src/ui/worker.zig"),
            .line = 1,
            .detail = try allocator.dupe(u8, "ui worker candidate"),
        };
        return result;
    }

    return error.InvalidArguments;
}

fn winnerSmallerThanExpanded(result: *const patch_candidates.Result) bool {
    var winner_cost: ?u32 = null;
    var expanded_cost: ?u32 = null;

    for (result.candidates) |candidate| {
        if (candidate.status == .supported and (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified)) {
            winner_cost = candidate.minimality.total_cost;
        }
        if (std.mem.eql(u8, candidate.scope, "expanded_neighbor_surface")) {
            expanded_cost = candidate.minimality.total_cost;
        }
    }

    if (winner_cost == null or expanded_cost == null) return false;
    return winner_cost.? < expanded_cost.?;
}

fn summarizePatchCandidates(allocator: std.mem.Allocator, result: *const patch_candidates.Result) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    for (result.candidates, 0..) |candidate, idx| {
        if (idx != 0) try writer.writeAll(" | ");
        try writer.print("{s}:scope={s},hunks={d},proof={s},state={s},retry={d},refinements={d}", .{
            candidate.id,
            candidate.scope,
            candidate.hunks.len,
            if (candidate.entered_proof_mode) "yes" else "no",
            @tagName(candidate.validation_state),
            candidate.verification.retry_count,
            candidate.verification.refinements.len,
        });
    }
    return out.toOwnedSlice();
}

fn codeIntelSupportComplete(result: *const code_intel.Result) bool {
    if (result.status != .supported) return false;
    if (!result.support_graph.minimum_met) return false;
    if (result.support_graph.permission != .supported) return false;
    if (result.support_graph.nodes.len == 0 or result.support_graph.edges.len == 0) return false;
    const evidence_count = result.evidence.len + result.contradiction_traces.len + result.refactor_path.len + result.overlap.len;
    return evidence_count > 0;
}

fn patchSupportComplete(result: *const patch_candidates.Result) bool {
    if (result.status != .supported) return false;
    if (!result.support_graph.minimum_met) return false;
    if (result.support_graph.permission != .supported) return false;
    if (result.support_graph.nodes.len == 0 or result.support_graph.edges.len == 0) return false;
    if (result.selected_candidate_id == null) return false;
    if (result.invariant_evidence.len + result.contradiction_evidence.len + result.abstraction_refs.len == 0) return false;
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        if (candidate.status != .supported) continue;
        if (candidate.validation_state != .build_test_verified and candidate.validation_state != .runtime_verified) continue;
        if (candidate.verification.build.state != .passed) return false;
        if (candidate.verification.test_step.state == .passed) return true;
        if (candidate.verification.runtime_step.state == .passed) return true;
    }
    return false;
}

fn classifyCodeIntelBucket(result: *const code_intel.Result) OutcomeBucket {
    return if (result.status == .supported) .supported_success else .correct_unresolved_or_refused;
}

fn classifyPatchBucket(result: *const patch_candidates.Result) OutcomeBucket {
    if (result.status == .supported) return .supported_success;
    for (result.candidates) |candidate| {
        if (candidate.validation_state == .build_failed or candidate.validation_state == .test_failed or candidate.validation_state == .runtime_failed) {
            return .failed_verification_or_runtime;
        }
        if (candidate.verification.build.state == .failed or candidate.verification.test_step.state == .failed or candidate.verification.runtime_step.state == .failed) {
            return .failed_verification_or_runtime;
        }
    }
    return .correct_unresolved_or_refused;
}

fn classifyExecutionBucket(result: *const execution.Result) OutcomeBucket {
    if (result.succeeded()) return .supported_success;
    return switch (result.failure_signal) {
        .disallowed_command, .workspace_violation => .correct_unresolved_or_refused,
        else => .failed_verification_or_runtime,
    };
}

const ShardClearMode = enum {
    code_intel_only,
    full_patch,
    full_task,
};

fn clearShardState(allocator: std.mem.Allocator, project_shard: []const u8, mode: ShardClearMode) !void {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    try deleteTreeIfExistsAbsolute(paths.code_intel_root_abs_path);
    if (mode == .full_patch) {
        try deleteTreeIfExistsAbsolute(paths.patch_candidates_root_abs_path);
        try deleteTreeIfExistsAbsolute(paths.abstractions_root_abs_path);
        try deleteFeedbackState(allocator, &paths);
    } else if (mode == .full_task) {
        try deleteTreeIfExistsAbsolute(paths.patch_candidates_root_abs_path);
        try deleteTreeIfExistsAbsolute(paths.abstractions_root_abs_path);
        try deleteTreeIfExistsAbsolute(paths.task_sessions_root_abs_path);
        try deleteTreeIfExistsAbsolute(paths.corpus_ingest_root_abs_path);
        try deleteFeedbackState(allocator, &paths);
    }
}

fn deleteFeedbackState(allocator: std.mem.Allocator, paths: *const shards.Paths) !void {
    const feedback_root = try std.fs.path.join(allocator, &.{ paths.root_abs_path, "feedback" });
    defer allocator.free(feedback_root);
    try deleteTreeIfExistsAbsolute(feedback_root);
}

fn seedAbstractions(allocator: std.mem.Allocator, project_shard: []const u8) !void {
    try seedAbstractionsFromBody(allocator, project_shard, ABSTRACTION_CATALOG);
}

fn seedAbstractionsFromBody(allocator: std.mem.Allocator, project_shard: []const u8, body: []const u8) !void {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    try sys.makePath(allocator, paths.abstractions_root_abs_path);
    const handle = try sys.openForWrite(allocator, paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, body);
}

fn applyReinforcementScenario(allocator: std.mem.Allocator, project_shard: []const u8, scenario: ReinforcementScenario) !void {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    switch (scenario) {
        .runtime_contract_grounding => {
            const sources = [_][]const u8{"region:docs/runbook.md:1-1"};
            const patterns = [_][]const u8{
                "heading:runtime_contracts@1",
                "direction:symbolic_to_code",
                "target_kind:declaration",
                "src/runtime/worker.zig",
            };
            const events = [_]abstractions.ReinforcementEvent{
                .{ .family = .grounding_schema, .key = "heading:runtime_contracts@1", .case_id = "tank-runtime-ground-a", .tier = .idiom, .category = .interface, .outcome = .success, .source_specs = &sources, .patterns = &patterns },
                .{ .family = .grounding_schema, .key = "heading:runtime_contracts@1", .case_id = "tank-runtime-ground-b", .tier = .idiom, .category = .interface, .outcome = .success, .source_specs = &sources, .patterns = &patterns },
            };
            _ = try abstractions.applyReinforcementEvents(allocator, &paths, &events, .{ .max_events = events.len, .max_new_records = events.len });
        },
        .ambiguous_patch_grounding => {
            const runtime_sources = [_][]const u8{"region:docs/rationale.md:1-1"};
            const runtime_patterns = [_][]const u8{
                "heading:patch_rationale@1",
                "direction:symbolic_to_code",
                "target_kind:declaration",
                "src/runtime/worker.zig",
            };
            const ui_sources = [_][]const u8{"region:docs/rationale.md:1-1"};
            const ui_patterns = [_][]const u8{
                "heading:patch_rationale@1",
                "direction:symbolic_to_code",
                "target_kind:declaration",
                "src/ui/worker.zig",
            };
            const events = [_]abstractions.ReinforcementEvent{
                .{ .family = .grounding_schema, .key = "heading:patch_rationale@1/runtime_worker", .case_id = "tank-ambiguous-ground-a", .tier = .idiom, .category = .interface, .outcome = .success, .source_specs = &runtime_sources, .patterns = &runtime_patterns },
                .{ .family = .grounding_schema, .key = "heading:patch_rationale@1/runtime_worker", .case_id = "tank-ambiguous-ground-b", .tier = .idiom, .category = .interface, .outcome = .success, .source_specs = &runtime_sources, .patterns = &runtime_patterns },
                .{ .family = .grounding_schema, .key = "heading:patch_rationale@1/ui_worker", .case_id = "tank-ambiguous-ground-c", .tier = .idiom, .category = .interface, .outcome = .success, .source_specs = &ui_sources, .patterns = &ui_patterns },
                .{ .family = .grounding_schema, .key = "heading:patch_rationale@1/ui_worker", .case_id = "tank-ambiguous-ground-d", .tier = .idiom, .category = .interface, .outcome = .success, .source_specs = &ui_sources, .patterns = &ui_patterns },
            };
            _ = try abstractions.applyReinforcementEvents(allocator, &paths, &events, .{ .max_events = events.len, .max_new_records = events.len });
        },
    }
}

fn lookupReinforcementScenarioHits(allocator: std.mem.Allocator, project_shard: []const u8, scenario: ReinforcementScenario) !usize {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    const refs = switch (scenario) {
        .runtime_contract_grounding => blk: {
            const patterns = [_][]const u8{
                "heading:runtime_contracts@1",
                "direction:symbolic_to_code",
                "target_kind:declaration",
                "src/runtime/worker.zig",
            };
            break :blk try abstractions.lookupFamilyConcepts(allocator, &paths, .{
                .family = .grounding_schema,
                .patterns = &patterns,
                .max_items = 4,
            });
        },
        .ambiguous_patch_grounding => blk: {
            const patterns = [_][]const u8{
                "heading:patch_rationale@1",
                "direction:symbolic_to_code",
                "target_kind:declaration",
            };
            break :blk try abstractions.lookupFamilyConcepts(allocator, &paths, .{
                .family = .grounding_schema,
                .patterns = &patterns,
                .max_items = 8,
            });
        },
    };
    defer abstractions.deinitSupportReferences(allocator, refs);

    var hits: usize = 0;
    for (refs) |reference| {
        if (reference.selection_mode == .promoted or reference.usable) hits += 1;
    }
    return hits;
}

fn clearShimState(allocator: std.mem.Allocator, shim_rel: []const u8) !void {
    const shim_root = try absolutePath(allocator, shim_rel);
    defer allocator.free(shim_root);
    const stamp_path = try std.fs.path.join(allocator, &.{ shim_root, "..", "build_fail_once.stamp" });
    defer allocator.free(stamp_path);
    try deleteFileIfExistsAbsolute(stamp_path);
}

fn countFeedbackEventsForShard(allocator: std.mem.Allocator, project_shard: []const u8) !usize {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return feedback.countEvents(allocator, &paths);
}

fn accumulateMetrics(metrics: *Metrics, spec: CaseSpec, result: *const CaseResult) void {
    metrics.total_cases += 1;
    if (result.passed) metrics.passed_cases += 1 else metrics.failed_cases += 1;

    incrementBucketExpected(metrics, result.expected_bucket);
    incrementBucketActual(metrics, result.actual_bucket);

    for (result.metric_tags) |tag| {
        metrics.category_totals[@intFromEnum(tag)] += 1;
        if (result.passed) metrics.category_passed[@intFromEnum(tag)] += 1;
    }

    metrics.patch_build_attempted += result.build_attempted;
    metrics.patch_build_passed += result.build_passed;
    metrics.patch_test_attempted += result.test_attempted;
    metrics.patch_test_passed += result.test_passed;
    metrics.patch_runtime_attempted += result.runtime_attempted;
    metrics.patch_runtime_passed += result.runtime_passed;

    if (result.verified_supported_count > 0) {
        metrics.verified_result_count += result.verified_supported_count;
        metrics.total_verified_latency_ms += result.duration_ms;
    }

    if (result.support_relevant) {
        metrics.support_relevant_cases += 1;
        if (result.support_complete) metrics.support_complete_cases += 1;
    }
    const expect_partial = expectedPartialFindingMin(spec);
    if (expect_partial > 0) {
        metrics.partial_finding_cases += 1;
        if (result.partial_finding_count >= expect_partial) metrics.partial_finding_preserved_cases += 1;
    }
    const expect_ambiguity = expectedAmbiguitySetMin(spec);
    if (expect_ambiguity > 0) {
        metrics.ambiguity_cases += 1;
        if (result.ambiguity_set_count >= expect_ambiguity) metrics.ambiguity_preserved_cases += 1;
    }
    metrics.suppressed_noise_count += result.suppressed_noise_count;
    metrics.reinforcement_reuse_hit_count += result.reinforcement_reuse_hit_count;
    metrics.reinforcement_event_count += result.reinforcement_event_count;
    metrics.unsupported_proof_admission_block_count += result.proof_admission_blocked_count;
    metrics.repo_scan_ms += result.repo_scan_ms;
    metrics.cache_refresh_ms += result.cache_refresh_ms;
    metrics.index_materialize_ms += result.index_materialize_ms;
    metrics.routing_index_build_ms += result.routing_index_build_ms;
    metrics.routing_considered_count += result.routing_considered_count;
    metrics.routing_selected_count += result.routing_selected_count;
    metrics.routing_skipped_count += result.routing_skipped_count;
    metrics.routing_suppressed_count += result.routing_suppressed_count;
    metrics.routing_budget_cap_hit_count += result.routing_budget_cap_hit_count;
    metrics.pack_mount_resolve_ms += result.pack_mount_resolve_ms;
    metrics.pack_manifest_preview_load_ms += result.pack_manifest_preview_load_ms;
    metrics.pack_routing_ms += result.pack_routing_ms;
    metrics.pack_catalog_load_ms += result.pack_catalog_load_ms;
    metrics.pack_candidate_surface_count += result.pack_candidate_surface_count;
    metrics.pack_peak_candidate_surface_count += result.pack_peak_candidate_surface_count;
    metrics.pack_activated_count += result.pack_activated_count;
    metrics.pack_peak_activated_count += result.pack_peak_activated_count;
    metrics.pack_skipped_count += result.pack_skipped_count;
    metrics.pack_peak_skipped_count += result.pack_peak_skipped_count;
    metrics.pack_budget_caps_hit_count += result.pack_budget_caps_hit_count;
    metrics.pack_local_truth_win_count += result.pack_local_truth_win_count;
    metrics.support_graph_build_ms += result.support_graph_build_ms;
    metrics.verifier_adapter_dispatch_ms += result.verifier_adapter_dispatch_ms;
    metrics.artifact_json_render_ms += result.artifact_json_render_ms;
    metrics.artifact_persist_ms += result.artifact_persist_ms;
    metrics.panic_dump_capture_ms += result.panic_dump_capture_ms;
    metrics.verification_workspace_ms += result.verification_workspace_ms;
    metrics.verification_build_exec_ms += result.verification_build_exec_ms;
    metrics.verification_test_exec_ms += result.verification_test_exec_ms;
    metrics.verification_runtime_exec_ms += result.verification_runtime_exec_ms;
    metrics.verifier_adapter_run_count += result.verifier_adapter_run_count;
    metrics.verifier_adapter_passed_count += result.verifier_adapter_passed_count;
    metrics.verifier_adapter_failed_count += result.verifier_adapter_failed_count;
    metrics.verifier_adapter_blocked_count += result.verifier_adapter_blocked_count;
    metrics.verifier_adapter_skipped_count += result.verifier_adapter_skipped_count;
    metrics.verifier_budget_exhaustion_count += result.verifier_budget_exhaustion_count;
    metrics.code_verifier_count += result.code_verifier_count;
    metrics.non_code_verifier_count += result.non_code_verifier_count;
    metrics.task_artifact_write_ms += result.task_artifact_write_ms;
    metrics.task_artifact_write_count += result.task_artifact_write_count;
    metrics.task_session_save_ms += result.task_session_save_ms;
    metrics.task_session_save_count += result.task_session_save_count;

    if (result.cold_duration_ms > 0 or result.warm_duration_ms > 0) {
        metrics.cold_start_ms = result.cold_duration_ms;
        metrics.warm_start_ms = result.warm_duration_ms;
        metrics.cold_cache_changed_files = result.cold_cache_changed_files;
        metrics.warm_cache_changed_files = result.warm_cache_changed_files;
    }

    if (result.task_status != null) {
        metrics.workflow_cases += 1;
        if (result.passed) metrics.workflow_passed_cases += 1;
        switch (parseTaskStatus(result.task_status.?)) {
            .planned => metrics.task_state_planned += 1,
            .running => metrics.task_state_running += 1,
            .blocked => metrics.task_state_blocked += 1,
            .unresolved => metrics.task_state_unresolved += 1,
            .verified_complete => metrics.task_state_verified_complete += 1,
            .failed => metrics.task_state_failed += 1,
        }
    }
    if (result.replay_class != null or result.replay_ready) {
        metrics.replay_cases += 1;
        if (result.replay_ready) metrics.replay_ready_cases += 1;
    }
    if (result.evidence_state) |state_text| {
        metrics.external_evidence_cases += 1;
        switch (parseEvidenceState(state_text)) {
            .not_needed => metrics.evidence_state_not_needed += 1,
            .requested => metrics.evidence_state_requested += 1,
            .fetched => metrics.evidence_state_fetched += 1,
            .ingested => metrics.evidence_state_ingested += 1,
            .conflicting => metrics.evidence_state_conflicting += 1,
            .insufficient => metrics.evidence_state_insufficient += 1,
        }
    }
}

fn incrementBucketExpected(metrics: *Metrics, bucket: OutcomeBucket) void {
    switch (bucket) {
        .supported_success => metrics.bucket_expected_supported_success += 1,
        .correct_unresolved_or_refused => metrics.bucket_expected_correct_unresolved_or_refused += 1,
        .failed_verification_or_runtime => metrics.bucket_expected_failed_verification_or_runtime += 1,
    }
}

fn expectedPartialFindingMin(spec: CaseSpec) u32 {
    return switch (spec.runner) {
        .code_intel => |case| @intCast(case.expect_partial_findings_min),
        .cold_warm => 0,
        .patch => |case| @intCast(case.expect_partial_findings_min),
        .execution => 0,
        .task_workflow => 0,
    };
}

fn expectedAmbiguitySetMin(spec: CaseSpec) u32 {
    return switch (spec.runner) {
        .code_intel => |case| @intCast(case.expect_ambiguity_sets_min),
        .cold_warm => 0,
        .patch => |case| @intCast(case.expect_ambiguity_sets_min),
        .execution => 0,
        .task_workflow => 0,
    };
}

fn incrementBucketActual(metrics: *Metrics, bucket: OutcomeBucket) void {
    switch (bucket) {
        .supported_success => metrics.bucket_actual_supported_success += 1,
        .correct_unresolved_or_refused => metrics.bucket_actual_correct_unresolved_or_refused += 1,
        .failed_verification_or_runtime => metrics.bucket_actual_failed_verification_or_runtime += 1,
    }
}

fn renderJsonReport(allocator: std.mem.Allocator, metrics: *const Metrics, results: []const CaseResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "suite", "ghost_serious_workflows", true);
    try writeJsonFieldString(writer, "os", @tagName(builtin.os.tag), false);
    const project_root = try config.getPath(allocator, ".");
    defer allocator.free(project_root);
    try writeJsonFieldString(writer, "projectRoot", project_root, false);
    try writer.writeAll(",\"metrics\":{");
    try writer.print("\"totalCases\":{d},\"passedCases\":{d},\"failedCases\":{d}", .{
        metrics.total_cases,
        metrics.passed_cases,
        metrics.failed_cases,
    });
    try writer.print(",\"totalBenchmarkWallTimeMs\":{d}", .{metrics.total_benchmark_wall_time_ms});
    try writer.print(",\"codeImpactCorrectnessRate\":{d}", .{scaledRate(metrics, .code_impact_correctness)});
    try writer.print(",\"contradictionDetectionCorrectnessRate\":{d}", .{scaledRate(metrics, .contradiction_detection_correctness)});
    try writer.print(",\"unresolvedVsUnsupportedRate\":{d}", .{scaledRate(metrics, .unresolved_vs_unsupported_behavior)});
    try writer.print(",\"minimalSafeRefactorCorrectnessRate\":{d}", .{scaledRate(metrics, .minimal_safe_refactor_correctness)});
    try writer.print(",\"executionLoopHandlingRate\":{d}", .{scaledRate(metrics, .execution_loop_success_failure_handling)});
    try writer.print(",\"provenanceSupportCompletenessRate\":{d}", .{scaledSupportRate(metrics)});
    try writer.print(",\"operatorVerifiedCompleteWorkflowRate\":{d}", .{scaledRate(metrics, .operator_verified_complete_workflow)});
    try writer.print(",\"operatorBlockedWorkflowRate\":{d}", .{scaledRate(metrics, .operator_blocked_workflow)});
    try writer.print(",\"operatorUnresolvedWorkflowRate\":{d}", .{scaledRate(metrics, .operator_unresolved_workflow)});
    try writer.print(",\"operatorReplayWorkflowRate\":{d}", .{scaledRate(metrics, .operator_replay_workflow)});
    try writer.print(",\"externalEvidenceAssistedWorkflowRate\":{d}", .{scaledRate(metrics, .external_evidence_assisted_workflow)});
    try writer.print(",\"runtimeVerifiedPatchWorkflowRate\":{d}", .{scaledRate(metrics, .runtime_verified_patch_workflow)});
    try writer.print(",\"patchCompilePassRate\":{d}", .{scaledFraction(metrics.patch_build_passed, metrics.patch_build_attempted)});
    try writer.print(",\"testPassRate\":{d}", .{scaledFraction(metrics.patch_test_passed, metrics.patch_test_attempted)});
    try writer.print(",\"runtimePassRate\":{d}", .{scaledFraction(metrics.patch_runtime_passed, metrics.patch_runtime_attempted)});
    try writer.print(",\"verifiedResultCount\":{d}", .{metrics.verified_result_count});
    try writer.print(",\"latencyPerVerifiedResultMs\":{d}", .{avgMs(metrics.total_verified_latency_ms, metrics.verified_result_count)});
    try writer.print(",\"coldStartMs\":{d}", .{metrics.cold_start_ms});
    try writer.print(",\"warmStartMs\":{d}", .{metrics.warm_start_ms});
    try writer.print(",\"coldCacheChangedFiles\":{d}", .{metrics.cold_cache_changed_files});
    try writer.print(",\"warmCacheChangedFiles\":{d}", .{metrics.warm_cache_changed_files});
    try writer.print(",\"supportCompleteCases\":{d}", .{metrics.support_complete_cases});
    try writer.print(",\"supportRelevantCases\":{d}", .{metrics.support_relevant_cases});
    try writer.print(",\"workflowCases\":{d},\"workflowPassedCases\":{d}", .{ metrics.workflow_cases, metrics.workflow_passed_cases });
    try writer.print(",\"taskStatePlanned\":{d},\"taskStateRunning\":{d},\"taskStateBlocked\":{d},\"taskStateUnresolved\":{d},\"taskStateVerifiedComplete\":{d},\"taskStateFailed\":{d}", .{
        metrics.task_state_planned,
        metrics.task_state_running,
        metrics.task_state_blocked,
        metrics.task_state_unresolved,
        metrics.task_state_verified_complete,
        metrics.task_state_failed,
    });
    try writer.print(",\"replayCases\":{d},\"replayReadyCases\":{d}", .{ metrics.replay_cases, metrics.replay_ready_cases });
    try writer.print(",\"externalEvidenceCases\":{d},\"evidenceStateNotNeeded\":{d},\"evidenceStateRequested\":{d},\"evidenceStateFetched\":{d},\"evidenceStateIngested\":{d},\"evidenceStateConflicting\":{d},\"evidenceStateInsufficient\":{d}", .{
        metrics.external_evidence_cases,
        metrics.evidence_state_not_needed,
        metrics.evidence_state_requested,
        metrics.evidence_state_fetched,
        metrics.evidence_state_ingested,
        metrics.evidence_state_conflicting,
        metrics.evidence_state_insufficient,
    });
    try writer.print(",\"partialFindingPreservationRate\":{d},\"ambiguityPreservationRate\":{d},\"suppressedNoiseCount\":{d},\"reinforcementEventCount\":{d},\"reinforcementReuseHitCount\":{d},\"reinforcementReuseHitRateAfterReinforcement\":{d},\"draftIntentResolutionImprovement\":{d},\"unsupportedProofAdmissionBlockCount\":{d}", .{
        scaledFraction(metrics.partial_finding_preserved_cases, metrics.partial_finding_cases),
        scaledFraction(metrics.ambiguity_preserved_cases, metrics.ambiguity_cases),
        metrics.suppressed_noise_count,
        metrics.reinforcement_event_count,
        metrics.reinforcement_reuse_hit_count,
        scaledFraction(metrics.reinforcement_reuse_hit_count, metrics.reinforcement_event_count),
        scaledFraction(metrics.reinforcement_event_count, metrics.total_cases),
        metrics.unsupported_proof_admission_block_count,
    });
    try writer.print(",\"repoScanMs\":{d},\"cacheRefreshMs\":{d},\"indexMaterializeMs\":{d},\"routingIndexBuildMs\":{d},\"routingCandidatesConsidered\":{d},\"routingCandidatesSelected\":{d},\"routingCandidatesSkipped\":{d},\"routingCandidatesSuppressed\":{d},\"routingBudgetCapHits\":{d},\"retainedTokenSignalCount\":{d},\"retainedPatternSignalCount\":{d},\"schemaEntitySignalCount\":{d},\"schemaRelationSignalCount\":{d},\"obligationSignalCount\":{d},\"anchorSignalCount\":{d},\"verifierHintSignalCount\":{d},\"fallbackSignalUsedCount\":{d}", .{
        metrics.repo_scan_ms,
        metrics.cache_refresh_ms,
        metrics.index_materialize_ms,
        metrics.routing_index_build_ms,
        metrics.routing_considered_count,
        metrics.routing_selected_count,
        metrics.routing_skipped_count,
        metrics.routing_suppressed_count,
        metrics.routing_budget_cap_hit_count,
        metrics.retained_token_signal_count,
        metrics.retained_pattern_signal_count,
        metrics.schema_entity_signal_count,
        metrics.schema_relation_signal_count,
        metrics.obligation_signal_count,
        metrics.anchor_signal_count,
        metrics.verifier_hint_signal_count,
        metrics.fallback_signal_used_count,
    });
    try writer.print(",\"generatedHypothesisCount\":{d},\"selectedHypothesisCount\":{d},\"suppressedHypothesisCount\":{d},\"hypothesisGenerationBudgetHitCount\":{d},\"hypothesisGenerationRulesFired\":{d},\"codeHypothesisCount\":{d},\"nonCodeHypothesisCount\":{d},\"hypothesisTriageSelectedCount\":{d},\"hypothesisTriageSuppressedCount\":{d},\"hypothesisDuplicateCount\":{d},\"hypothesisBudgetHitCount\":{d},\"selectedCodeHypothesisCount\":{d},\"selectedNonCodeHypothesisCount\":{d},\"hypothesisVerifierEligibleCount\":{d},\"hypothesisVerifierScheduledCount\":{d},\"hypothesisVerifierCompletedCount\":{d},\"hypothesisVerifierBlockedCount\":{d},\"hypothesisVerifierSkippedCount\":{d},\"hypothesisVerifierBudgetExhaustedCount\":{d},\"codeHypothesisVerifierJobCount\":{d},\"nonCodeHypothesisVerifierJobCount\":{d},\"verifierCandidateProposedCount\":{d},\"verifierCandidateBlockedCount\":{d},\"verifierCandidateAcceptedCount\":{d},\"verifierCandidateMaterializedCount\":{d},\"verifierCandidateRejectedCount\":{d},\"verifierCandidateMaterializationBlockedCount\":{d},\"verifierCandidateBudgetHitCount\":{d},\"codeVerifierCandidateCount\":{d},\"nonCodeVerifierCandidateCount\":{d}", .{
        metrics.generated_hypothesis_count,
        metrics.selected_hypothesis_count,
        metrics.suppressed_hypothesis_count,
        metrics.hypothesis_generation_budget_hit_count,
        metrics.hypothesis_generation_rules_fired,
        metrics.code_hypothesis_count,
        metrics.non_code_hypothesis_count,
        metrics.hypothesis_triage_selected_count,
        metrics.hypothesis_triage_suppressed_count,
        metrics.hypothesis_duplicate_count,
        metrics.hypothesis_budget_hit_count,
        metrics.selected_code_hypothesis_count,
        metrics.selected_non_code_hypothesis_count,
        metrics.hypothesis_verifier_eligible_count,
        metrics.hypothesis_verifier_scheduled_count,
        metrics.hypothesis_verifier_completed_count,
        metrics.hypothesis_verifier_blocked_count,
        metrics.hypothesis_verifier_skipped_count,
        metrics.hypothesis_verifier_budget_exhausted_count,
        metrics.code_hypothesis_verifier_job_count,
        metrics.non_code_hypothesis_verifier_job_count,
        metrics.verifier_candidate_proposed_count,
        metrics.verifier_candidate_blocked_count,
        metrics.verifier_candidate_accepted_count,
        metrics.verifier_candidate_materialized_count,
        metrics.verifier_candidate_rejected_count,
        metrics.verifier_candidate_materialization_blocked_count,
        metrics.verifier_candidate_budget_hit_count,
        metrics.code_verifier_candidate_count,
        metrics.non_code_verifier_candidate_count,
    });
    try writer.writeAll(",\"topSelectedHypothesisKinds\":");
    try writeTopSelectedHypothesisKindsJson(writer, &metrics.top_selected_hypothesis_kinds);
    try writer.print(",\"packMountResolveMs\":{d},\"packManifestPreviewLoadMs\":{d},\"packRoutingMs\":{d},\"packCatalogLoadMs\":{d},\"packCandidateSurfaceCount\":{d},\"packActivatedCount\":{d},\"packSkippedCount\":{d},\"packBudgetCapsHitCount\":{d},\"packLocalTruthWinCount\":{d},\"supportGraphBuildMs\":{d}", .{
        metrics.pack_mount_resolve_ms,
        metrics.pack_manifest_preview_load_ms,
        metrics.pack_routing_ms,
        metrics.pack_catalog_load_ms,
        metrics.pack_candidate_surface_count,
        metrics.pack_activated_count,
        metrics.pack_skipped_count,
        metrics.pack_budget_caps_hit_count,
        metrics.pack_local_truth_win_count,
        metrics.support_graph_build_ms,
    });
    try writer.print(",\"responseModeSelectionMs\":{d},\"responseDraftModeCount\":{d},\"responseFastPathCount\":{d},\"responseDeepPathCount\":{d},\"responseDraftPathMs\":{d},\"responseFastPathMs\":{d},\"responseDeepPathMs\":{d},\"artifactSchemaPipelineMs\":{d},\"verifierAdapterDispatchMs\":{d}", .{
        metrics.response_mode_selection_ms,
        metrics.response_draft_mode_count,
        metrics.response_fast_path_count,
        metrics.response_deep_path_count,
        metrics.response_draft_path_ms,
        metrics.response_fast_path_ms,
        metrics.response_deep_path_ms,
        metrics.artifact_schema_pipeline_ms,
        metrics.verifier_adapter_dispatch_ms,
    });
    try writer.print(",\"artifactJsonRenderMs\":{d},\"artifactPersistMs\":{d},\"panicDumpCaptureMs\":{d}", .{
        metrics.artifact_json_render_ms,
        metrics.artifact_persist_ms,
        metrics.panic_dump_capture_ms,
    });
    try writer.print(",\"verificationWorkspaceMs\":{d},\"verificationBuildExecMs\":{d},\"verificationTestExecMs\":{d},\"verificationRuntimeExecMs\":{d}", .{
        metrics.verification_workspace_ms,
        metrics.verification_build_exec_ms,
        metrics.verification_test_exec_ms,
        metrics.verification_runtime_exec_ms,
    });
    try writer.print(",\"verifierAdapterRunCount\":{d},\"verifierAdapterPassedCount\":{d},\"verifierAdapterFailedCount\":{d},\"verifierAdapterBlockedCount\":{d},\"verifierAdapterSkippedCount\":{d},\"verifierBudgetExhaustionCount\":{d},\"codeVerifierCount\":{d},\"nonCodeVerifierCount\":{d}", .{
        metrics.verifier_adapter_run_count,
        metrics.verifier_adapter_passed_count,
        metrics.verifier_adapter_failed_count,
        metrics.verifier_adapter_blocked_count,
        metrics.verifier_adapter_skipped_count,
        metrics.verifier_budget_exhaustion_count,
        metrics.code_verifier_count,
        metrics.non_code_verifier_count,
    });
    try writer.print(",\"taskArtifactWriteMs\":{d},\"taskArtifactWriteCount\":{d},\"taskSessionSaveMs\":{d},\"taskSessionSaveCount\":{d}", .{
        metrics.task_artifact_write_ms,
        metrics.task_artifact_write_count,
        metrics.task_session_save_ms,
        metrics.task_session_save_count,
    });
    try writer.writeAll("}");

    try writer.writeAll(",\"cases\":[");
    for (results, 0..) |result, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "id", result.id, true);
        try writeJsonFieldString(writer, "title", result.title, false);
        try writeJsonFieldString(writer, "expectedBucket", @tagName(result.expected_bucket), false);
        try writeJsonFieldString(writer, "actualBucket", @tagName(result.actual_bucket), false);
        try writer.writeAll(",\"passed\":");
        try writer.writeAll(if (result.passed) "true" else "false");
        try writer.print(",\"durationMs\":{d}", .{result.duration_ms});
        if (result.ghost_status) |value| try writeOptionalStringField(writer, "ghostStatus", value);
        if (result.stop_reason) |value| try writeOptionalStringField(writer, "stopReason", value);
        if (result.cache_lifecycle) |value| try writeOptionalStringField(writer, "cacheLifecycle", value);
        if (result.contradiction_kind) |value| try writeOptionalStringField(writer, "contradictionKind", value);
        if (result.selected_refactor_scope) |value| try writeOptionalStringField(writer, "selectedRefactorScope", value);
        if (result.selected_verification_state) |value| try writeOptionalStringField(writer, "selectedVerificationState", value);
        if (result.unresolved_detail) |value| try writeOptionalStringField(writer, "unresolvedDetail", value);
        try writer.writeAll(",\"support\":{");
        try writer.writeAll("\"complete\":");
        try writer.writeAll(if (result.support_complete) "true" else "false");
        try writer.print(",\"minimumMet\":{s},\"nodeCount\":{d},\"edgeCount\":{d},\"evidenceCount\":{d},\"abstractionRefCount\":{d}", .{
            if (result.support_graph_minimum_met) "true" else "false",
            result.support_node_count,
            result.support_edge_count,
            result.evidence_count,
            result.abstraction_ref_count,
        });
        try writer.writeAll("}");
        try writer.print(",\"routingIndex\":{{\"buildMs\":{d},\"considered\":{d},\"selected\":{d},\"skipped\":{d},\"suppressed\":{d},\"budgetCapHits\":{d}}}", .{
            result.routing_index_build_ms,
            result.routing_considered_count,
            result.routing_selected_count,
            result.routing_skipped_count,
            result.routing_suppressed_count,
            result.routing_budget_cap_hit_count,
        });
        try writer.print(",\"pack\":{{\"candidateSurfaceCount\":{d},\"peakCandidateSurfaceCount\":{d},\"activatedCount\":{d},\"peakActivatedCount\":{d},\"skippedCount\":{d},\"peakSkippedCount\":{d},\"suppressedCount\":{d},\"peakSuppressedCount\":{d},\"conflictRefusedCount\":{d},\"trustBlockedCount\":{d},\"staleBlockedCount\":{d},\"budgetCapsHitCount\":{d},\"localTruthWinCount\":{d},\"mountResolveMs\":{d},\"manifestPreviewLoadMs\":{d},\"routingMs\":{d},\"catalogLoadMs\":{d}}}", .{
            result.pack_candidate_surface_count,
            result.pack_peak_candidate_surface_count,
            result.pack_activated_count,
            result.pack_peak_activated_count,
            result.pack_skipped_count,
            result.pack_peak_skipped_count,
            result.pack_suppressed_count,
            result.pack_peak_suppressed_count,
            result.pack_conflict_refused_count,
            result.pack_trust_blocked_count,
            result.pack_stale_blocked_count,
            result.pack_budget_caps_hit_count,
            result.pack_local_truth_win_count,
            result.pack_mount_resolve_ms,
            result.pack_manifest_preview_load_ms,
            result.pack_routing_ms,
            result.pack_catalog_load_ms,
        });
        try writer.print(",\"compute\":{{\"requestedTier\":\"{s}\",\"effectiveTier\":\"{s}\",\"budgetExhausted\":{s}", .{
            result.requested_compute_tier,
            result.effective_compute_tier,
            if (result.budget_exhausted) "true" else "false",
        });
        if (result.budget_limit) |value| try writeOptionalStringField(writer, "limit", value);
        if (result.budget_stage) |value| try writeOptionalStringField(writer, "stage", value);
        try writer.writeAll("}");
        try writer.writeAll(",\"verification\":{");
        try writer.print("\"verifiedSupportedCount\":{d},\"buildPassed\":{d},\"buildAttempted\":{d},\"testPassed\":{d},\"testAttempted\":{d},\"runtimePassed\":{d},\"runtimeAttempted\":{d},\"adapterRunCount\":{d},\"adapterPassedCount\":{d},\"adapterFailedCount\":{d},\"adapterBlockedCount\":{d},\"adapterSkippedCount\":{d},\"adapterBudgetExhaustionCount\":{d},\"codeVerifierCount\":{d},\"nonCodeVerifierCount\":{d},\"repairPlanCount\":{d},\"repairRecoveredCount\":{d},\"repairFailedCount\":{d},\"retryingCandidateCount\":{d},\"refinementCount\":{d}", .{
            result.verified_supported_count,
            result.build_passed,
            result.build_attempted,
            result.test_passed,
            result.test_attempted,
            result.runtime_passed,
            result.runtime_attempted,
            result.verifier_adapter_run_count,
            result.verifier_adapter_passed_count,
            result.verifier_adapter_failed_count,
            result.verifier_adapter_blocked_count,
            result.verifier_adapter_skipped_count,
            result.verifier_budget_exhaustion_count,
            result.code_verifier_count,
            result.non_code_verifier_count,
            result.repair_plan_count,
            result.repair_recovered_count,
            result.repair_failed_count,
            result.retrying_candidate_count,
            result.refinement_count,
        });
        try writer.writeAll("}");
        try writer.print(",\"tank\":{{\"partialFindingCount\":{d},\"ambiguitySetCount\":{d},\"suppressedNoiseCount\":{d},\"reinforcementEventCount\":{d},\"reinforcementReuseHitCount\":{d},\"proofAdmissionBlockedCount\":{d},\"preservedNovelCount\":{d},\"candidateCount\":{d}}}", .{
            result.partial_finding_count,
            result.ambiguity_set_count,
            result.suppressed_noise_count,
            result.reinforcement_event_count,
            result.reinforcement_reuse_hit_count,
            result.proof_admission_blocked_count,
            result.preserved_novel_count,
            result.candidate_count,
        });
        if (result.task_status) |value| {
            try writer.writeAll(",\"task\":{");
            try writeJsonFieldString(writer, "status", value, true);
            if (result.evidence_state) |state| try writeOptionalStringField(writer, "evidenceState", state);
            try writer.writeAll(",\"replayReady\":");
            try writer.writeAll(if (result.replay_ready) "true" else "false");
            if (result.replay_class) |state| try writeOptionalStringField(writer, "replayClass", state);
            if (result.replay_source) |state| try writeOptionalStringField(writer, "replaySource", state);
            try writer.writeAll("}");
        }
        if (result.cold_duration_ms > 0 or result.warm_duration_ms > 0) {
            try writer.print(",\"coldWarm\":{{\"coldMs\":{d},\"warmMs\":{d},\"coldCacheChangedFiles\":{d},\"warmCacheChangedFiles\":{d}}}", .{
                result.cold_duration_ms,
                result.warm_duration_ms,
                result.cold_cache_changed_files,
                result.warm_cache_changed_files,
            });
        }
        try writeOptionalStringField(writer, "detail", result.detail);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderMarkdownReport(allocator: std.mem.Allocator, metrics: *const Metrics, results: []const CaseResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.print("# Ghost Serious Workflow Benchmarks ({s})\n\n", .{@tagName(builtin.os.tag)});
    try writer.print("- total cases: {d}\n", .{metrics.total_cases});
    try writer.print("- passed cases: {d}\n", .{metrics.passed_cases});
    try writer.print("- failed cases: {d}\n", .{metrics.failed_cases});
    try writer.print("- total benchmark wall time: {d} ms\n", .{metrics.total_benchmark_wall_time_ms});
    try writer.print("- code impact correctness rate: {d}%\n", .{scaledRate(metrics, .code_impact_correctness)});
    try writer.print("- contradiction detection correctness rate: {d}%\n", .{scaledRate(metrics, .contradiction_detection_correctness)});
    try writer.print("- unresolved-vs-unsupported correctness rate: {d}%\n", .{scaledRate(metrics, .unresolved_vs_unsupported_behavior)});
    try writer.print("- minimal-safe-refactor correctness rate: {d}%\n", .{scaledRate(metrics, .minimal_safe_refactor_correctness)});
    try writer.print("- execution-loop handling rate: {d}%\n", .{scaledRate(metrics, .execution_loop_success_failure_handling)});
    try writer.print("- provenance/support completeness rate: {d}%\n", .{scaledSupportRate(metrics)});
    try writer.print("- support/provenance completeness: {d}/{d}\n", .{ metrics.support_complete_cases, metrics.support_relevant_cases });
    try writer.print("- verified-complete workflow rate: {d}%\n", .{scaledRate(metrics, .operator_verified_complete_workflow)});
    try writer.print("- blocked workflow rate: {d}%\n", .{scaledRate(metrics, .operator_blocked_workflow)});
    try writer.print("- unresolved workflow rate: {d}%\n", .{scaledRate(metrics, .operator_unresolved_workflow)});
    try writer.print("- replay-from-task workflow rate: {d}%\n", .{scaledRate(metrics, .operator_replay_workflow)});
    try writer.print("- external-evidence-assisted workflow rate: {d}%\n", .{scaledRate(metrics, .external_evidence_assisted_workflow)});
    try writer.print("- runtime-verified patch workflow rate: {d}%\n", .{scaledRate(metrics, .runtime_verified_patch_workflow)});
    try writer.print("- verified supported patch results: {d}\n", .{metrics.verified_result_count});
    try writer.print("- patch compile-pass rate: {d}% ({d}/{d})\n", .{ scaledFraction(metrics.patch_build_passed, metrics.patch_build_attempted), metrics.patch_build_passed, metrics.patch_build_attempted });
    try writer.print("- test-pass rate: {d}% ({d}/{d})\n", .{ scaledFraction(metrics.patch_test_passed, metrics.patch_test_attempted), metrics.patch_test_passed, metrics.patch_test_attempted });
    try writer.print("- runtime-pass rate: {d}% ({d}/{d})\n", .{ scaledFraction(metrics.patch_runtime_passed, metrics.patch_runtime_attempted), metrics.patch_runtime_passed, metrics.patch_runtime_attempted });
    try writer.print("- verifier adapters: runs={d}, passed={d}, failed={d}, blocked={d}, skipped={d}, budget_exhausted={d}\n", .{
        metrics.verifier_adapter_run_count,
        metrics.verifier_adapter_passed_count,
        metrics.verifier_adapter_failed_count,
        metrics.verifier_adapter_blocked_count,
        metrics.verifier_adapter_skipped_count,
        metrics.verifier_budget_exhaustion_count,
    });
    try writer.print("- verifier domains: code={d}, non_code={d}\n", .{ metrics.code_verifier_count, metrics.non_code_verifier_count });
    try writer.print("- latency per verified result: {d} ms\n", .{avgMs(metrics.total_verified_latency_ms, metrics.verified_result_count)});
    try writer.print("- cold start / warm start: {d} ms / {d} ms\n", .{ metrics.cold_start_ms, metrics.warm_start_ms });
    try writer.print("- cold cache changed files / warm cache changed files: {d} / {d}\n", .{ metrics.cold_cache_changed_files, metrics.warm_cache_changed_files });
    try writer.print("- workflow cases: {d}; passing workflow cases: {d}\n", .{ metrics.workflow_cases, metrics.workflow_passed_cases });
    try writer.print("- task-state distribution: planned={d}, running={d}, blocked={d}, unresolved={d}, verified_complete={d}, failed={d}\n", .{
        metrics.task_state_planned,
        metrics.task_state_running,
        metrics.task_state_blocked,
        metrics.task_state_unresolved,
        metrics.task_state_verified_complete,
        metrics.task_state_failed,
    });
    try writer.print("- replay coverage: {d}/{d} replay workflow case(s) fully replayable\n", .{ metrics.replay_ready_cases, metrics.replay_cases });
    try writer.print("- external evidence outcomes: not_needed={d}, requested={d}, fetched={d}, ingested={d}, conflicting={d}, insufficient={d}\n", .{
        metrics.evidence_state_not_needed,
        metrics.evidence_state_requested,
        metrics.evidence_state_fetched,
        metrics.evidence_state_ingested,
        metrics.evidence_state_conflicting,
        metrics.evidence_state_insufficient,
    });
    try writer.print("- partial-finding preservation rate: {d}% ({d}/{d})\n", .{
        scaledFraction(metrics.partial_finding_preserved_cases, metrics.partial_finding_cases),
        metrics.partial_finding_preserved_cases,
        metrics.partial_finding_cases,
    });
    try writer.print("- ambiguity preservation rate: {d}% ({d}/{d})\n", .{
        scaledFraction(metrics.ambiguity_preserved_cases, metrics.ambiguity_cases),
        metrics.ambiguity_preserved_cases,
        metrics.ambiguity_cases,
    });
    try writer.print("- suppressed-noise count: {d}\n", .{metrics.suppressed_noise_count});
    try writer.print("- reinforcement event count: {d}\n", .{metrics.reinforcement_event_count});
    try writer.print("- reinforcement reuse hit count: {d}\n", .{metrics.reinforcement_reuse_hit_count});
    try writer.print("- reinforcement reuse hit rate after reinforcement: {d}%\n", .{scaledFraction(metrics.reinforcement_reuse_hit_count, metrics.reinforcement_event_count)});
    try writer.print("- draft intent resolution improvement: {d}% measurable event coverage\n", .{scaledFraction(metrics.reinforcement_event_count, metrics.total_cases)});
    try writer.print("- unsupported proof-admission block count: {d}\n", .{metrics.unsupported_proof_admission_block_count});
    try writer.print("- measured repo scan / cache refresh / index materialize: {d} / {d} / {d} ms\n", .{
        metrics.repo_scan_ms,
        metrics.cache_refresh_ms,
        metrics.index_materialize_ms,
    });
    try writer.print("- measured support-aware routing index build: {d} ms; considered / selected / skipped / suppressed / cap_hits: {d} / {d} / {d} / {d} / {d}\n", .{
        metrics.routing_index_build_ms,
        metrics.routing_considered_count,
        metrics.routing_selected_count,
        metrics.routing_skipped_count,
        metrics.routing_suppressed_count,
        metrics.routing_budget_cap_hit_count,
    });
    try writer.print("- discovery signals: retained_token={d}, retained_pattern={d}, schema_entity={d}, schema_relation={d}, obligation={d}, anchor={d}, verifier_hint={d}, fallback_used={d}\n", .{
        metrics.retained_token_signal_count,
        metrics.retained_pattern_signal_count,
        metrics.schema_entity_signal_count,
        metrics.schema_relation_signal_count,
        metrics.obligation_signal_count,
        metrics.anchor_signal_count,
        metrics.verifier_hint_signal_count,
        metrics.fallback_signal_used_count,
    });
    try writer.print("- universal hypotheses: generated={d}, selected={d}, suppressed={d}, budget_hits={d}, rules_fired={d}, code={d}, non_code={d}\n", .{
        metrics.generated_hypothesis_count,
        metrics.selected_hypothesis_count,
        metrics.suppressed_hypothesis_count,
        metrics.hypothesis_generation_budget_hit_count,
        metrics.hypothesis_generation_rules_fired,
        metrics.code_hypothesis_count,
        metrics.non_code_hypothesis_count,
    });
    try writer.print("- hypothesis triage: selected={d}, suppressed={d}, duplicates={d}, budget_hits={d}, selected_code={d}, selected_non_code={d}\n", .{
        metrics.hypothesis_triage_selected_count,
        metrics.hypothesis_triage_suppressed_count,
        metrics.hypothesis_duplicate_count,
        metrics.hypothesis_budget_hit_count,
        metrics.selected_code_hypothesis_count,
        metrics.selected_non_code_hypothesis_count,
    });
    try writer.print("- hypothesis verifier handoff: eligible={d}, scheduled={d}, completed={d}, blocked={d}, skipped={d}, budget_exhausted={d}, code_jobs={d}, non_code_jobs={d}\n", .{
        metrics.hypothesis_verifier_eligible_count,
        metrics.hypothesis_verifier_scheduled_count,
        metrics.hypothesis_verifier_completed_count,
        metrics.hypothesis_verifier_blocked_count,
        metrics.hypothesis_verifier_skipped_count,
        metrics.hypothesis_verifier_budget_exhausted_count,
        metrics.code_hypothesis_verifier_job_count,
        metrics.non_code_hypothesis_verifier_job_count,
    });
    try writer.print("- verifier candidates: proposed={d}, blocked={d}, accepted={d}, materialized={d}, rejected={d}, materialization_blocked={d}, budget_hits={d}, code={d}, non_code={d}\n", .{
        metrics.verifier_candidate_proposed_count,
        metrics.verifier_candidate_blocked_count,
        metrics.verifier_candidate_accepted_count,
        metrics.verifier_candidate_materialized_count,
        metrics.verifier_candidate_rejected_count,
        metrics.verifier_candidate_materialization_blocked_count,
        metrics.verifier_candidate_budget_hit_count,
        metrics.code_verifier_candidate_count,
        metrics.non_code_verifier_candidate_count,
    });
    try writer.print("- measured pack mount resolve / manifest preview load / pack routing / pack catalog load: {d} / {d} / {d} / {d} ms\n", .{
        metrics.pack_mount_resolve_ms,
        metrics.pack_manifest_preview_load_ms,
        metrics.pack_routing_ms,
        metrics.pack_catalog_load_ms,
    });
    try writer.print("- measured pack candidate surfaces / activated packs / skipped packs: {d} / {d} / {d}\n", .{
        metrics.pack_candidate_surface_count,
        metrics.pack_activated_count,
        metrics.pack_skipped_count,
    });
    try writer.print("- measured pack budget cap hits / local-truth wins: {d} / {d}\n", .{
        metrics.pack_budget_caps_hit_count,
        metrics.pack_local_truth_win_count,
    });
    try writer.print("- measured support graph build: {d} ms\n", .{metrics.support_graph_build_ms});
    try writer.print("- response mode distribution: draft={d}, fast={d}, deep={d}\n", .{
        metrics.response_draft_mode_count,
        metrics.response_fast_path_count,
        metrics.response_deep_path_count,
    });
    try writer.print("- measured response mode selection / draft path / fast path / deep path: {d} / {d} / {d} / {d} ms\n", .{
        metrics.response_mode_selection_ms,
        metrics.response_draft_path_ms,
        metrics.response_fast_path_ms,
        metrics.response_deep_path_ms,
    });
    try writer.print("- measured artifact schema pipeline / verifier adapter dispatch: {d} / {d} ms\n", .{
        metrics.artifact_schema_pipeline_ms,
        metrics.verifier_adapter_dispatch_ms,
    });
    try writer.print("- measured artifact json render / persist / panic capture: {d} / {d} / {d} ms\n", .{
        metrics.artifact_json_render_ms,
        metrics.artifact_persist_ms,
        metrics.panic_dump_capture_ms,
    });
    try writer.print("- measured verification workspace / build / test / runtime: {d} / {d} / {d} / {d} ms\n", .{
        metrics.verification_workspace_ms,
        metrics.verification_build_exec_ms,
        metrics.verification_test_exec_ms,
        metrics.verification_runtime_exec_ms,
    });
    try writer.print("- measured task artifact writes: {d} ms across {d} writes\n", .{
        metrics.task_artifact_write_ms,
        metrics.task_artifact_write_count,
    });
    try writer.print("- measured task session saves: {d} ms across {d} saves\n", .{
        metrics.task_session_save_ms,
        metrics.task_session_save_count,
    });
    try writer.writeAll("\nNotes:\n");
    try writer.writeAll("- patch compile-pass and test-pass rates are per attempted candidate verification step, not per benchmark case.\n");
    if (metrics.patch_runtime_attempted == 0) {
        try writer.writeAll("- runtime-pass rate is currently 0/0 because the suite has no positive runtime-verified patch fixture yet, not because runtime execution is failing.\n");
    } else {
        try writer.writeAll("- runtime-pass rate is per attempted bounded runtime-oracle step after build/test verification.\n");
    }
    try writer.writeAll("- cold versus warm cache measurements are reported factually; the suite checks shard-local cache behavior, not a guarantee that warm latency is always lower.\n");
    try appendPackScalingMarkdown(writer, results);

    try writer.writeAll("\n## Case Results\n\n");
    for (results) |result| {
        try writer.print("- `{s}`: {s}; expected `{s}` got `{s}`; tier={s}; pack_caps={d}; local_truth={d}; partials={d}; ambiguities={d}; suppressed_noise={d}; reuse_hits={d}; proof_blocks={d}; {s}\n", .{
            result.id,
            if (result.passed) "pass" else "fail",
            @tagName(result.expected_bucket),
            @tagName(result.actual_bucket),
            result.effective_compute_tier,
            result.pack_budget_caps_hit_count,
            result.pack_local_truth_win_count,
            result.partial_finding_count,
            result.ambiguity_set_count,
            result.suppressed_noise_count,
            result.reinforcement_reuse_hit_count,
            result.proof_admission_blocked_count,
            result.detail,
        });
    }

    if (metrics.failed_cases > 0) {
        try writer.writeAll("\n## Current Gaps\n\n");
        for (results) |result| {
            if (result.passed) continue;
            try writer.print("- `{s}`: {s}\n", .{ result.id, result.detail });
        }
    }

    return out.toOwnedSlice();
}

fn appendPackScalingMarkdown(writer: anytype, results: []const CaseResult) !void {
    const small = findCaseResult(results, "pack_active_runtime_grounding");
    const large = findCaseResult(results, "pack_large_runtime_grounding");
    const low = findCaseResult(results, "pack_large_low_tier_bounded");
    const high = findCaseResult(results, "pack_large_high_tier_bounded");
    const max = findCaseResult(results, "pack_large_max_tier_bounded");

    if (small == null and large == null and low == null and high == null and max == null) return;

    try writer.writeAll("\n## Pack Scaling\n\n");
    if (small != null and large != null) {
        const small_case = small.?;
        const large_case = large.?;
        try writer.print("- small vs large pack manifest preview / routing / catalog load delta: {d} / {d} / {d} ms\n", .{
            signedDelta(large_case.pack_manifest_preview_load_ms, small_case.pack_manifest_preview_load_ms),
            signedDelta(large_case.pack_routing_ms, small_case.pack_routing_ms),
            signedDelta(large_case.pack_catalog_load_ms, small_case.pack_catalog_load_ms),
        });
        try writer.print("- small vs large pack peak candidate surfaces / peak activated / skipped delta: {d} / {d} / {d}\n", .{
            signedDelta(large_case.pack_peak_candidate_surface_count, small_case.pack_peak_candidate_surface_count),
            signedDelta(large_case.pack_peak_activated_count, small_case.pack_peak_activated_count),
            signedDelta(large_case.pack_skipped_count, small_case.pack_skipped_count),
        });
    }
    if (low != null or high != null or max != null) {
        try writer.writeAll("- tier comparison:\n");
        if (low) |case_result| try writer.print("  low -> peak_activated={d}, peak_candidate_surfaces={d}, cap_hits={d}, routing_ms={d}\n", .{
            case_result.pack_peak_activated_count,
            case_result.pack_peak_candidate_surface_count,
            case_result.pack_budget_caps_hit_count,
            case_result.pack_routing_ms,
        });
        if (high) |case_result| try writer.print("  high -> peak_activated={d}, peak_candidate_surfaces={d}, cap_hits={d}, routing_ms={d}\n", .{
            case_result.pack_peak_activated_count,
            case_result.pack_peak_candidate_surface_count,
            case_result.pack_budget_caps_hit_count,
            case_result.pack_routing_ms,
        });
        if (max) |case_result| try writer.print("  max -> peak_activated={d}, peak_candidate_surfaces={d}, cap_hits={d}, routing_ms={d}\n", .{
            case_result.pack_peak_activated_count,
            case_result.pack_peak_candidate_surface_count,
            case_result.pack_budget_caps_hit_count,
            case_result.pack_routing_ms,
        });
    }
}

fn findCaseResult(results: []const CaseResult, id: []const u8) ?*const CaseResult {
    for (results) |*result| {
        if (std.mem.eql(u8, result.id, id)) return result;
    }
    return null;
}

fn signedDelta(current: anytype, baseline: @TypeOf(current)) i64 {
    return @as(i64, @intCast(current)) - @as(i64, @intCast(baseline));
}

fn classifyTaskBucket(status: task_sessions.Status, replay_required: bool, replay_ready: bool) OutcomeBucket {
    if (replay_required) return if (replay_ready) .supported_success else .failed_verification_or_runtime;
    return switch (status) {
        .verified_complete => .supported_success,
        .blocked, .unresolved => .correct_unresolved_or_refused,
        .failed => .failed_verification_or_runtime,
        .planned, .running => .failed_verification_or_runtime,
    };
}

fn taskSupportComplete(session: *const task_sessions.Session) bool {
    const support = session.latest_support orelse return false;
    if (session.status != .verified_complete) return false;
    if (support.permission != .supported or !support.minimum_met) return false;
    if (support.node_count == 0 or support.edge_count == 0 or support.evidence_count == 0) return false;
    if (session.workflow == .patch_candidates) {
        if (support.build_passed == 0 or support.test_passed + support.runtime_passed == 0) return false;
        return support.verified_candidate_count > 0;
    }
    return true;
}

fn fileUrlForPath(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
}

fn patchArtifactContains(allocator: std.mem.Allocator, abs_path: []const u8, pattern: []const u8) !bool {
    const bytes = try std.fs.openFileAbsolute(abs_path, .{});
    defer bytes.close();
    const body = try bytes.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(body);
    return std.mem.indexOf(u8, body, pattern) != null;
}

fn replayClassName(class: panic_dump.ReplayClass) []const u8 {
    return switch (class) {
        .fully_replayable => "fully_replayable",
        .observational_only => "observational_only",
        .insufficient_replay_state => "insufficient_replay_state",
    };
}

fn replaySourceName(source: panic_dump.ReplaySource) []const u8 {
    return switch (source) {
        .none => "none",
        .embedded => "embedded",
        .external_exact => "external_exact",
    };
}

fn parseTaskStatus(text: []const u8) task_sessions.Status {
    if (std.mem.eql(u8, text, "planned")) return .planned;
    if (std.mem.eql(u8, text, "running")) return .running;
    if (std.mem.eql(u8, text, "blocked")) return .blocked;
    if (std.mem.eql(u8, text, "unresolved")) return .unresolved;
    if (std.mem.eql(u8, text, "verified_complete")) return .verified_complete;
    return .failed;
}

fn parseEvidenceState(text: []const u8) external_evidence.AcquisitionState {
    if (std.mem.eql(u8, text, "requested")) return .requested;
    if (std.mem.eql(u8, text, "fetched")) return .fetched;
    if (std.mem.eql(u8, text, "ingested")) return .ingested;
    if (std.mem.eql(u8, text, "conflicting")) return .conflicting;
    if (std.mem.eql(u8, text, "insufficient")) return .insufficient;
    return .not_needed;
}

fn scaledRate(metrics: *const Metrics, tag: Category) u32 {
    return scaledFraction(metrics.category_passed[@intFromEnum(tag)], metrics.category_totals[@intFromEnum(tag)]);
}

fn scaledSupportRate(metrics: *const Metrics) u32 {
    return scaledFraction(metrics.support_complete_cases, metrics.support_relevant_cases);
}

fn scaledFraction(numerator: u32, denominator: u32) u32 {
    if (denominator == 0) return 0;
    return @intCast((@as(u64, numerator) * 100) / denominator);
}

fn avgMs(total_ms: u64, count: u32) u64 {
    if (count == 0) return 0;
    return total_ms / count;
}

fn absolutePath(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    return config.getPath(allocator, rel);
}

fn outputPath(allocator: std.mem.Allocator, ext: []const u8) ![]u8 {
    if (builtin.os.tag == .linux) {
        const rel_path = if (std.mem.eql(u8, ext, "json"))
            repo_hygiene.canonical_linux_benchmark_json
        else
            repo_hygiene.canonical_linux_benchmark_md;
        return config.getPath(allocator, rel_path);
    }

    const file_name = if (std.mem.eql(u8, ext, "json")) "latest.json" else "latest.md";
    const rel_path = try std.fs.path.join(allocator, &.{ repo_hygiene.benchmark_results_rel_dir, file_name });
    defer allocator.free(rel_path);
    return config.getPath(allocator, rel_path);
}

fn writeAbsoluteFile(allocator: std.mem.Allocator, path: []const u8, body: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try sys.makePath(allocator, dir_name);
    const handle = try sys.openForWrite(allocator, path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, body);
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteFileIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |item| allocator.free(item);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |item| try allocator.dupe(u8, item) else null;
}

fn appendFailure(allocator: std.mem.Allocator, failures: *std.ArrayList([]u8), message: []const u8) !void {
    try failures.append(try allocator.dupe(u8, message));
}

fn appendFailuref(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList([]u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try failures.append(try std.fmt.allocPrint(allocator, fmt, args));
}

fn joinFailures(allocator: std.mem.Allocator, failures: []const []u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (failures, 0..) |failure, idx| {
        if (idx != 0) try out.appendSlice("; ");
        try out.appendSlice(failure);
    }
    return out.toOwnedSlice();
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

fn writeJsonFieldString(writer: anytype, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeOptionalStringField(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeTopSelectedHypothesisKindsJson(writer: anytype, counts_by_kind: []const u32) !void {
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (counts_by_kind, 0..) |count, idx| {
        if (count == 0) continue;
        if (emitted != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        const kind: hypothesis_core.HypothesisKind = @enumFromInt(idx);
        try writeJsonFieldString(writer, "kind", hypothesis_core.kindName(kind), true);
        try writer.print(",\"count\":{d}", .{count});
        try writer.writeByte('}');
        emitted += 1;
    }
    try writer.writeByte(']');
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{@as(u8, c)});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}
