const std = @import("std");
const builtin = @import("builtin");
const core = @import("ghost_core");
const code_intel = core.code_intel;
const config = core.config;
const execution = core.execution;
const mc = core.inference;
const patch_candidates = core.patch_candidates;
const shards = core.shards;
const sys = core.sys;

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
    expect_any_refinement: bool = false,
    expect_candidate0_test_failed: bool = false,
    expect_any_retry: bool = false,
    expect_any_build_failed: bool = false,
    expect_abstraction_refs_min: usize = 0,
    expect_selected_scope_smaller_than_expanded: bool = false,
};

const ExecutionCase = struct {
    fixture_rel: []const u8,
    step: execution.Step,
    expect_signal: execution.FailureSignal,
    expect_success: bool = false,
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
    retrying_candidate_count: u32 = 0,
    refinement_count: u32 = 0,
    cold_duration_ms: u64 = 0,
    warm_duration_ms: u64 = 0,
    cold_cache_changed_files: u32 = 0,
    warm_cache_changed_files: u32 = 0,

    fn deinit(self: *CaseResult) void {
        self.allocator.free(self.detail);
        freeOptional(self.allocator, self.ghost_status);
        freeOptional(self.allocator, self.stop_reason);
        freeOptional(self.allocator, self.cache_lifecycle);
        freeOptional(self.allocator, self.contradiction_kind);
        freeOptional(self.allocator, self.selected_refactor_scope);
        freeOptional(self.allocator, self.unresolved_detail);
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
        .metric_tags = &.{ .contradiction_detection_correctness },
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
        .metric_tags = &.{ .contradiction_detection_correctness },
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
        .metric_tags = &.{ .contradiction_detection_correctness },
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
        .metric_tags = &.{ .unresolved_vs_unsupported_behavior },
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
        .metric_tags = &.{ .cold_vs_warm_project_start },
        .expected_bucket = .supported_success,
        .runner = .{ .cold_warm = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/base_service",
            .project_shard = "bench-cold-warm-base-service",
            .query_kind = .impact,
            .target = "src/api/service.zig:compute",
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
        .title = "Execution loop records failed candidates and successful retries",
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
            .expect_candidate0_test_failed = true,
            .expect_any_retry = true,
        } },
    },
    .{
        .id = "patch_refinement_retry",
        .title = "Execution loop records bounded refinement hypotheses",
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
            .expect_any_refinement = true,
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
                .max_candidates = 2,
                .max_files = 2,
                .max_hunks_per_candidate = 2,
                .max_lines_per_hunk = 6,
            },
            .shim_rel = "benchmarks/ghost_serious_workflows/shims/always_fail/bin",
            .expect_status = .unresolved,
            .expect_stop_reason = .low_confidence,
            .expect_refactor_plan_status = .unresolved,
            .expect_any_build_failed = true,
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
        .id = "execution_zig_run_success",
        .title = "Execution harness succeeds on bounded zig run",
        .metric_tags = &.{ .execution_loop_success_failure_handling },
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
        .metric_tags = &.{ .execution_loop_success_failure_handling },
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
        .metric_tags = &.{ .execution_loop_success_failure_handling },
        .expected_bucket = .failed_verification_or_runtime,
        .runner = .{ .execution = .{
            .fixture_rel = "benchmarks/ghost_serious_workflows/fixtures/execution_timeout",
            .step = .{
                .label = "hang_script",
                .kind = .shell,
                .phase = .invariant,
                .argv = &.{ "./scripts/hang.sh" },
                .timeout_ms = 100,
            },
            .expect_signal = .timed_out,
        } },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var results = std.ArrayList(CaseResult).init(allocator);
    defer {
        for (results.items) |*item| item.deinit();
        results.deinit();
    }

    var metrics = Metrics{};

    for (CASES) |spec| {
        const result = try runCase(allocator, spec);
        try results.append(result);
        accumulateMetrics(&metrics, spec, &results.items[results.items.len - 1]);
    }

    const results_dir = try absolutePath(allocator, "benchmarks/ghost_serious_workflows/results");
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

fn runCase(allocator: std.mem.Allocator, spec: CaseSpec) !CaseResult {
    return switch (spec.runner) {
        .code_intel => |case| runCodeIntelCase(allocator, spec, case),
        .cold_warm => |case| runColdWarmCase(allocator, spec, case),
        .patch => |case| runPatchCase(allocator, spec, case),
        .execution => |case| runExecutionCase(allocator, spec, case),
    };
}

fn runCodeIntelCase(allocator: std.mem.Allocator, spec: CaseSpec, case: CodeIntelCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    if (case.project_shard) |project_shard| try clearShardState(allocator, project_shard, .code_intel_only);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture_root,
        .project_shard = case.project_shard,
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

    const actual_bucket = classifyCodeIntelBucket(&result);
    if (actual_bucket != spec.expected_bucket) {
        try appendFailuref(allocator, &failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
    }

    const detail = if (failures.items.len == 0)
        try std.fmt.allocPrint(allocator, "status={s}; evidence={d}; support_nodes={d}", .{
            @tagName(result.status),
            result.evidence.len,
            result.support_graph.nodes.len,
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
    };
}

fn runPatchCase(allocator: std.mem.Allocator, spec: CaseSpec, case: PatchCase) !CaseResult {
    const fixture_root = try absolutePath(allocator, case.fixture_rel);
    defer allocator.free(fixture_root);

    if (case.project_shard) |project_shard| try clearShardState(allocator, project_shard, .full_patch);
    if (case.seed_abstraction_catalog and case.project_shard != null) {
        try seedAbstractions(allocator, case.project_shard.?);
    }
    if (case.shim_rel) |shim_rel| try clearShimState(allocator, shim_rel);

    const shim_path = if (case.shim_rel) |shim_rel|
        try absolutePath(allocator, shim_rel)
    else
        null;
    defer if (shim_path) |path| allocator.free(path);

    const started = sys.getMilliTick();
    var result = try patch_candidates.run(allocator, .{
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
    });
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
    if (case.expect_any_refinement and stats.refinement_count == 0) {
        const summary = try summarizePatchCandidates(allocator, &result);
        defer allocator.free(summary);
        try appendFailuref(allocator, &failures, "expected at least one refinement trace; candidates={s}", .{summary});
    }
    if (case.expect_any_retry and stats.retrying_candidate_count == 0) try appendFailure(allocator, &failures, "expected at least one retrying candidate");
    if (case.expect_any_build_failed and !stats.any_build_failed) try appendFailure(allocator, &failures, "expected at least one build_failed candidate");
    if (case.expect_abstraction_refs_min > result.abstraction_refs.len) try appendFailuref(allocator, &failures, "expected at least {d} abstraction refs", .{case.expect_abstraction_refs_min});

    if (case.expect_candidate0_test_failed) {
        if (result.candidates.len == 0 or result.candidates[0].validation_state != .test_failed) {
            try appendFailure(allocator, &failures, "candidate_1 was expected to fail test verification");
        }
    }
    if (case.expect_selected_scope_smaller_than_expanded) {
        if (!winnerSmallerThanExpanded(&result)) try appendFailure(allocator, &failures, "selected survivor was not smaller than expanded_neighbor_surface");
    }

    const actual_bucket = classifyPatchBucket(&result);
    if (actual_bucket != spec.expected_bucket) {
        try appendFailuref(allocator, &failures, "bucket expected {s} got {s}", .{ @tagName(spec.expected_bucket), @tagName(actual_bucket) });
    }

    const detail = if (failures.items.len == 0)
        try std.fmt.allocPrint(allocator, "status={s}; verified={d}; build={d}/{d}; test={d}/{d}", .{
            @tagName(result.status),
            stats.verified_supported_count,
            stats.build_passed,
            stats.build_attempted,
            stats.test_passed,
            stats.test_attempted,
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
        .retrying_candidate_count = stats.retrying_candidate_count,
        .refinement_count = stats.refinement_count,
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

const PatchStats = struct {
    support_complete: bool,
    verified_supported_count: u32,
    build_attempted: u32,
    build_passed: u32,
    test_attempted: u32,
    test_passed: u32,
    runtime_attempted: u32,
    runtime_passed: u32,
    retrying_candidate_count: u32,
    refinement_count: u32,
    any_build_failed: bool,
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
        .retrying_candidate_count = 0,
        .refinement_count = 0,
        .any_build_failed = false,
    };
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        if (candidate.validation_state == .verified_supported) stats.verified_supported_count += 1;
        if (candidate.validation_state == .build_failed) stats.any_build_failed = true;
        if (candidate.verification.retry_count > 0) stats.retrying_candidate_count += 1;
        stats.refinement_count += @intCast(candidate.verification.refinements.len);
        if (candidate.verification.build.state != .unavailable) {
            stats.build_attempted += 1;
            if (candidate.verification.build.state == .passed) stats.build_passed += 1;
        }
        if (candidate.verification.test_step.state != .unavailable) {
            stats.test_attempted += 1;
            if (candidate.verification.test_step.state == .passed) stats.test_passed += 1;
        }
        if (candidate.verification.runtime_step.state != .unavailable) {
            stats.runtime_attempted += 1;
            if (candidate.verification.runtime_step.state == .passed) stats.runtime_passed += 1;
        }
    }
    return stats;
}

fn winnerSmallerThanExpanded(result: *const patch_candidates.Result) bool {
    var winner_cost: ?u32 = null;
    var expanded_cost: ?u32 = null;

    for (result.candidates) |candidate| {
        if (candidate.validation_state == .verified_supported) {
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
        if (candidate.validation_state != .verified_supported) continue;
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
        if (candidate.validation_state == .build_failed or candidate.validation_state == .test_failed) {
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
    }
}

fn seedAbstractions(allocator: std.mem.Allocator, project_shard: []const u8) !void {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    try sys.makePath(allocator, paths.abstractions_root_abs_path);
    const handle = try sys.openForWrite(allocator, paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, ABSTRACTION_CATALOG);
}

fn clearShimState(allocator: std.mem.Allocator, shim_rel: []const u8) !void {
    const shim_root = try absolutePath(allocator, shim_rel);
    defer allocator.free(shim_root);
    const stamp_path = try std.fs.path.join(allocator, &.{ shim_root, "..", "build_fail_once.stamp" });
    defer allocator.free(stamp_path);
    try deleteFileIfExistsAbsolute(stamp_path);
}

fn accumulateMetrics(metrics: *Metrics, spec: CaseSpec, result: *const CaseResult) void {
    _ = spec;
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

    if (result.actual_bucket == .supported_success and result.support_node_count > 0) {
        metrics.support_relevant_cases += 1;
        if (result.support_complete) metrics.support_complete_cases += 1;
    }

    if (result.cold_duration_ms > 0 or result.warm_duration_ms > 0) {
        metrics.cold_start_ms = result.cold_duration_ms;
        metrics.warm_start_ms = result.warm_duration_ms;
        metrics.cold_cache_changed_files = result.cold_cache_changed_files;
        metrics.warm_cache_changed_files = result.warm_cache_changed_files;
    }
}

fn incrementBucketExpected(metrics: *Metrics, bucket: OutcomeBucket) void {
    switch (bucket) {
        .supported_success => metrics.bucket_expected_supported_success += 1,
        .correct_unresolved_or_refused => metrics.bucket_expected_correct_unresolved_or_refused += 1,
        .failed_verification_or_runtime => metrics.bucket_expected_failed_verification_or_runtime += 1,
    }
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
    try writer.print(",\"codeImpactCorrectnessRate\":{d}", .{scaledRate(metrics, .code_impact_correctness)});
    try writer.print(",\"contradictionDetectionCorrectnessRate\":{d}", .{scaledRate(metrics, .contradiction_detection_correctness)});
    try writer.print(",\"unresolvedVsUnsupportedRate\":{d}", .{scaledRate(metrics, .unresolved_vs_unsupported_behavior)});
    try writer.print(",\"minimalSafeRefactorCorrectnessRate\":{d}", .{scaledRate(metrics, .minimal_safe_refactor_correctness)});
    try writer.print(",\"executionLoopHandlingRate\":{d}", .{scaledRate(metrics, .execution_loop_success_failure_handling)});
    try writer.print(",\"provenanceSupportCompletenessRate\":{d}", .{scaledSupportRate(metrics)});
    try writer.print(",\"patchCompilePassRate\":{d}", .{scaledFraction(metrics.patch_build_passed, metrics.patch_build_attempted)});
    try writer.print(",\"testPassRate\":{d}", .{scaledFraction(metrics.patch_test_passed, metrics.patch_test_attempted)});
    try writer.print(",\"runtimePassRate\":{d}", .{scaledFraction(metrics.patch_runtime_passed, metrics.patch_runtime_attempted)});
    try writer.print(",\"verifiedResultCount\":{d}", .{metrics.verified_result_count});
    try writer.print(",\"latencyPerVerifiedResultMs\":{d}", .{avgMs(metrics.total_verified_latency_ms, metrics.verified_result_count)});
    try writer.print(",\"coldStartMs\":{d}", .{metrics.cold_start_ms});
    try writer.print(",\"warmStartMs\":{d}", .{metrics.warm_start_ms});
    try writer.print(",\"coldCacheChangedFiles\":{d}", .{metrics.cold_cache_changed_files});
    try writer.print(",\"warmCacheChangedFiles\":{d}", .{metrics.warm_cache_changed_files});
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
        try writer.writeAll(",\"verification\":{");
        try writer.print("\"verifiedSupportedCount\":{d},\"buildPassed\":{d},\"buildAttempted\":{d},\"testPassed\":{d},\"testAttempted\":{d},\"runtimePassed\":{d},\"runtimeAttempted\":{d},\"retryingCandidateCount\":{d},\"refinementCount\":{d}", .{
            result.verified_supported_count,
            result.build_passed,
            result.build_attempted,
            result.test_passed,
            result.test_attempted,
            result.runtime_passed,
            result.runtime_attempted,
            result.retrying_candidate_count,
            result.refinement_count,
        });
        try writer.writeAll("}");
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
    try writer.print("- code impact correctness rate: {d}%\n", .{scaledRate(metrics, .code_impact_correctness)});
    try writer.print("- contradiction detection correctness rate: {d}%\n", .{scaledRate(metrics, .contradiction_detection_correctness)});
    try writer.print("- unresolved-vs-unsupported correctness rate: {d}%\n", .{scaledRate(metrics, .unresolved_vs_unsupported_behavior)});
    try writer.print("- minimal-safe-refactor correctness rate: {d}%\n", .{scaledRate(metrics, .minimal_safe_refactor_correctness)});
    try writer.print("- execution-loop handling rate: {d}%\n", .{scaledRate(metrics, .execution_loop_success_failure_handling)});
    try writer.print("- provenance/support completeness rate: {d}%\n", .{scaledSupportRate(metrics)});
    try writer.print("- verified supported patch results: {d}\n", .{metrics.verified_result_count});
    try writer.print("- patch compile-pass rate: {d}% ({d}/{d})\n", .{ scaledFraction(metrics.patch_build_passed, metrics.patch_build_attempted), metrics.patch_build_passed, metrics.patch_build_attempted });
    try writer.print("- test-pass rate: {d}% ({d}/{d})\n", .{ scaledFraction(metrics.patch_test_passed, metrics.patch_test_attempted), metrics.patch_test_passed, metrics.patch_test_attempted });
    try writer.print("- runtime-pass rate: {d}% ({d}/{d})\n", .{ scaledFraction(metrics.patch_runtime_passed, metrics.patch_runtime_attempted), metrics.patch_runtime_passed, metrics.patch_runtime_attempted });
    try writer.print("- latency per verified result: {d} ms\n", .{avgMs(metrics.total_verified_latency_ms, metrics.verified_result_count)});
    try writer.print("- cold start / warm start: {d} ms / {d} ms\n", .{ metrics.cold_start_ms, metrics.warm_start_ms });
    try writer.print("- cold cache changed files / warm cache changed files: {d} / {d}\n", .{ metrics.cold_cache_changed_files, metrics.warm_cache_changed_files });
    try writer.writeAll("\nNotes:\n");
    try writer.writeAll("- patch compile-pass and test-pass rates are per attempted candidate verification step, not per benchmark case.\n");
    try writer.writeAll("- runtime-pass rate is currently 0/0 because the suite has no positive runtime-verified patch fixture yet, not because runtime execution is failing.\n");
    try writer.writeAll("- cold versus warm cache measurements are reported factually; the suite checks shard-local cache behavior, not a guarantee that warm latency is always lower.\n");

    try writer.writeAll("\n## Case Results\n\n");
    for (results) |result| {
        try writer.print("- `{s}`: {s}; expected `{s}` got `{s}`; {s}\n", .{
            result.id,
            if (result.passed) "pass" else "fail",
            @tagName(result.expected_bucket),
            @tagName(result.actual_bucket),
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
    const file_name = if (builtin.os.tag == .linux)
        if (std.mem.eql(u8, ext, "json")) "latest-linux.json" else "latest-linux.md"
    else if (std.mem.eql(u8, ext, "json"))
        "latest.json"
    else
        "latest.md";
    const rel_path = try std.fs.path.join(allocator, &.{ "benchmarks", "ghost_serious_workflows", "results", file_name });
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
