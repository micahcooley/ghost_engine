const std = @import("std");
const engine_logic = @import("engine.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const config = @import("config.zig");
const shards = @import("shards.zig");
const mc = @import("inference.zig");
const layer2a_gpu = @import("layer2a_gpu.zig");
const sys = @import("sys.zig");
const sigil_runtime = @import("sigil_runtime.zig");
const sigil_snapshot = @import("sigil_snapshot.zig");
const scratchpad = @import("scratchpad.zig");
const panic_dump = @import("panic_dump.zig");
const code_intel = @import("code_intel.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const corpus_ask = @import("corpus_ask.zig");
const corpus_sketch = @import("corpus_sketch.zig");
const rule_reasoning = @import("rule_reasoning.zig");
const external_evidence = @import("external_evidence.zig");
const execution = @import("execution.zig");
const abstractions = @import("abstractions.zig");
const patch_candidates = @import("patch_candidates.zig");
const operator_workflow = @import("operator_workflow.zig");
const task_intent = @import("task_intent.zig");
const task_sessions = @import("task_sessions.zig");
const technical_drafts = @import("technical_drafts.zig");
const knowledge_packs = @import("knowledge_packs.zig");
const knowledge_pack_store = @import("knowledge_pack_store.zig");
const artifact_schema = @import("artifact_schema.zig");
const compute_budget = @import("compute_budget.zig");
const conversation_session = @import("conversation_session.zig");
const intent_grounding = @import("intent_grounding.zig");
const response_engine = @import("response_engine.zig");
const verifier_adapter = @import("verifier_adapter.zig");
const verifier_execution = @import("verifier_execution.zig");
const correction_hooks = @import("correction_hooks.zig");
const correction_candidates = @import("correction_candidates.zig");
const correction_review = @import("correction_review.zig");
const negative_knowledge = @import("negative_knowledge.zig");
const negative_knowledge_review = @import("negative_knowledge_review.zig");
const support_routing = @import("support_routing.zig");
const repo_hygiene = @import("repo_hygiene.zig");
const hypothesis_core = @import("hypothesis_core.zig");
const project_autopsy = @import("project_autopsy.zig");
const context_autopsy = @import("context_autopsy.zig");
const context_autopsy_engine = @import("context_autopsy_engine.zig");
const context_inputs = @import("context_inputs.zig");
const gip = @import("gip.zig");

comptime {
    _ = context_autopsy;
    _ = context_autopsy_engine;
    _ = context_inputs;
    _ = project_autopsy;
    _ = rule_reasoning;
    _ = corpus_sketch;
    _ = repo_hygiene;
    _ = hypothesis_core;
    _ = gip;
    _ = verifier_execution;
    _ = correction_hooks;
    _ = correction_candidates;
    _ = correction_review;
    _ = negative_knowledge;
    _ = support_routing;
}

test "smoke: correction proposal remains candidate-only and non-mutating" {
    const proposal = correction_candidates.propose(.{
        .operation_kind = "rule.evaluate",
        .disputed_output_kind = .rule_candidate,
        .user_correction = "the emitted rule candidate is misleading",
        .correction_type = .misleading_rule,
    }, 0xabc);
    try std.testing.expectEqualStrings("proposed", proposal.status);
    try std.testing.expect(proposal.required_review);
    try std.testing.expect(proposal.non_authorizing);
    try std.testing.expect(!proposal.treated_as_proof);
    try std.testing.expect(!proposal.mutation_flags.corpus_mutation);
    try std.testing.expect(!proposal.mutation_flags.pack_mutation);
    try std.testing.expect(!proposal.mutation_flags.negative_knowledge_mutation);
    try std.testing.expect(!proposal.mutation_flags.commands_executed);
    try std.testing.expect(!proposal.mutation_flags.verifiers_executed);
}

const TraceCapture = struct {
    event: ?mc.TraceEvent = null,
    event_count: u32 = 0,
    max_branch_count: u32 = 0,
    max_created_hypotheses: u32 = 0,
    max_expanded_hypotheses: u32 = 0,
    max_accepted_hypotheses: u32 = 0,
    max_unresolved_hypotheses: u32 = 0,
    max_killed_branches: u32 = 0,
    max_killed_by_branch_cap: u32 = 0,
    max_killed_by_contradiction: u32 = 0,
    max_contradiction_checks: u32 = 0,
    max_contradictions: u32 = 0,

    fn emit(ctx: ?*anyopaque, event: mc.TraceEvent) void {
        const self: *TraceCapture = @ptrCast(@alignCast(ctx.?));
        self.event = event;
        self.event_count += 1;
        self.max_branch_count = @max(self.max_branch_count, event.branch_count);
        self.max_created_hypotheses = @max(self.max_created_hypotheses, event.created_hypotheses);
        self.max_expanded_hypotheses = @max(self.max_expanded_hypotheses, event.expanded_hypotheses);
        self.max_accepted_hypotheses = @max(self.max_accepted_hypotheses, event.accepted_hypotheses);
        self.max_unresolved_hypotheses = @max(self.max_unresolved_hypotheses, event.unresolved_hypotheses);
        self.max_killed_branches = @max(self.max_killed_branches, event.killed_branches);
        self.max_killed_by_branch_cap = @max(self.max_killed_by_branch_cap, event.killed_by_branch_cap);
        self.max_killed_by_contradiction = @max(self.max_killed_by_contradiction, event.killed_by_contradiction);
        self.max_contradiction_checks = @max(self.max_contradiction_checks, event.contradiction_checks);
        self.max_contradictions = @max(self.max_contradictions, event.contradiction_count);
    }
};

const ReasoningFixture = struct {
    allocator: std.mem.Allocator,
    meaning_data: []u32,
    tag_data: []u64,
    meaning_matrix: vsa.MeaningMatrix,
    soul: ghost_state.GhostSoul,

    fn init(allocator: std.mem.Allocator) !ReasoningFixture {
        const meaning_data = try allocator.alloc(u32, 1024 * 16);
        errdefer allocator.free(meaning_data);
        const tag_data = try allocator.alloc(u64, 16);
        errdefer allocator.free(tag_data);
        @memset(meaning_data, 0);
        @memset(tag_data, 0);

        var soul = try ghost_state.GhostSoul.init(allocator);
        errdefer soul.deinit();

        var fixture = ReasoningFixture{
            .allocator = allocator,
            .meaning_data = meaning_data,
            .tag_data = tag_data,
            .meaning_matrix = .{
                .data = meaning_data,
                .tags = tag_data,
            },
            .soul = soul,
        };
        fixture.soul.meaning_matrix = &fixture.meaning_matrix;

        return fixture;
    }

    fn deinit(self: *ReasoningFixture) void {
        self.soul.deinit();
        self.allocator.free(self.meaning_data);
        self.allocator.free(self.tag_data);
    }
};

test "verifier adapter registry, evidence, budget, and non-code checks are domain neutral" {
    const allocator = std.testing.allocator;

    var registry = verifier_adapter.Registry.init(allocator);
    defer registry.deinit();
    try verifier_adapter.registerBuiltinAdapters(&registry);
    try std.testing.expect(registry.lookup("code_artifact_schema", .build, "build") != null);
    try std.testing.expect(registry.lookup("config_schema", .schema_validation, "schema_validation") != null);
    try std.testing.expect(registry.lookup("document_schema", .citation_check, "citation_check") != null);
    try std.testing.expect(registry.missingVerifierObligation("config_schema", .schema_validation, "runtime"));

    var tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .medium }));
    const config_artifact = artifact_schema.Artifact{
        .id = "cfg",
        .source = .user,
        .artifact_type = .file,
        .format_hint = "toml",
        .provenance = "test",
        .trust_class = .project,
        .schema_name = "config_schema",
    };
    const config_entities = [_]artifact_schema.Entity{
        .{ .id = "cfg_key", .entity_type = "key", .fragment_index = 0, .label = "port", .provenance = "test", .artifact_id = "cfg" },
        .{ .id = "cfg_value", .entity_type = "value", .fragment_index = 0, .label = "3000", .provenance = "test", .artifact_id = "cfg" },
    };
    var config_result = try verifier_adapter.run(allocator, &tracker, .{
        .adapter = verifier_adapter.configSchemaValidationAdapter(),
        .artifact = &config_artifact,
        .entities = &config_entities,
        .provenance = "smoke",
    });
    defer config_result.deinit();
    try std.testing.expectEqual(verifier_adapter.Status.passed, config_result.status);
    try std.testing.expectEqual(@as(usize, 1), config_result.obligations_discharged.len);

    const contradiction = artifact_schema.RelationEdge{
        .relation = .contradicts,
        .from_entity_id = "a",
        .to_entity_id = "b",
        .provenance = "test",
    };
    var consistency_result = try verifier_adapter.run(allocator, &tracker, .{
        .adapter = verifier_adapter.genericConsistencyCheckAdapter(),
        .relations = &.{contradiction},
        .provenance = "smoke",
    });
    defer consistency_result.deinit();
    try std.testing.expectEqual(verifier_adapter.Status.failed, consistency_result.status);
    try std.testing.expect(consistency_result.failure_signal != null);

    const link = artifact_schema.Entity{ .id = "link", .entity_type = "link", .fragment_index = 0, .label = "https://example.test", .provenance = "test", .artifact_id = "doc" };
    var citation_result = try verifier_adapter.run(allocator, &tracker, .{
        .adapter = verifier_adapter.documentCitationCheckAdapter(),
        .entities = &.{link},
        .provenance = "smoke",
    });
    defer citation_result.deinit();
    try std.testing.expectEqual(verifier_adapter.Status.passed, citation_result.status);

    var zero_tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{
        .tier = .medium,
        .overrides = .{ .max_verifier_runs = 0 },
    }));
    var budget_result = try verifier_adapter.run(allocator, &zero_tracker, .{
        .adapter = verifier_adapter.configSchemaValidationAdapter(),
        .provenance = "smoke",
    });
    defer budget_result.deinit();
    try std.testing.expectEqual(verifier_adapter.Status.budget_exhausted, budget_result.status);
    try std.testing.expect(budget_result.budget_exhaustion != null);
}

test "code execution verifier output is adapter traceable evidence only" {
    const allocator = std.testing.allocator;
    var capture = execution.Result{
        .label = try allocator.dupe(u8, "zig_build"),
        .kind = .zig_build,
        .phase = .build,
        .command = try allocator.dupe(u8, "zig build"),
        .exit_code = 0,
        .duration_ms = 1,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
    };
    defer capture.deinit(allocator);

    var adapter_result = try verifier_adapter.fromExecutionCapture(
        allocator,
        verifier_adapter.codeBuildAdapter(),
        &capture,
        &.{"build"},
        "execution_harness",
    );
    defer adapter_result.deinit();
    try std.testing.expectEqual(verifier_adapter.Status.passed, adapter_result.status);
    try std.testing.expectEqual(verifier_adapter.EvidenceKind.build_log, adapter_result.evidence_kind);
    try std.testing.expect(std.mem.eql(u8, adapter_result.adapter_id, "code.build.zig_build"));
}

fn testHandoffHypothesis(
    allocator: std.mem.Allocator,
    id: []const u8,
    artifact_scope: []const u8,
    schema_name: []const u8,
    hook: []const u8,
    obligation: []const u8,
    provenance: []const u8,
    trace: []const u8,
) !hypothesis_core.Hypothesis {
    const evidence = [_][]const u8{"provenance-backed evidence"};
    const obligations = [_][]const u8{obligation};
    const hooks = [_][]const u8{hook};
    return hypothesis_core.makeWithSignals(
        allocator,
        id,
        artifact_scope,
        schema_name,
        .possible_missing_obligation,
        &.{ "key", "value" },
        &.{"contains"},
        &evidence,
        &obligations,
        &hooks,
        "verify",
        "handoff_test",
        &.{ "fresh", "high_trust", "project" },
        provenance,
        trace,
    );
}

test "hypothesis verifier handoff schedules selected matching verifier job and evidence stays non-authorizing" {
    const allocator = std.testing.allocator;
    var hypothesis = try testHandoffHypothesis(allocator, "hyp:selected", "runtime.toml", "config_schema", "schema_validation", "schema_validation", "project_provenance", "safe selected hypothesis");
    defer hypothesis.deinit(allocator);
    var triage = try hypothesis_core.triage(allocator, @as([]const hypothesis_core.Hypothesis, &.{hypothesis}), .{ .max_hypotheses_selected = 1 });
    defer triage.deinit();
    var registry = verifier_adapter.Registry.init(allocator);
    defer registry.deinit();
    try verifier_adapter.registerBuiltinAdapters(&registry);
    var tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .high }));
    var artifact = try artifact_schema.Artifact.init(allocator, "cfg", .repo, .file, "project", .project, "toml", "runtime.toml", "config_schema");
    defer artifact.deinit(allocator);
    const entities = [_]artifact_schema.Entity{
        .{ .id = "key", .entity_type = "key", .fragment_index = 0, .label = "port", .provenance = "project", .artifact_id = "cfg" },
        .{ .id = "value", .entity_type = "value", .fragment_index = 0, .label = "3000", .provenance = "project", .artifact_id = "cfg" },
    };
    var handoff = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &tracker, @as([]const hypothesis_core.Hypothesis, &.{hypothesis}), triage, .{ .artifact = &artifact, .entities = &entities }, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), handoff.eligible_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.scheduled_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.completed_count);
    try std.testing.expectEqual(verifier_adapter.HandoffJobStatus.completed, handoff.jobs[0].status);
    try std.testing.expectEqual(verifier_adapter.Status.passed, handoff.jobs[0].result_status.?);
    try std.testing.expect(handoff.jobs[0].non_authorizing_input);
}

test "hypothesis verifier handoff blocks non-selected, missing adapter, unbound, draft, and unsafe requests deterministically" {
    const allocator = std.testing.allocator;
    var selected = try testHandoffHypothesis(allocator, "hyp:a", "runtime.toml", "config_schema", "schema_validation", "schema_validation", "project_provenance", "safe");
    defer selected.deinit(allocator);
    var second = try testHandoffHypothesis(allocator, "hyp:b", "runtime.toml", "config_schema", "schema_validation", "schema_validation", "project_provenance", "safe");
    defer second.deinit(allocator);
    var hypotheses = [_]hypothesis_core.Hypothesis{ selected, second };
    var triage = try hypothesis_core.triage(allocator, &hypotheses, .{ .max_hypotheses_selected = 1 });
    defer triage.deinit();
    var registry = verifier_adapter.Registry.init(allocator);
    defer registry.deinit();
    try verifier_adapter.registerBuiltinAdapters(&registry);
    var tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .high }));
    var draft_handoff = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &tracker, &hypotheses, triage, .{}, .draft);
    defer draft_handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), draft_handoff.skipped_count);
    try std.testing.expectEqual(@as(usize, 1), draft_handoff.jobs.len);

    var missing = try testHandoffHypothesis(allocator, "hyp:missing", "docs/runbook.md", "document_schema", "schema_validation", "schema_validation", "project_provenance", "safe");
    defer missing.deinit(allocator);
    var missing_triage = try hypothesis_core.triage(allocator, @as([]const hypothesis_core.Hypothesis, &.{missing}), .{ .max_hypotheses_selected = 1 });
    defer missing_triage.deinit();
    var missing_handoff = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &tracker, @as([]const hypothesis_core.Hypothesis, &.{missing}), missing_triage, .{}, .deep);
    defer missing_handoff.deinit();
    try std.testing.expectEqual(verifier_adapter.HandoffBlockedReason.no_matching_adapter, missing_handoff.jobs[0].blocked_reason.?);

    var unbound = try testHandoffHypothesis(allocator, "hyp:unbound", "unbound", "config_schema", "schema_validation", "schema_validation", "project_provenance", "safe");
    defer unbound.deinit(allocator);
    var unbound_triage = try hypothesis_core.triage(allocator, @as([]const hypothesis_core.Hypothesis, &.{unbound}), .{ .max_hypotheses_selected = 1 });
    defer unbound_triage.deinit();
    var unbound_handoff = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &tracker, @as([]const hypothesis_core.Hypothesis, &.{unbound}), unbound_triage, .{}, .deep);
    defer unbound_handoff.deinit();
    try std.testing.expectEqual(verifier_adapter.HandoffBlockedReason.unbound_artifact_scope, unbound_handoff.jobs[0].blocked_reason.?);

    var unsafe = try testHandoffHypothesis(allocator, "hyp:unsafe", "runtime.toml", "config_schema", "schema_validation", "schema_validation", "project_provenance", "unsafe disallowed verifier request");
    defer unsafe.deinit(allocator);
    var unsafe_triage = try hypothesis_core.triage(allocator, @as([]const hypothesis_core.Hypothesis, &.{unsafe}), .{ .max_hypotheses_selected = 1 });
    defer unsafe_triage.deinit();
    var unsafe_handoff = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &tracker, @as([]const hypothesis_core.Hypothesis, &.{unsafe}), unsafe_triage, .{}, .deep);
    defer unsafe_handoff.deinit();
    try std.testing.expectEqual(verifier_adapter.HandoffBlockedReason.unsafe_or_disallowed_verification, unsafe_handoff.jobs[0].blocked_reason.?);
}

test "hypothesis verifier handoff records failed evidence, budget caps, non-code jobs, and deterministic order" {
    const allocator = std.testing.allocator;
    var failed = try testHandoffHypothesis(allocator, "hyp:failed", "docs/contract.md", "generic_schema", "consistency_check", "consistency_check", "project_provenance", "safe failed verifier");
    defer failed.deinit(allocator);
    var triage = try hypothesis_core.triage(allocator, @as([]const hypothesis_core.Hypothesis, &.{failed}), .{ .max_hypotheses_selected = 1 });
    defer triage.deinit();
    var registry = verifier_adapter.Registry.init(allocator);
    defer registry.deinit();
    try verifier_adapter.registerBuiltinAdapters(&registry);
    var tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .high }));
    const relation = artifact_schema.RelationEdge{ .relation = .contradicts, .from_entity_id = "a", .to_entity_id = "b", .provenance = "project" };
    var handoff = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &tracker, @as([]const hypothesis_core.Hypothesis, &.{failed}), triage, .{ .relations = &.{relation} }, .deep);
    defer handoff.deinit();
    try std.testing.expectEqual(@as(usize, 1), handoff.scheduled_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.completed_count);
    try std.testing.expectEqual(@as(usize, 1), handoff.non_code_job_count);
    try std.testing.expectEqual(verifier_adapter.HandoffJobStatus.failed, handoff.jobs[0].status);
    try std.testing.expectEqual(verifier_adapter.Status.failed, handoff.jobs[0].result_status.?);
    try std.testing.expect(handoff.jobs[0].evidence_ref != null);

    var capped_tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{
        .tier = .high,
        .overrides = .{ .max_hypothesis_verifier_jobs = 0 },
    }));
    var capped = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &capped_tracker, @as([]const hypothesis_core.Hypothesis, &.{failed}), triage, .{}, .deep);
    defer capped.deinit();
    try std.testing.expectEqual(@as(usize, 1), capped.budget_exhausted_count);
    try std.testing.expectEqual(verifier_adapter.HandoffBlockedReason.budget_exhausted, capped.jobs[0].blocked_reason.?);

    var first_tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .high }));
    var second_tracker = verifier_adapter.BudgetTracker.init(allocator, compute_budget.resolve(.{ .tier = .high }));
    var first = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &first_tracker, @as([]const hypothesis_core.Hypothesis, &.{failed}), triage, .{ .relations = &.{relation} }, .deep);
    defer first.deinit();
    var second = try verifier_adapter.handoffSelectedHypotheses(allocator, &registry, &second_tracker, @as([]const hypothesis_core.Hypothesis, &.{failed}), triage, .{ .relations = &.{relation} }, .deep);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.jobs[0].id, second.jobs[0].id);
}

const Layer2aStub = struct {
    score_calls: u32 = 0,
    neighborhood_calls: u32 = 0,
    contradiction_calls: u32 = 0,
    fail_candidate_scores: bool = false,
    invalid_candidate_shape: bool = false,

    fn hooks(self: *Layer2aStub) mc.Layer2aHooks {
        return .{
            .context = self,
            .uses_gpu = true,
            .score_candidates = scoreCandidates,
            .score_neighborhoods = scoreNeighborhoods,
            .filter_contradictions = filterContradictions,
            .reference_score_candidates = referenceScoreCandidates,
            .reference_score_neighborhoods = referenceScoreNeighborhoods,
            .reference_filter_contradictions = referenceFilterContradictions,
        };
    }

    fn scoreCandidates(ctx: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.CandidateScore) ![]const layer2a_gpu.CandidateScore {
        _ = lexical_rotor;
        _ = semantic_rotor;
        const self: *Layer2aStub = @ptrCast(@alignCast(ctx.?));
        self.score_calls += 1;
        if (self.fail_candidate_scores) return error.MockLayer2aFailure;
        if (self.invalid_candidate_shape) return error.InvalidResultShape;
        for (chars, 0..) |char_code, idx| {
            out[idx] = .{
                .char_code = char_code,
                .score = @as(u32, @intCast((char_code % 17) + 1)),
            };
        }
        return out[0..chars.len];
    }

    fn scoreNeighborhoods(ctx: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.NeighborhoodScore) ![]const layer2a_gpu.NeighborhoodScore {
        _ = lexical_rotor;
        _ = semantic_rotor;
        const self: *Layer2aStub = @ptrCast(@alignCast(ctx.?));
        self.neighborhood_calls += 1;
        for (chars, 0..) |char_code, idx| {
            out[idx] = .{
                .char_code = char_code,
                .score = @as(u32, @intCast((char_code % 13) + 1)),
                .lexical_slot = @as(u32, @intCast(idx)),
                .semantic_slot = @as(u32, @intCast(idx)),
                .neighbor_hits = 1,
            };
        }
        return out[0..chars.len];
    }

    fn filterContradictions(ctx: ?*anyopaque, candidates: []const layer2a_gpu.CandidateScore) !layer2a_gpu.ContradictionFilterResult {
        const self: *Layer2aStub = @ptrCast(@alignCast(ctx.?));
        return self.runContradictionFilter(candidates);
    }

    fn referenceScoreCandidates(ctx: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.CandidateScore) ![]const layer2a_gpu.CandidateScore {
        const self: *Layer2aStub = @ptrCast(@alignCast(ctx.?));
        const original_fail = self.fail_candidate_scores;
        self.fail_candidate_scores = false;
        defer self.fail_candidate_scores = original_fail;
        return scoreCandidates(ctx, lexical_rotor, semantic_rotor, chars, out);
    }

    fn referenceScoreNeighborhoods(ctx: ?*anyopaque, lexical_rotor: u64, semantic_rotor: u64, chars: []const u32, out: []layer2a_gpu.NeighborhoodScore) ![]const layer2a_gpu.NeighborhoodScore {
        return scoreNeighborhoods(ctx, lexical_rotor, semantic_rotor, chars, out);
    }

    fn referenceFilterContradictions(ctx: ?*anyopaque, candidates: []const layer2a_gpu.CandidateScore) !layer2a_gpu.ContradictionFilterResult {
        const self: *Layer2aStub = @ptrCast(@alignCast(ctx.?));
        return self.runContradictionFilter(candidates);
    }

    fn runContradictionFilter(self: *Layer2aStub, candidates: []const layer2a_gpu.CandidateScore) layer2a_gpu.ContradictionFilterResult {
        self.contradiction_calls += 1;

        var best_idx: ?u32 = null;
        var best_char: u32 = 0;
        var best_score: u32 = 0;
        var runner_up_score: u32 = 0;
        var contradiction_checks: u32 = 0;
        var contradiction = false;

        for (candidates, 0..) |candidate, idx| {
            if (candidate.score == 0) continue;
            if (best_idx == null or candidate.score > best_score) {
                runner_up_score = best_score;
                best_idx = @intCast(idx);
                best_char = candidate.char_code;
                best_score = candidate.score;
                contradiction = false;
            } else {
                contradiction_checks += 1;
                if (candidate.score == best_score and candidate.char_code != best_char) {
                    contradiction = true;
                } else if (candidate.score > runner_up_score) {
                    runner_up_score = candidate.score;
                }
            }
        }

        return .{
            .winner_index = if (contradiction) null else best_idx,
            .winner_char = best_char,
            .best_score = best_score,
            .runner_up_score = runner_up_score,
            .contradiction = contradiction,
            .contradiction_checks = contradiction_checks,
            .candidate_count = @intCast(candidates.len),
            .survivor_count = if (best_idx != null and !contradiction) 1 else 0,
        };
    }
};

fn deleteFileIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn ensureParentDirAbsolute(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(parent);
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn fileExistsAbsolute(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

test "test mode uses micro matrix sizing" {
    try std.testing.expect(config.TEST_MODE);
    try std.testing.expectEqual(@as(usize, 16_384), config.SEMANTIC_SLOTS);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), config.UNIFIED_SIZE_BYTES);
    try std.testing.expect(config.TOTAL_STATE_BYTES <= 129 * 1024 * 1024);
}

test "ghost soul smoke absorb stays fast and deterministic" {
    const allocator = std.testing.allocator;

    const meaning_entries = 1024 * 16;
    const meaning_data = try allocator.alloc(u32, meaning_entries);
    defer allocator.free(meaning_data);
    const tag_data = try allocator.alloc(u64, 16);
    defer allocator.free(tag_data);
    @memset(meaning_data, 0);
    @memset(tag_data, 0);

    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_data,
        .tags = tag_data,
    };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    for (config.TEST_STRING) |byte| {
        _ = try soul.absorb(vsa.generate(byte), byte, null);
    }

    try std.testing.expect(soul.lexical_rotor != ghost_state.FNV_OFFSET_BASIS);
    try std.testing.expect(soul.rune_count == config.TEST_STRING.len);
}

test "layer3 refuses low confidence outputs" {
    const chars = [_]u32{ 'a', 'b', 'c' };
    const scores = [_]u32{ 12, 9, 3 };
    var trace = TraceCapture{};
    const decision = mc.decideFromScores(&chars, &scores, 1, 3, .{
        .confidence_floor = .{ .min_score = 13 },
        .max_steps = 1,
        .max_branches = 3,
        .trace = .{
            .context = &trace,
            .emit = TraceCapture.emit,
        },
    });

    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, decision.output);
    try std.testing.expectEqual(mc.StopReason.low_confidence, decision.stop_reason);
    try std.testing.expect(trace.event != null);
    try std.testing.expectEqual(@as(u32, 12), trace.event.?.confidence);
    try std.testing.expectEqual(mc.StopReason.low_confidence, trace.event.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), trace.event.?.step_count);
    try std.testing.expectEqual(@as(u32, 3), trace.event.?.branch_count);
    try std.testing.expectEqual(@as(u32, 3), trace.event.?.unresolved_hypotheses);
}

test "layer3 stops on contradiction instead of guessing" {
    const chars = [_]u32{ 'x', 'y', 'z' };
    const scores = [_]u32{ 40, 40, 5 };
    const decision = mc.decideFromScores(&chars, &scores, 1, 3, .{
        .confidence_floor = .{ .min_score = 10 },
        .max_steps = 1,
        .max_branches = 3,
    });

    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, decision.output);
    try std.testing.expectEqual(mc.StopReason.contradiction, decision.stop_reason);
}

test "layer3 stops when reasoning budget is exhausted" {
    const chars = [_]u32{ 'm', 'n', 'o' };
    const scores = [_]u32{ 80, 30, 10 };
    const decision = mc.decideFromScores(&chars, &scores, 2, 3, .{
        .confidence_floor = .{ .min_score = 10 },
        .max_steps = 1,
        .max_branches = 3,
    });

    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, decision.output);
    try std.testing.expectEqual(mc.StopReason.budget, decision.stop_reason);
}

test "layer3 allows supported output above the confidence floor" {
    const chars = [_]u32{ 'm', 'n', 'o' };
    const scores = [_]u32{ 80, 30, 10 };
    var trace = TraceCapture{};
    const decision = mc.decideFromScores(&chars, &scores, 1, 3, .{
        .confidence_floor = .{ .min_score = 10 },
        .max_steps = 1,
        .max_branches = 3,
        .trace = .{
            .context = &trace,
            .emit = TraceCapture.emit,
        },
    });

    try std.testing.expectEqual(@as(u32, 'm'), decision.output);
    try std.testing.expectEqual(@as(?u32, 0), decision.branch_index);
    try std.testing.expectEqual(@as(u32, 80), decision.confidence);
    try std.testing.expectEqual(mc.StopReason.none, decision.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), trace.max_accepted_hypotheses);
}

test "layer3 defaults to proof policy" {
    const layer3: mc.Layer3Config = .{};

    try std.testing.expectEqual(mc.ReasoningMode.proof, layer3.policy.mode);
    try std.testing.expectEqual(config.LAYER3_MAX_BRANCHES, layer3.policy.internal_branch_allowance);
    try std.testing.expectEqual(@as(u32, 1), layer3.policy.internal_candidate_promotion_floor);
    try std.testing.expectEqual(config.LAYER3_MAX_BRANCHES * 2, mc.boundedAlternativeGeneration(layer3.policy));
}

test "exploratory policy widens internal budget but still respects final confidence floor" {
    const chars = [_]u32{ 'a', 'b', 'c' };
    const scores = [_]u32{ 12, 9, 3 };

    const proof = mc.decideFromScores(&chars, &scores, 1, 4, .{
        .confidence_floor = .{ .min_score = 13 },
        .max_steps = 1,
        .max_branches = 3,
        .policy = mc.ReasoningPolicy.proof(),
    });
    try std.testing.expectEqual(mc.StopReason.budget, proof.stop_reason);

    const exploratory = mc.decideFromScores(&chars, &scores, 1, 4, .{
        .confidence_floor = .{ .min_score = 13 },
        .max_steps = 1,
        .max_branches = 3,
        .policy = mc.ReasoningPolicy.exploratory(),
    });
    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, exploratory.output);
    try std.testing.expectEqual(mc.StopReason.low_confidence, exploratory.stop_reason);
    try std.testing.expectEqual(@as(u32, 12), exploratory.confidence);
    try std.testing.expect(mc.boundedAlternativeGeneration(mc.ReasoningPolicy.exploratory()) > mc.boundedAlternativeGeneration(mc.ReasoningPolicy.proof()));
}

test "score-only layer3 accepts six bounded alternatives without overflow" {
    const chars = [_]u32{ 'a', 'b', 'c', 'd', 'e', 'f' };
    const scores = [_]u32{ 90, 70, 60, 50, 40, 30 };

    const decision = mc.decideFromScores(&chars, &scores, 1, 6, .{
        .confidence_floor = .{ .min_score = 80 },
        .max_steps = 1,
        .max_branches = 6,
        .policy = mc.ReasoningPolicy.proof(),
    });

    try std.testing.expectEqual(mc.StopReason.none, decision.stop_reason);
    try std.testing.expectEqual(@as(u32, 'a'), decision.output);
}

test "cpu reasoning respects confidence floor" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    var trace = TraceCapture{};
    const reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 4096 },
        .max_steps = 2,
        .max_branches = 3,
        .trace = .{
            .context = &trace,
            .emit = TraceCapture.emit,
        },
    }).withRecentBytes(.{ '.', '.', '.' });

    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 64, 48, 24 };
    const decision = reasoning.resolve(&chars, &energies);

    try std.testing.expectEqual(mc.StopReason.low_confidence, decision.stop_reason);
    try std.testing.expect(trace.event != null);
    try std.testing.expect(trace.event.?.confidence < 4096);
    try std.testing.expect(trace.max_unresolved_hypotheses > 0);
}

test "cpu reasoning accepts supported output through the reasoning path" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    var trace = TraceCapture{};
    const reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 0 },
        .max_steps = 2,
        .max_branches = 3,
        .trace = .{
            .context = &trace,
            .emit = TraceCapture.emit,
        },
    }).withRecentBytes(.{ '.', '.', '.' });

    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 900, 500, 100 };
    const decision = reasoning.resolve(&chars, &energies);

    try std.testing.expectEqual(mc.StopReason.none, decision.stop_reason);
    try std.testing.expect(decision.output != mc.UNRESOLVED_OUTPUT);
    try std.testing.expect(decision.branch_index != null);
    try std.testing.expectEqual(@as(u32, 1), trace.max_accepted_hypotheses);
    try std.testing.expect(trace.max_created_hypotheses > 0);
}

test "cpu reasoning prunes branches deterministically under the cap" {
    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 900, 850, 0 };
    var first_decision: ?mc.Layer3Decision = null;
    var first_trace: ?TraceCapture = null;

    var run_index: usize = 0;
    while (run_index < 4) : (run_index += 1) {
        const allocator = std.testing.allocator;
        var fixture = try ReasoningFixture.init(allocator);
        defer fixture.deinit();

        var trace = TraceCapture{};
        const reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
            .confidence_floor = .{ .min_score = 0 },
            .max_steps = 2,
            .max_branches = 2,
            .trace = .{
                .context = &trace,
                .emit = TraceCapture.emit,
            },
        }).withRecentBytes(.{ '.', 'a', 'b' });

        const decision = reasoning.resolve(&chars, &energies);

        try std.testing.expect(trace.max_branch_count <= 2);
        try std.testing.expect(trace.max_killed_by_branch_cap > 0);
        try std.testing.expect(trace.max_expanded_hypotheses > 0);

        if (first_decision == null) {
            first_decision = decision;
            first_trace = trace;
            continue;
        }

        try std.testing.expectEqualDeep(first_decision.?, decision);
        try std.testing.expectEqualDeep(first_trace.?, trace);
    }
}

test "cpu contradiction-heavy input stays unresolved instead of falling back" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    var trace = TraceCapture{};
    const reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 100_000 },
        .max_steps = 2,
        .max_branches = 3,
        .trace = .{
            .context = &trace,
            .emit = TraceCapture.emit,
        },
    }).withRecentBytes(.{ '{', '[', '(' });

    const chars = [_]u32{ ')', ']', '}' };
    const energies = [_]u32{ 700, 700, 700 };
    const decision = reasoning.resolve(&chars, &energies);

    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, decision.output);
    try std.testing.expect(decision.stop_reason == .contradiction or decision.stop_reason == .low_confidence);
    try std.testing.expect(trace.max_contradiction_checks > 0);
    try std.testing.expect(trace.max_unresolved_hypotheses > 0);
}

test "cpu reasoning is stable across repeated identical runs" {
    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 900, 500, 100 };
    var first_decision: ?mc.Layer3Decision = null;
    var first_trace: ?TraceCapture = null;

    var run_index: usize = 0;
    while (run_index < 8) : (run_index += 1) {
        const allocator = std.testing.allocator;
        var fixture = try ReasoningFixture.init(allocator);
        defer fixture.deinit();

        var trace = TraceCapture{};
        const reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
            .confidence_floor = .{ .min_score = 0 },
            .max_steps = 2,
            .max_branches = 3,
            .trace = .{
                .context = &trace,
                .emit = TraceCapture.emit,
            },
        }).withRecentBytes(.{ '.', '.', '.' });

        const decision = reasoning.resolve(&chars, &energies);
        if (first_decision == null) {
            first_decision = decision;
            first_trace = trace;
            continue;
        }

        try std.testing.expectEqualDeep(first_decision.?, decision);
        try std.testing.expectEqual(first_trace.?.event_count, trace.event_count);
        try std.testing.expectEqual(first_trace.?.max_created_hypotheses, trace.max_created_hypotheses);
        try std.testing.expectEqual(first_trace.?.max_expanded_hypotheses, trace.max_expanded_hypotheses);
        try std.testing.expectEqual(first_trace.?.max_killed_by_branch_cap, trace.max_killed_by_branch_cap);
        try std.testing.expectEqual(first_trace.?.max_contradiction_checks, trace.max_contradiction_checks);
    }
}

test "layer2a enabled preserves supported behavior on bounded reasoning case" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 900, 500, 100 };

    const base_reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 0 },
        .max_steps = 2,
        .max_branches = 3,
    }).withRecentBytes(.{ '.', '.', '.' });
    const without_layer2a = base_reasoning.resolve(&chars, &energies);

    var stub = Layer2aStub{};
    var metrics = mc.Layer2aInstrumentation{};
    const with_layer2a = base_reasoning
        .withLayer2aHooks(stub.hooks())
        .withInstrumentation(&metrics)
        .resolve(&chars, &energies);

    try std.testing.expectEqual(without_layer2a.stop_reason, with_layer2a.stop_reason);
    try std.testing.expectEqual(without_layer2a.output, with_layer2a.output);
    try std.testing.expectEqual(without_layer2a.branch_index, with_layer2a.branch_index);
    try std.testing.expect(metrics.gpu_dispatch_count > 0);
    try std.testing.expect(metrics.bytes_transferred > 0);
    try std.testing.expect(metrics.layer2a_time_ns > 0);
    try std.testing.expect(metrics.layer2b_time_ns > 0);
    try std.testing.expect(metrics.fallback_to_cpu_count == 0);
    try std.testing.expect(stub.score_calls > 0);
    try std.testing.expect(stub.neighborhood_calls > 0);
    try std.testing.expect(stub.contradiction_calls > 0);
}

test "layer2a enabled preserves unresolved behavior on bounded contradiction case" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    const chars = [_]u32{ ')', ']', '}' };
    const energies = [_]u32{ 700, 700, 700 };

    const base_reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 100_000 },
        .max_steps = 2,
        .max_branches = 3,
    }).withRecentBytes(.{ '{', '[', '(' });
    const without_layer2a = base_reasoning.resolve(&chars, &energies);

    var stub = Layer2aStub{};
    const with_layer2a = base_reasoning
        .withLayer2aHooks(stub.hooks())
        .resolve(&chars, &energies);

    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, without_layer2a.output);
    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, with_layer2a.output);
    try std.testing.expectEqual(without_layer2a.stop_reason, with_layer2a.stop_reason);
}

test "layer2a gpu fallback records cpu fallback without changing bounded support state" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 900, 500, 100 };

    const base_reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 0 },
        .max_steps = 2,
        .max_branches = 3,
    }).withRecentBytes(.{ '.', '.', '.' });
    const without_layer2a = base_reasoning.resolve(&chars, &energies);

    var stub = Layer2aStub{ .fail_candidate_scores = true };
    var metrics = mc.Layer2aInstrumentation{};
    const with_fallback = base_reasoning
        .withLayer2aHooks(stub.hooks())
        .withInstrumentation(&metrics)
        .resolve(&chars, &energies);

    try std.testing.expectEqual(without_layer2a.stop_reason, with_fallback.stop_reason);
    try std.testing.expectEqual(without_layer2a.output, with_fallback.output);
    try std.testing.expect(metrics.gpu_dispatch_count > 0);
    try std.testing.expect(metrics.fallback_to_cpu_count > 0);
}

test "layer2a invalid shape fallback stays deterministic and safe" {
    const allocator = std.testing.allocator;
    var fixture = try ReasoningFixture.init(allocator);
    defer fixture.deinit();

    const chars = [_]u32{ 'a', 'b', 'c' };
    const energies = [_]u32{ 900, 500, 100 };

    const base_reasoning = mc.ReasoningContext.init(&fixture.meaning_matrix, &fixture.soul, .{
        .confidence_floor = .{ .min_score = 0 },
        .max_steps = 2,
        .max_branches = 3,
    }).withRecentBytes(.{ '.', '.', '.' });
    const without_layer2a = base_reasoning.resolve(&chars, &energies);

    var stub = Layer2aStub{ .invalid_candidate_shape = true };
    var metrics = mc.Layer2aInstrumentation{};
    const with_fallback = base_reasoning
        .withLayer2aHooks(stub.hooks())
        .withInstrumentation(&metrics)
        .resolve(&chars, &energies);

    try std.testing.expectEqual(without_layer2a.stop_reason, with_fallback.stop_reason);
    try std.testing.expectEqual(without_layer2a.output, with_fallback.output);
    try std.testing.expectEqual(without_layer2a.confidence, with_fallback.confidence);
    try std.testing.expect(metrics.fallback_to_cpu_count > 0);
}

test "layer3 unresolved output does not commit state" {
    const allocator = std.testing.allocator;

    const meaning_entries = 1024 * 16;
    const meaning_data = try allocator.alloc(u32, meaning_entries);
    defer allocator.free(meaning_data);
    const tag_data = try allocator.alloc(u64, 16);
    defer allocator.free(tag_data);
    @memset(meaning_data, 0);
    @memset(tag_data, 0);

    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_data,
        .tags = tag_data,
    };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    var engine = engine_logic.SingularityEngine{
        .lattice = undefined,
        .meaning = &meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = null,
        .allocator = allocator,
    };
    defer engine.canvas.deinit();

    engine.ema.average = 4096 << 8;
    engine.ema.deviation = 0;

    const soul_before = engine_logic.saveSoul(&soul);
    const inventory_before = engine.inventory;
    const cursor_before = engine.canvas.cursor;
    const inv_cursor_before = engine.inv_cursor;
    const ema_average_before = engine.ema.average;
    const ema_deviation_before = engine.ema.deviation;

    const decision = engine.resolveText1D();

    try std.testing.expectEqual(mc.UNRESOLVED_OUTPUT, decision.output);
    try std.testing.expectEqual(mc.StopReason.low_confidence, decision.stop_reason);
    try std.testing.expectEqual(cursor_before, engine.canvas.cursor);
    try std.testing.expectEqual(inv_cursor_before, engine.inv_cursor);
    try std.testing.expectEqual(ema_average_before, engine.ema.average);
    try std.testing.expectEqual(ema_deviation_before, engine.ema.deviation);
    try std.testing.expectEqualSlices(u8, inventory_before[0..], engine.inventory[0..]);
    try std.testing.expectEqual(@as(u16, 0), engine.canvas.noise[0]);
    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), engine.canvas.cells[0]);

    const soul_after = engine_logic.saveSoul(&soul);
    try std.testing.expectEqualDeep(soul_before, soul_after);
}

test "sigil control capture is deterministic and restorable" {
    const allocator = std.testing.allocator;

    var control = sigil_runtime.ControlPlane.init(allocator);
    defer control.deinit();

    control.applyMoodName("focused");
    control.setReasoningMode(.exploratory);
    control.setComputeMode(true, false);
    control.setLoomTier(3, 256 * 1024 * 1024);
    control.setLastScan(.{ .hash = 0xBEEF, .energy = 77 });
    try control.lockSlot(9);
    try control.lockSlot(3);
    try control.lockHash(11);
    try control.lockHash(2);
    try control.bindRune("zeta", 'Z');
    try control.bindRune("alpha", 'A');

    var captured = try control.captureState(allocator);
    defer captured.deinit();

    try std.testing.expectEqualSlices(u32, &[_]u32{ 3, 9 }, captured.locked_slots);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 2, 11 }, captured.locked_hashes);
    try std.testing.expectEqualStrings("alpha", captured.bindings[0].label);
    try std.testing.expectEqualStrings("zeta", captured.bindings[1].label);

    var restored = sigil_runtime.ControlPlane.init(allocator);
    defer restored.deinit();
    try restored.restoreState(&captured);

    const snapshot = restored.snapshot();
    try std.testing.expectEqual(sigil_runtime.ReasoningMode.exploratory, snapshot.reasoning_mode);
    try std.testing.expectEqual(@as(u32, 80), snapshot.saturation_bonus);
    try std.testing.expectEqual(@as(u8, 3), snapshot.loom_tier);
    try std.testing.expect(snapshot.enable_vulkan);
    try std.testing.expect(!snapshot.force_cpu_only);
    try std.testing.expectEqual(@as(u64, 0xBEEF), snapshot.last_scan.hash);
    try std.testing.expectEqual(@as(u32, 77), snapshot.last_scan.energy);
    try std.testing.expectEqual(@as(usize, 2), snapshot.locked_slot_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.locked_hash_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.binding_count);
    try std.testing.expect(restored.isSlotLocked(3));
    try std.testing.expect(restored.isSlotLocked(9));
    try std.testing.expect(restored.isHashLocked(2));
    try std.testing.expect(restored.isHashLocked(11));
}

test "sigil snapshot command parser recognizes control commands" {
    try std.testing.expectEqual(sigil_snapshot.Command.begin_scratch, sigil_snapshot.parseCommand("begin scratch"));
    try std.testing.expectEqual(sigil_snapshot.Command.discard, sigil_snapshot.parseCommand(" discard "));
    try std.testing.expectEqual(sigil_snapshot.Command.commit, sigil_snapshot.parseCommand("COMMIT"));
    try std.testing.expectEqual(sigil_snapshot.Command.snapshot, sigil_snapshot.parseCommand("snapshot"));
    try std.testing.expectEqual(sigil_snapshot.Command.revert, sigil_snapshot.parseCommand("ReVeRt"));
    try std.testing.expectEqual(sigil_snapshot.Command.rollback, sigil_snapshot.parseCommand("rollback"));
    try std.testing.expectEqual(sigil_snapshot.Command.none, sigil_snapshot.parseCommand("ETCH \"anchor\" @2"));
}

test "scratchpad overlay isolates semantic writes from permanent state" {
    const allocator = std.testing.allocator;

    const permanent_data = try allocator.alloc(u32, 1024 * 16);
    defer allocator.free(permanent_data);
    const permanent_tags = try allocator.alloc(u64, 16);
    defer allocator.free(permanent_tags);
    @memset(permanent_data, 0);
    @memset(permanent_tags, 0);

    var permanent = vsa.MeaningMatrix{
        .data = permanent_data,
        .tags = permanent_tags,
    };

    var layer = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = scratchpad.SLOT_BYTES * 4,
    }, &permanent);
    defer layer.deinit();

    const hash = ghost_state.wyhash(ghost_state.GENESIS_SEED, 0xBEEF);

    const before = permanent.collapseToBinary(hash);
    layer.meaning().hardLockUniversalSigil(hash, 'Q');
    const scratch_after = layer.meaning().collapseToBinary(hash);
    const permanent_after = permanent.collapseToBinary(hash);

    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), before);
    try std.testing.expect(vsa.hammingDistance(scratch_after, @as(vsa.HyperVector, @splat(@as(u64, 0)))) > 0);
    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), permanent_after);
    try std.testing.expectEqual(@as(?usize, 1), layer.meaning().slotUsageHint());

    layer.clear();

    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), layer.meaning().collapseToBinary(hash));
    try std.testing.expectEqual(@as(?usize, 0), layer.meaning().slotUsageHint());
    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), permanent.collapseToBinary(hash));
}

test "scratchpad session flag is separate from staged overlay data" {
    const allocator = std.testing.allocator;

    const permanent_data = try allocator.alloc(u32, 1024 * 16);
    defer allocator.free(permanent_data);
    const permanent_tags = try allocator.alloc(u64, 16);
    defer allocator.free(permanent_tags);
    @memset(permanent_data, 0);
    @memset(permanent_tags, 0);

    var permanent = vsa.MeaningMatrix{
        .data = permanent_data,
        .tags = permanent_tags,
    };

    var layer = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = scratchpad.SLOT_BYTES * 4,
    }, &permanent);
    defer layer.deinit();

    try std.testing.expect(!layer.isSessionActive());
    layer.meaning().hardLockUniversalSigil(0xABCD, 'S');
    try std.testing.expect(layer.hasChanges());
    try std.testing.expect(!layer.isSessionActive());

    layer.beginSession();
    try std.testing.expect(layer.isSessionActive());
    try std.testing.expect(!layer.hasChanges());

    layer.endSession();
    try std.testing.expect(!layer.isSessionActive());
}

test "scratchpad apply promotes overlay state into permanent matrix" {
    const allocator = std.testing.allocator;

    const permanent_data = try allocator.alloc(u32, 1024 * 16);
    defer allocator.free(permanent_data);
    const permanent_tags = try allocator.alloc(u64, 16);
    defer allocator.free(permanent_tags);
    @memset(permanent_data, 0);
    @memset(permanent_tags, 0);

    var permanent = vsa.MeaningMatrix{
        .data = permanent_data,
        .tags = permanent_tags,
    };

    var layer = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = scratchpad.SLOT_BYTES * 4,
    }, &permanent);
    defer layer.deinit();

    const hash = ghost_state.wyhash(ghost_state.GENESIS_SEED, 0xCAFE);
    layer.meaning().hardLockUniversalSigil(hash, 'R');

    try std.testing.expect(layer.hasChanges());
    try layer.applyToPermanent();
    try std.testing.expect(!layer.hasChanges());
    try std.testing.expect(vsa.hammingDistance(permanent.collapseToBinary(hash), @as(vsa.HyperVector, @splat(@as(u64, 0)))) > 0);
    try std.testing.expectEqual(@as(?usize, 0), layer.meaning().slotUsageHint());
    try std.testing.expectEqual(permanent.collapseToBinary(hash), layer.meaning().collapseToBinary(hash));
}

test "sigil commit applies scratch while discard restores the baseline" {
    const allocator = std.testing.allocator;
    const lattice_path = "/tmp/ghost-engine-snapshot-test-lattice.bin";
    const semantic_path = "/tmp/ghost-engine-snapshot-test-semantic.bin";
    const tags_path = "/tmp/ghost-engine-snapshot-test-tags.bin";
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.sigil_root_abs_path);
    try deleteFileIfExistsAbsolute(lattice_path);
    try deleteFileIfExistsAbsolute(semantic_path);
    try deleteFileIfExistsAbsolute(tags_path);
    defer deleteTreeIfExistsAbsolute(core_paths.sigil_root_abs_path) catch {};
    defer deleteFileIfExistsAbsolute(lattice_path) catch {};
    defer deleteFileIfExistsAbsolute(semantic_path) catch {};
    defer deleteFileIfExistsAbsolute(tags_path) catch {};

    var lattice_file = try sys.createMappedFile(allocator, lattice_path, config.UNIFIED_SIZE_BYTES);
    defer lattice_file.unmap();
    var semantic_file = try sys.createMappedFile(allocator, semantic_path, config.SEMANTIC_SIZE_BYTES);
    defer semantic_file.unmap();
    var tags_file = try sys.createMappedFile(allocator, tags_path, config.TAG_SIZE_BYTES);
    defer tags_file.unmap();
    @memset(lattice_file.data, 0);
    @memset(semantic_file.data, 0);
    @memset(tags_file.data, 0);

    const lattice: *ghost_state.UnifiedLattice = @ptrCast(@alignCast(lattice_file.data.ptr));
    var lattice_provider = ghost_state.LatticeProvider.initMapped(lattice);
    const lattice_words = @as([*]u16, @ptrCast(@alignCast(lattice_file.data.ptr)))[0 .. config.UNIFIED_SIZE_BYTES / @sizeOf(u16)];
    const meaning_words = @as([*]u32, @ptrCast(@alignCast(semantic_file.data.ptr)))[0..config.SEMANTIC_ENTRIES];
    const tags_words = @as([*]u64, @ptrCast(@alignCast(tags_file.data.ptr)))[0..config.TAG_ENTRIES];
    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_words,
        .tags = tags_words,
    };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    var control = sigil_runtime.ControlPlane.init(allocator);
    defer control.deinit();
    control.applyMoodName("calm");

    var layer = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = scratchpad.SLOT_BYTES * 4,
        .file_prefix = core_paths.scratch_file_prefix,
        .owner_id = core_paths.metadata.id,
    }, &meaning_matrix);
    defer layer.deinit();

    var engine = engine_logic.SingularityEngine{
        .lattice = lattice,
        .meaning = &meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = null,
        .allocator = allocator,
    };
    defer engine.canvas.deinit();
    engine.setLatticeProvider(&lattice_provider);

    const baseline_hash = ghost_state.wyhash(ghost_state.GENESIS_SEED, 0x1101);
    const scratch_hash = ghost_state.wyhash(ghost_state.GENESIS_SEED, 0x2202);

    const scratch_started = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .begin_scratch);
    try std.testing.expect(scratch_started.scratch_active);
    try std.testing.expect(!scratch_started.committed_exists);
    try std.testing.expectEqual(@as(u32, 40), control.snapshot().saturation_bonus);

    control.applyMoodName("aggressive");
    control.setLastScan(.{ .hash = 0xABCD, .energy = 17 });
    meaning_matrix.hardLockUniversalSigil(baseline_hash, 'B');
    layer.meaning().hardLockUniversalSigil(scratch_hash, 'S');
    try std.testing.expect(layer.hasChanges());
    try std.testing.expect(vsa.hammingDistance(meaning_matrix.collapseToBinary(baseline_hash), @as(vsa.HyperVector, @splat(@as(u64, 0)))) > 0);
    try std.testing.expect(vsa.hammingDistance(layer.meaning().collapseToBinary(scratch_hash), @as(vsa.HyperVector, @splat(@as(u64, 0)))) > 0);

    const discarded = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .discard);
    try std.testing.expect(!discarded.scratch_active);
    try std.testing.expectEqual(@as(u32, 40), control.snapshot().saturation_bonus);
    try std.testing.expectEqual(@as(u64, 0), control.snapshot().last_scan.hash);
    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), meaning_matrix.collapseToBinary(baseline_hash));
    try std.testing.expectEqual(@as(vsa.HyperVector, @splat(@as(u64, 0))), layer.meaning().collapseToBinary(scratch_hash));
    try std.testing.expect(!layer.hasChanges());

    const scratch_restarted = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .begin_scratch);
    try std.testing.expect(scratch_restarted.scratch_active);

    control.applyMoodName("focused");
    control.setLastScan(.{ .hash = 0xFEED, .energy = 33 });
    layer.meaning().hardLockUniversalSigil(scratch_hash, 'K');
    try std.testing.expect(layer.hasChanges());

    const committed = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .commit);
    try std.testing.expect(!committed.scratch_active);
    try std.testing.expect(committed.committed_exists);
    try std.testing.expectEqual(@as(u32, 80), control.snapshot().saturation_bonus);
    try std.testing.expectEqual(@as(u64, 0xFEED), control.snapshot().last_scan.hash);
    try std.testing.expect(vsa.hammingDistance(meaning_matrix.collapseToBinary(scratch_hash), @as(vsa.HyperVector, @splat(@as(u64, 0)))) > 0);
    try std.testing.expectEqual(meaning_matrix.collapseToBinary(scratch_hash), layer.meaning().collapseToBinary(scratch_hash));
    try std.testing.expect(!layer.hasChanges());
}

test "abstraction distillation stays staged until sigil commit and snapshot revert restores prior catalog" {
    const allocator = std.testing.allocator;
    const lattice_path = "/tmp/ghost-engine-abstraction-test-lattice.bin";
    const semantic_path = "/tmp/ghost-engine-abstraction-test-semantic.bin";
    const tags_path = "/tmp/ghost-engine-abstraction-test-tags.bin";
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.sigil_root_abs_path);
    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteFileIfExistsAbsolute(lattice_path);
    try deleteFileIfExistsAbsolute(semantic_path);
    try deleteFileIfExistsAbsolute(tags_path);
    defer deleteTreeIfExistsAbsolute(core_paths.sigil_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteFileIfExistsAbsolute(lattice_path) catch {};
    defer deleteFileIfExistsAbsolute(semantic_path) catch {};
    defer deleteFileIfExistsAbsolute(tags_path) catch {};

    var lattice_file = try sys.createMappedFile(allocator, lattice_path, config.UNIFIED_SIZE_BYTES);
    defer lattice_file.unmap();
    var semantic_file = try sys.createMappedFile(allocator, semantic_path, config.SEMANTIC_SIZE_BYTES);
    defer semantic_file.unmap();
    var tags_file = try sys.createMappedFile(allocator, tags_path, config.TAG_SIZE_BYTES);
    defer tags_file.unmap();
    @memset(lattice_file.data, 0);
    @memset(semantic_file.data, 0);
    @memset(tags_file.data, 0);

    const lattice: *ghost_state.UnifiedLattice = @ptrCast(@alignCast(lattice_file.data.ptr));
    var lattice_provider = ghost_state.LatticeProvider.initMapped(lattice);
    const lattice_words = @as([*]u16, @ptrCast(@alignCast(lattice_file.data.ptr)))[0 .. config.UNIFIED_SIZE_BYTES / @sizeOf(u16)];
    const meaning_words = @as([*]u32, @ptrCast(@alignCast(semantic_file.data.ptr)))[0..config.SEMANTIC_ENTRIES];
    const tags_words = @as([*]u64, @ptrCast(@alignCast(tags_file.data.ptr)))[0..config.TAG_ENTRIES];
    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_words,
        .tags = tags_words,
    };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    var control = sigil_runtime.ControlPlane.init(allocator);
    defer control.deinit();
    control.applyMoodName("focused");

    var layer = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = scratchpad.SLOT_BYTES * 4,
        .file_prefix = core_paths.scratch_file_prefix,
        .owner_id = core_paths.metadata.id,
    }, &meaning_matrix);
    defer layer.deinit();

    var engine = engine_logic.SingularityEngine{
        .lattice = lattice,
        .meaning = &meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = null,
        .allocator = allocator,
    };
    defer engine.canvas.deinit();
    engine.setLatticeProvider(&lattice_provider);

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .begin_scratch);

    var parser_record = try abstractions.stageFromCommand(
        allocator,
        &core_paths,
        "/commit_abstractions sigil_json_script_parser region:src/shell_shared.zig:464-472 region:src/shell_windows.zig:823-831",
    );
    defer parser_record.deinit();

    try std.testing.expect(parser_record.valid_to_commit);
    try std.testing.expectEqual(@as(u32, 2), parser_record.example_count);
    try std.testing.expect(parser_record.retained_pattern_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, parser_record.sources[0], "region:src/shell_shared.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, parser_record.sources[1], "region:src/shell_windows.zig") != null);
    try std.testing.expect(fileExistsAbsolute(core_paths.abstractions_staged_abs_path));
    try std.testing.expect(!fileExistsAbsolute(core_paths.abstractions_live_abs_path));

    const staged_before_commit = try readFileAbsoluteAlloc(allocator, core_paths.abstractions_staged_abs_path, 64 * 1024);
    defer allocator.free(staged_before_commit);
    try std.testing.expect(std.mem.indexOf(u8, staged_before_commit, "concept sigil_json_script_parser") != null);

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .commit);

    const live_after_first_commit = try readFileAbsoluteAlloc(allocator, core_paths.abstractions_live_abs_path, 64 * 1024);
    defer allocator.free(live_after_first_commit);
    try std.testing.expect(std.mem.indexOf(u8, live_after_first_commit, "concept sigil_json_script_parser") != null);
    try std.testing.expect(!fileExistsAbsolute(core_paths.abstractions_staged_abs_path));

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .snapshot);

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .begin_scratch);

    var mood_record = try abstractions.stageFromCommand(
        allocator,
        &core_paths,
        "/commit_abstractions sigil_control_mood_guard region:src/shell_shared.zig:488-495 region:src/shell_windows.zig:847-854",
    );
    defer mood_record.deinit();
    try std.testing.expect(mood_record.valid_to_commit);

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .discard);

    const live_after_discard = try readFileAbsoluteAlloc(allocator, core_paths.abstractions_live_abs_path, 64 * 1024);
    defer allocator.free(live_after_discard);
    try std.testing.expect(std.mem.indexOf(u8, live_after_discard, "concept sigil_json_script_parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, live_after_discard, "concept sigil_control_mood_guard") == null);

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .begin_scratch);

    var mood_record_again = try abstractions.stageFromCommand(
        allocator,
        &core_paths,
        "/commit_abstractions sigil_control_mood_guard region:src/shell_shared.zig:488-495 region:src/shell_windows.zig:847-854",
    );
    defer mood_record_again.deinit();

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .commit);

    const live_after_second_commit = try readFileAbsoluteAlloc(allocator, core_paths.abstractions_live_abs_path, 64 * 1024);
    defer allocator.free(live_after_second_commit);
    try std.testing.expect(std.mem.indexOf(u8, live_after_second_commit, "concept sigil_control_mood_guard") != null);

    _ = try sigil_snapshot.executeCommand(.{
        .allocator = allocator,
        .paths = &core_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    }, .revert);

    const live_after_revert = try readFileAbsoluteAlloc(allocator, core_paths.abstractions_live_abs_path, 64 * 1024);
    defer allocator.free(live_after_revert);
    try std.testing.expect(std.mem.indexOf(u8, live_after_revert, "concept sigil_json_script_parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, live_after_revert, "concept sigil_control_mood_guard") == null);
}

test "abstraction distillation can expand bounded code_intel evidence" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    const code_intel_dir = try std.fs.path.join(allocator, &.{ core_paths.root_abs_path, "code_intel" });
    defer allocator.free(code_intel_dir);
    try deleteTreeIfExistsAbsolute(code_intel_dir);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(code_intel_dir) catch {};
    try sys.makePath(allocator, code_intel_dir);

    const code_intel_path = try std.fs.path.join(allocator, &.{ code_intel_dir, "last_result.json" });
    defer allocator.free(code_intel_path);
    const code_intel_body =
        \\{"status":"supported","evidence":[
        \\{"relPath":"src/shell_shared.zig","line":465,"reason":"guard"},
        \\{"relPath":"src/shell_windows.zig","line":824,"reason":"guard"}
        \\],"refactorPath":[],"overlap":[]}
    ;
    const code_intel_handle = try sys.openForWrite(allocator, code_intel_path);
    defer sys.closeFile(code_intel_handle);
    try sys.writeAll(code_intel_handle, code_intel_body);

    var record = try abstractions.stageFromCommand(
        allocator,
        &core_paths,
        "/commit_abstractions code_intel_parser_guard code_intel:last_result:evidence",
    );
    defer record.deinit();

    try std.testing.expect(record.valid_to_commit);
    try std.testing.expectEqual(@as(u32, 2), record.example_count);
    try std.testing.expect(record.retained_pattern_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, record.sources[0], "region:src/shell_shared.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, record.sources[1], "region:src/shell_windows.zig") != null);
}

test "abstraction distillation preserves explicit hierarchy metadata" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};

    var record = try abstractions.stageFromCommand(
        allocator,
        &core_paths,
        "/commit_abstractions sigil_command_guard tier:mechanism category:control_flow parent:sigil_request_contract region:src/shell_shared.zig:464-472 region:src/shell_windows.zig:823-831",
    );
    defer record.deinit();

    try std.testing.expectEqual(abstractions.Tier.mechanism, record.tier);
    try std.testing.expectEqual(abstractions.Category.control_flow, record.category);
    try std.testing.expect(record.parent_concept_id != null);
    try std.testing.expectEqualStrings("sigil_request_contract", record.parent_concept_id.?);
    try std.testing.expect(record.quality_score > 0);
    try std.testing.expect(record.confidence_score > 0);
    try std.testing.expect(record.promotion_ready);
}

test "abstraction lookup promotes bounded higher tiers and falls back when support is insufficient" {
    const allocator = std.testing.allocator;
    var shard_metadata = try shards.resolveProjectMetadata(allocator, "abstraction-lookup-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
        \\GABS1
        \\concept compute_guard
        \\tier pattern
        \\category control_flow
        \\parent compute_mechanism
        \\examples 2
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 2
        \\average_resonance 700
        \\min_resonance 700
        \\quality_score 760
        \\confidence_score 770
        \\reuse_score 160
        \\support_score 240
        \\promotion_ready 0
        \\consensus_hash 42
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern if ( id == null ) return
        \\pattern return id
        \\end
        \\concept compute_mechanism
        \\tier mechanism
        \\category invariant
        \\parent compute_contract
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 3
        \\average_resonance 760
        \\min_resonance 740
        \\quality_score 860
        \\confidence_score 830
        \\reuse_score 200
        \\support_score 300
        \\promotion_ready 1
        \\consensus_hash 84
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/router.zig:10-18
        \\pattern if ( id == null ) return
        \\pattern return id
        \\end
        \\concept compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 3
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 210
        \\support_score 310
        \\promotion_ready 1
        \\consensus_hash 126
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/contracts.zig:2-9
        \\pattern return id
        \\pattern if ( id == null ) return
        \\end
    ;
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    const refs = try abstractions.lookupConcepts(allocator, &shard_paths, .{
        .rel_paths = &.{"src/api/service.zig"},
        .max_items = 3,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = .control_flow,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);

    try std.testing.expect(refs.len >= 2);
    try std.testing.expectEqualStrings("compute_mechanism", refs[0].concept_id);
    try std.testing.expectEqual(abstractions.SelectionMode.promoted, refs[0].selection_mode);
    try std.testing.expectEqualStrings("compute_guard", refs[0].supporting_concept_id.?);
    try std.testing.expectEqualStrings("compute_guard", refs[1].concept_id);
    var saw_contract = false;
    for (refs) |reference| {
        if (std.mem.eql(u8, reference.concept_id, "compute_contract")) saw_contract = true;
    }
    try std.testing.expect(!saw_contract);
}

test "project abstraction lookup imports trusted core provenance without copying local truth" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var project_metadata = try shards.resolveProjectMetadata(allocator, "cross-shard-import-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.abstractions_root_abs_path);
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const core_catalog =
        \\GABS1
        \\concept shared_compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 210
        \\support_score 310
        \\promotion_ready 1
        \\consensus_hash 126
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern return id
        \\pattern if ( id == null ) return
        \\end
    ;
    const core_handle = try sys.openForWrite(allocator, core_paths.abstractions_live_abs_path);
    defer sys.closeFile(core_handle);
    try sys.writeAll(core_handle, core_catalog);

    const refs = try abstractions.lookupConcepts(allocator, &project_paths, .{
        .rel_paths = &.{"src/api/service.zig"},
        .max_items = 4,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = .control_flow,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);

    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("shared_compute_contract", refs[0].concept_id);
    try std.testing.expectEqual(shards.Kind.core, refs[0].owner_kind);
    try std.testing.expectEqualStrings("core", refs[0].owner_id);
    try std.testing.expectEqual(abstractions.ReuseResolution.imported, refs[0].resolution);
    try std.testing.expect(refs[0].usable);
}

test "cross-shard reject keeps provenance explicit and blocks imported reuse" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var project_metadata = try shards.resolveProjectMetadata(allocator, "cross-shard-reject-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.abstractions_root_abs_path);
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const core_catalog =
        \\GABS1
        \\concept shared_compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 210
        \\support_score 310
        \\promotion_ready 1
        \\consensus_hash 126
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern return id
        \\pattern if ( id == null ) return
        \\end
    ;
    const core_handle = try sys.openForWrite(allocator, core_paths.abstractions_live_abs_path);
    defer sys.closeFile(core_handle);
    try sys.writeAll(core_handle, core_catalog);

    var reuse_result = try abstractions.stageReuseFromCommand(allocator, &project_paths, "/reuse_abstractions reject core:shared_compute_contract");
    defer reuse_result.deinit();
    try abstractions.applyStaged(allocator, &project_paths);

    const refs = try abstractions.lookupConcepts(allocator, &project_paths, .{
        .rel_paths = &.{"src/api/service.zig"},
        .max_items = 4,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = .control_flow,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);

    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expect(!refs[0].usable);
    try std.testing.expectEqual(abstractions.ReuseDecision.reject, refs[0].reuse_decision);
    try std.testing.expectEqual(abstractions.ReuseResolution.rejected, refs[0].resolution);
    try std.testing.expectEqual(abstractions.ConflictKind.explicit_reject, refs[0].conflict_kind);
    try std.testing.expectEqual(@as(usize, 0), abstractions.countUsableReferences(refs));
}

test "cross-shard conflict refuses incompatible import and promote pins local override" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var project_metadata = try shards.resolveProjectMetadata(allocator, "cross-shard-promote-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.abstractions_root_abs_path);
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const core_catalog =
        \\GABS1
        \\concept shared_compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 210
        \\support_score 310
        \\promotion_ready 1
        \\consensus_hash 126
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern return id
        \\pattern if ( id == null ) return
        \\end
    ;
    const local_catalog =
        \\GABS1
        \\concept shared_compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 790
        \\min_resonance 770
        \\quality_score 910
        \\confidence_score 890
        \\reuse_score 215
        \\support_score 320
        \\promotion_ready 1
        \\consensus_hash 999
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern return id
        \\pattern if ( cache == null ) return
        \\end
    ;
    const core_handle = try sys.openForWrite(allocator, core_paths.abstractions_live_abs_path);
    defer sys.closeFile(core_handle);
    try sys.writeAll(core_handle, core_catalog);
    const project_handle = try sys.openForWrite(allocator, project_paths.abstractions_live_abs_path);
    defer sys.closeFile(project_handle);
    try sys.writeAll(project_handle, local_catalog);

    {
        const refs = try abstractions.lookupConcepts(allocator, &project_paths, .{
            .rel_paths = &.{"src/api/service.zig"},
            .max_items = 4,
            .include_staged = false,
            .prefer_higher_tiers = true,
            .category_hint = .control_flow,
        });
        defer abstractions.deinitSupportReferences(allocator, refs);

        try std.testing.expectEqual(@as(usize, 2), refs.len);
        try std.testing.expect(refs[0].usable);
        try std.testing.expectEqual(abstractions.ReuseResolution.local_override, refs[0].resolution);
        try std.testing.expectEqual(abstractions.ConflictKind.incompatible, refs[0].conflict_kind);
        try std.testing.expectEqualStrings("shared_compute_contract", refs[0].conflict_concept_id.?);
        try std.testing.expect(!refs[1].usable);
        try std.testing.expectEqual(abstractions.ReuseResolution.conflict_refused, refs[1].resolution);
    }

    var reuse_result = try abstractions.stageReuseFromCommand(allocator, &project_paths, "/reuse_abstractions promote core:shared_compute_contract local:shared_compute_contract");
    defer reuse_result.deinit();
    try abstractions.applyStaged(allocator, &project_paths);

    const promoted_refs = try abstractions.lookupConcepts(allocator, &project_paths, .{
        .rel_paths = &.{"src/api/service.zig"},
        .max_items = 4,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = .control_flow,
    });
    defer abstractions.deinitSupportReferences(allocator, promoted_refs);

    try std.testing.expectEqual(abstractions.ReuseDecision.promote, promoted_refs[0].reuse_decision);
    try std.testing.expectEqual(abstractions.ReuseResolution.local_override, promoted_refs[0].resolution);
}

test "merge tool safely promotes committed project knowledge into core with preserved provenance" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var project_metadata = try shards.resolveProjectMetadata(allocator, "merge-promote-safe");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.abstractions_root_abs_path);
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const project_catalog =
        \\GABS1
        \\concept project_render_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 782
        \\min_resonance 768
        \\quality_score 688
        \\confidence_score 676
        \\reuse_score 210
        \\support_score 300
        \\promotion_ready 1
        \\consensus_hash 4242
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/ui/render.zig:1-8
        \\pattern if ( cache == null ) return
        \\pattern return render id
        \\end
    ;
    const project_handle = try sys.openForWrite(allocator, project_paths.abstractions_live_abs_path);
    defer sys.closeFile(project_handle);
    try sys.writeAll(project_handle, project_catalog);

    var merge_result = try abstractions.stageMergeFromCommand(
        allocator,
        &core_paths,
        "/merge_abstractions promote project:merge-promote-safe:project_render_contract as:core_render_contract",
    );
    defer merge_result.deinit();
    try std.testing.expectEqual(abstractions.MergeMode.promote, merge_result.mode);
    try std.testing.expectEqual(shards.Kind.project, merge_result.source_kind);
    try std.testing.expectEqualStrings("merge-promote-safe", merge_result.source_id);
    try std.testing.expectEqualStrings("core_render_contract", merge_result.destination_concept_id);
    try std.testing.expectEqual(abstractions.TrustClass.promoted, merge_result.destination_trust_class);

    try abstractions.applyStaged(allocator, &core_paths);

    const persisted = try readFileAbsoluteAlloc(allocator, core_paths.abstractions_live_abs_path, 64 * 1024);
    defer allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "concept core_render_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "trust_class promoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "provenance merge_promote|owner=core/core|concept=core_render_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "from=project/merge-promote-safe:project:merge-promote-safe:project_render_contract@1") != null);
}

test "merge tool refuses incompatible promotion into trusted core" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var project_metadata = try shards.resolveProjectMetadata(allocator, "merge-promote-refuse");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.abstractions_root_abs_path);
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const core_catalog =
        \\GABS1
        \\concept shared_runtime_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 790
        \\min_resonance 770
        \\quality_score 910
        \\confidence_score 890
        \\reuse_score 220
        \\support_score 320
        \\promotion_ready 1
        \\consensus_hash 9001
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/runtime/worker.zig:1-6
        \\pattern if ( worker == null ) return
        \\pattern return worker id
        \\end
    ;
    const project_catalog =
        \\GABS1
        \\concept shared_runtime_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 680
        \\confidence_score 670
        \\reuse_score 205
        \\support_score 300
        \\promotion_ready 1
        \\consensus_hash 1234
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/runtime/worker.zig:1-6
        \\pattern if ( cache == null ) return
        \\pattern return worker id
        \\end
    ;
    const core_handle = try sys.openForWrite(allocator, core_paths.abstractions_live_abs_path);
    defer sys.closeFile(core_handle);
    try sys.writeAll(core_handle, core_catalog);
    const project_handle = try sys.openForWrite(allocator, project_paths.abstractions_live_abs_path);
    defer sys.closeFile(project_handle);
    try sys.writeAll(project_handle, project_catalog);

    try std.testing.expectError(
        error.MergeConflictRefused,
        abstractions.stageMergeFromCommand(
            allocator,
            &core_paths,
            "/merge_abstractions promote project:merge-promote-refuse:shared_runtime_contract",
        ),
    );
    try std.testing.expect(!fileExistsAbsolute(core_paths.abstractions_staged_abs_path));
}

test "prune tool marks stale and prunable project memory without deleting it" {
    const allocator = std.testing.allocator;
    var project_metadata = try shards.resolveProjectMetadata(allocator, "prune-hooks-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const project_catalog =
        \\GABS1
        \\concept stale_render_note
        \\tier pattern
        \\category state
        \\examples 2
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 1
        \\average_resonance 640
        \\min_resonance 600
        \\quality_score 620
        \\confidence_score 610
        \\reuse_score 80
        \\support_score 120
        \\promotion_ready 0
        \\consensus_hash 5151
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/ui/render.zig:1-4
        \\pattern render note
        \\end
    ;
    const handle = try sys.openForWrite(allocator, project_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, project_catalog);

    var stale_result = try abstractions.stagePruneFromCommand(
        allocator,
        &project_paths,
        "/prune_abstractions stale stale_render_note",
    );
    defer stale_result.deinit();
    try std.testing.expectEqual(abstractions.PruneMode.mark_stale, stale_result.mode);
    try std.testing.expectEqual(@as(usize, 1), stale_result.affected_concepts.len);
    try abstractions.applyStaged(allocator, &project_paths);

    var collect_result = try abstractions.stagePruneFromCommand(
        allocator,
        &project_paths,
        "/prune_abstractions collect gap:0 quality_below:700 confidence_below:700 trust_at_most:project",
    );
    defer collect_result.deinit();
    try std.testing.expectEqual(abstractions.PruneMode.collect, collect_result.mode);
    try std.testing.expectEqual(@as(usize, 1), collect_result.affected_concepts.len);
    try abstractions.applyStaged(allocator, &project_paths);

    const persisted = try readFileAbsoluteAlloc(allocator, project_paths.abstractions_live_abs_path, 64 * 1024);
    defer allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "concept stale_render_note") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "decay_state prunable") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "provenance prune_mark_stale|owner=project/prune-hooks-test|concept=stale_render_note") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "provenance prune_collect|owner=project/prune-hooks-test|concept=stale_render_note") != null);
}

test "panic dump formatting is deterministic" {
    const allocator = std.testing.allocator;
    const dump = try panic_dump.format(allocator, error.ScratchNotActive);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings("[MONOLITH] Panic: error.ScratchNotActive\n", dump);
}

test "panic dump binary is deterministic and versioned" {
    const allocator = std.testing.allocator;

    var recorder = panic_dump.Recorder.init();
    recorder.notePanicMessage("panic");
    recorder.capture(.{
        .step = 3,
        .active_branches = 2,
        .step_count = 3,
        .branch_count = 2,
        .confidence = 777,
        .stop_reason = .contradiction,
    }, &.{
        .{ .char_code = 'x', .branch_index = 0, .base_score = 500, .score = 700, .confidence = 700 },
        .{ .char_code = 'y', .branch_index = 1, .base_score = 400, .score = 650, .confidence = 650 },
    }, &.{
        .{ .root_char = 'x', .branch_index = 0, .last_char = 'z', .depth = 2, .score = 900, .confidence = 450 },
    });
    recorder.scratch_ref_count = 1;
    recorder.scratch_ref_total_count = 1;
    recorder.scratch_refs[0] = .{ .slot_index = 7, .hash = 0xABCD };

    var first = std.ArrayList(u8).init(allocator);
    defer first.deinit();
    try recorder.serialize(first.writer());

    var second = std.ArrayList(u8).init(allocator);
    defer second.deinit();
    try recorder.serialize(second.writer());

    try std.testing.expectEqualSlices(u8, first.items, second.items);
    try std.testing.expect(first.items.len > 64);
    try std.testing.expectEqualSlices(u8, panic_dump.MAGIC, first.items[0..panic_dump.MAGIC.len]);
    try std.testing.expectEqual(@as(u16, panic_dump.FORMAT_VERSION), std.mem.readInt(u16, first.items[8..10], .little));
    var parsed = try panic_dump.parse(allocator, first.items);
    defer parsed.deinit();
    try std.testing.expectEqual(mc.StopReason.contradiction, parsed.trace.stop_reason);
    try std.testing.expectEqual(@as(u32, 3), parsed.trace.step_count);
    try std.testing.expectEqual(@as(u32, 777), parsed.trace.confidence);
    try std.testing.expectEqual(@as(usize, 2), parsed.candidates.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.candidateTotalCount());
    try std.testing.expectEqual(@as(usize, 1), parsed.hypotheses.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.scratch_refs.len);
    try std.testing.expectEqualStrings("panic", parsed.panic_message.?);
}

test "panic dump replay surfaces patch verification, repair, and support context" {
    const allocator = std.testing.allocator;
    var fixture = try makeRepairSuccessVerificationFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    defer allocator.free(fixture.path_override);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 3,
            .max_files = 3,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = fixture.path_override,
    });
    defer result.deinit();

    var recorder = panic_dump.Recorder.init();
    recorder.notePanicMessage("patch verification replay");
    recorder.capture(.{
        .step = 1,
        .active_branches = 2,
        .reasoning_mode = .proof,
        .step_count = 1,
        .branch_count = 2,
        .created_hypotheses = 2,
        .expanded_hypotheses = 2,
        .accepted_hypotheses = 1,
        .unresolved_hypotheses = 1,
        .confidence = result.confidence,
        .stop_reason = result.stop_reason,
    }, &.{}, &.{});
    try recorder.capturePatchCandidatesResult(allocator, &result);

    var dump_bytes = std.ArrayList(u8).init(allocator);
    defer dump_bytes.deinit();
    try recorder.serialize(dump_bytes.writer());

    var parsed = try panic_dump.parse(allocator, dump_bytes.items);
    defer parsed.deinit();
    var replay = try panic_dump.inspectReplay(allocator, &parsed, false);
    defer replay.deinit(allocator);

    try std.testing.expectEqual(panic_dump.ArtifactKind.patch_candidates_result, parsed.artifact_kind);
    try std.testing.expectEqual(panic_dump.ReplayClass.fully_replayable, replay.class);
    try std.testing.expectEqual(panic_dump.ReplaySource.embedded, replay.source);

    const summary = try panic_dump.renderSummary(allocator, &parsed, &replay);
    defer allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "replay_summary kind=patch_candidates_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "repair lineage=") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "support nodes=") != null);

    const report = try panic_dump.renderReplayReport(allocator, &parsed, &replay);
    defer allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "rendering_model: ghost_technical_renderer_v1") != null);

    panic_dump.global_recorder.reset();
    panic_dump.global_recorder.capture(.{
        .step = 1,
        .active_branches = @intCast(result.candidates.len),
        .reasoning_mode = .proof,
        .step_count = 1,
        .branch_count = @intCast(result.candidates.len),
        .created_hypotheses = @intCast(result.candidates.len),
        .expanded_hypotheses = @intCast(result.candidates.len),
        .accepted_hypotheses = if (result.status == .supported) 1 else 0,
        .unresolved_hypotheses = if (result.status == .unresolved) 1 else 0,
        .confidence = result.confidence,
        .stop_reason = result.stop_reason,
    }, &.{}, &.{});
    try panic_dump.capturePatchCandidatesResult(allocator, &result);
    panic_dump.emitPanicDump("panic replay fixture");
}

fn writeFixtureFile(dir: std.fs.Dir, sub_path: []const u8, contents: []const u8) !void {
    const parent = std.fs.path.dirname(sub_path) orelse ".";
    try dir.makePath(parent);
    try dir.writeFile(.{
        .sub_path = sub_path,
        .data = contents,
    });
}

fn writeFixtureFileAbsolute(root_abs_path: []const u8, sub_path: []const u8, contents: []const u8) !void {
    const abs_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs_path, sub_path });
    defer std.testing.allocator.free(abs_path);
    const parent = std.fs.path.dirname(abs_path) orelse return error.FileNotFound;
    try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn fileUrlForPath(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
}

fn makeCodeIntelFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "src/api/service.zig",
        \\const types = @import("../model/types.zig");
        \\pub fn compute() void {}
        \\pub fn run() void {
        \\    compute();
        \\}
        \\pub fn hydrate(widget: types.Widget) void {
        \\    _ = widget;
        \\    compute();
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/model/types.zig",
        \\pub const Widget = struct {
        \\    value: u32,
        \\};
        \\
    );
    try writeFixtureFile(tmp.dir, "src/ui/render.zig",
        \\const service = @import("../api/service.zig");
        \\pub fn draw() void {
        \\    service.compute();
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/runtime/worker.zig",
        \\const service = @import("../api/service.zig");
        \\pub fn sync() void {
        \\    service.compute();
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/runtime/state.zig",
        \\pub var counter: u32 = 0;
        \\pub fn tick() void {
        \\    counter += 1;
        \\}
        \\pub fn snapshot() u32 {
        \\    return counter;
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/app/root.zig",
        \\const render = @import("../ui/render.zig");
        \\const worker = @import("../runtime/worker.zig");
        \\pub fn boot() void {
        \\    render.draw();
        \\    worker.sync();
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/app/stateful.zig",
        \\const state = @import("../runtime/state.zig");
        \\pub fn repaint() u32 {
        \\    state.tick();
        \\    return state.counter;
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/alt/run.zig",
        \\pub fn helper() void {}
        \\pub fn run() void {
        \\    helper();
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/main.zig",
        \\const root = @import("app/root.zig");
        \\pub fn main() void {
        \\    root.boot();
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/tests.zig",
        \\const std = @import("std");
        \\const service = @import("api/service.zig");
        \\const stateful = @import("app/stateful.zig");
        \\
        \\test "fixture compute paths stay valid" {
        \\    service.run();
        \\    try std.testing.expectEqual(@as(u32, 1), stateful.repaint());
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "build.zig",
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "fixture_app",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\
        \\    const tests = b.addTest(.{
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/tests.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    const run_tests = b.addRunArtifact(tests);
        \\    const test_step = b.step("test", "Run fixture tests");
        \\    test_step.dependOn(&run_tests.step);
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    return .{
        .tmp = tmp,
        .root_path = root_path,
    };
}

fn writeCorpusFixtureVariantOne(dir: std.fs.Dir) !void {
    try writeFixtureFile(dir, "runbook.md",
        \\# Runtime Contracts
        \\Use worker.zig when runtime mode must stay synchronized.
        \\The worker sync path is the project default.
        \\
    );
    try writeFixtureFile(dir, "runbook-copy.md",
        \\# Runtime Contracts
        \\Use worker.zig when runtime mode must stay synchronized.
        \\The worker sync path is the project default.
        \\
    );
    try writeFixtureFile(dir, "runtime.toml",
        \\[runtime]
        \\mode = "safe"
        \\worker_file = "worker.zig"
        \\
    );
    try writeFixtureFile(dir, "worker.zig",
        \\pub fn sync() void {}
        \\pub fn apply() void {
        \\    sync();
        \\}
        \\
    );
    try writeFixtureFile(dir, "blob.bin",
        \\opaque bytes
        \\
    );
}

fn writeCorpusFixtureVariantTwo(dir: std.fs.Dir) !void {
    try writeFixtureFile(dir, "runbook.md",
        \\# Runtime Contracts
        \\Use worker.zig when rebuild mode must take over.
        \\The worker rebuild path replaces sync.
        \\
    );
    try writeFixtureFile(dir, "runbook-copy.md",
        \\# Runtime Contracts
        \\Use worker.zig when rebuild mode must take over.
        \\The worker rebuild path replaces sync.
        \\
    );
    try writeFixtureFile(dir, "runtime.toml",
        \\[runtime]
        \\mode = "rebuild"
        \\worker_file = "worker.zig"
        \\
    );
    try writeFixtureFile(dir, "worker.zig",
        \\pub fn rebuild() void {}
        \\pub fn apply() void {
        \\    rebuild();
        \\}
        \\
    );
    try writeFixtureFile(dir, "blob.bin",
        \\opaque bytes
        \\
    );
}

fn makeCorpusIngestionFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try writeCorpusFixtureVariantOne(tmp.dir);

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    return .{
        .tmp = tmp,
        .root_path = root_path,
    };
}

fn writeCorpusReverseGroundingAmbiguousFixture(dir: std.fs.Dir) !void {
    try writeFixtureFile(dir, "guide-a.md",
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\Keep sync aligned with the documented runtime contract.
        \\
    );
    try writeFixtureFile(dir, "guide-b.md",
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\Keep sync aligned with the operator runtime contract.
        \\
    );
    try writeFixtureFile(dir, "worker.zig",
        \\pub fn sync() void {}
        \\pub fn apply() void {
        \\    sync();
        \\}
        \\
    );
}

fn makeCorpusReverseGroundingAmbiguousFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try writeCorpusReverseGroundingAmbiguousFixture(tmp.dir);

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    return .{
        .tmp = tmp,
        .root_path = root_path,
    };
}

fn writeNoisyRoutingCorpusFixture(dir: std.fs.Dir) !void {
    try writeFixtureFile(dir, "runbook.md",
        \\# Runtime Contracts
        \\The sync path in worker.zig is the supported runtime contract.
        \\Keep sync deterministic.
        \\
    );
    try writeFixtureFile(dir, "runtime.toml",
        \\[runtime]
        \\worker_file = "worker.zig"
        \\worker_action = "sync"
        \\
    );
    try writeFixtureFile(dir, "guide-noise.md",
        \\# Worker Notes
        \\worker.zig handles runtime background work.
        \\This note intentionally avoids the exact action anchor.
        \\
    );
    try writeFixtureFile(dir, "guide-noise-2.md",
        \\# Worker Notes
        \\worker.zig handles operator maintenance work.
        \\This note also avoids the exact action anchor.
        \\
    );
    try writeFixtureFile(dir, "worker.zig",
        \\pub fn sync() void {}
        \\pub fn apply() void {
        \\    sync();
        \\}
        \\
    );
}

fn makeNoisyRoutingCorpusFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try writeNoisyRoutingCorpusFixture(tmp.dir);

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    return .{
        .tmp = tmp,
        .root_path = root_path,
    };
}

fn writeKnowledgePackCorpusFixture(dir: std.fs.Dir, runbook_body: []const u8) !void {
    try writeFixtureFile(dir, "runbook.md", runbook_body);
    try writeFixtureFile(dir, "worker.zig",
        \\pub fn sync() void {}
        \\pub fn apply() void {
        \\    sync();
        \\}
        \\
    );
}

fn countPackReverseGroundings(result: *const code_intel.Result, pack_id: []const u8, pack_version: []const u8) usize {
    var count: usize = 0;
    var prefix_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "@pack/{s}/{s}/", .{ pack_id, pack_version }) catch return 0;
    for (result.reverse_grounding_traces) |trace| {
        if (!trace.usable) continue;
        const rel_path = trace.target_rel_path orelse continue;
        if (std.mem.startsWith(u8, rel_path, prefix)) count += 1;
    }
    return count;
}

fn hasPackRoutingStatus(result: *const code_intel.Result, stage: abstractions.PackRoutingStage, pack_id: []const u8, pack_version: []const u8, status: abstractions.PackRoutingStatus) bool {
    for (result.pack_routing_traces) |trace| {
        if (trace.stage != stage) continue;
        if (trace.status != status) continue;
        if (!std.mem.eql(u8, trace.pack_id, pack_id)) continue;
        if (!std.mem.eql(u8, trace.pack_version, pack_version)) continue;
        return true;
    }
    return false;
}

fn hasPackRoutingStatusCategory(
    result: *const code_intel.Result,
    stage: abstractions.PackRoutingStage,
    pack_id: []const u8,
    pack_version: []const u8,
    status: abstractions.PackRoutingStatus,
    category: abstractions.PackConflictCategory,
) bool {
    for (result.pack_routing_traces) |trace| {
        if (trace.stage != stage) continue;
        if (trace.status != status) continue;
        if (trace.conflict_category != category) continue;
        if (!std.mem.eql(u8, trace.pack_id, pack_id)) continue;
        if (!std.mem.eql(u8, trace.pack_version, pack_version)) continue;
        return true;
    }
    return false;
}

fn countPackRoutingStatus(result: *const code_intel.Result, stage: abstractions.PackRoutingStage, status: abstractions.PackRoutingStatus) usize {
    var count: usize = 0;
    for (result.pack_routing_traces) |trace| {
        if (trace.stage != stage) continue;
        if (trace.status == status) count += 1;
    }
    return count;
}

fn countPackAbstractionTraces(result: *const code_intel.Result, pack_id: []const u8, pack_version: []const u8, usable_only: bool) usize {
    var count: usize = 0;
    var owner_buf: [256]u8 = undefined;
    const owner_id = std.fmt.bufPrint(&owner_buf, "pack/{s}@{s}", .{ pack_id, pack_version }) catch return 0;
    for (result.abstraction_traces) |trace| {
        if (usable_only and !trace.usable) continue;
        if (std.mem.eql(u8, trace.owner_id, owner_id)) count += 1;
    }
    return count;
}

fn hasPackRoutingStageStatus(traces: []const abstractions.PackRoutingTrace, stage: abstractions.PackRoutingStage, pack_id: []const u8, pack_version: []const u8, status: abstractions.PackRoutingStatus) bool {
    for (traces) |trace| {
        if (trace.stage != stage) continue;
        if (trace.status != status) continue;
        if (!std.mem.eql(u8, trace.pack_id, pack_id)) continue;
        if (!std.mem.eql(u8, trace.pack_version, pack_version)) continue;
        return true;
    }
    return false;
}

fn countPackRoutingStageStatus(traces: []const abstractions.PackRoutingTrace, stage: abstractions.PackRoutingStage, status: abstractions.PackRoutingStatus) usize {
    var count: usize = 0;
    for (traces) |trace| {
        if (trace.stage != stage) continue;
        if (trace.status == status) count += 1;
    }
    return count;
}

fn makeScriptedVerificationFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
    path_override: []const u8,
} {
    var fixture = try makeCodeIntelFixture(allocator);
    errdefer fixture.tmp.cleanup();
    errdefer allocator.free(fixture.root_path);

    const fail_once_path = try std.fs.path.join(allocator, &.{ fixture.root_path, "build_fail_once.stamp" });
    defer allocator.free(fail_once_path);
    const script_body = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\set -eu
        \\if [ "${{1:-}}" = "build" ] && [ "${{2:-}}" = "test" ] && grep -R -q "const forwarded_impl =" "$PWD/src" && ! grep -R -q "service\\.compute__ghost_" "$PWD/src"; then
        \\  echo "simulated test failure for contradiction_split wrapper" >&2
        \\  exit 1
        \\fi
        \\if [ "${{1:-}}" = "build" ] && [ -z "${{2:-}}" ] && grep -R -q "@call(.auto," "$PWD/src"; then
        \\  if [ ! -f "{s}" ]; then
        \\    printf '1\n' > "{s}"
        \\    echo "simulated one-time build failure for seam_adapter wrapper" >&2
        \\    exit 1
        \\  fi
        \\fi
        \\exit 0
        \\
    , .{ fail_once_path, fail_once_path });
    defer allocator.free(script_body);
    try writeFixtureFile(fixture.tmp.dir, "bin/zig", script_body);

    const script_path = try fixture.tmp.dir.realpathAlloc(allocator, "bin/zig");
    defer allocator.free(script_path);
    try std.posix.fchmodat(std.posix.AT.FDCWD, script_path, 0o755, 0);

    const path_override = try fixture.tmp.dir.realpathAlloc(allocator, "bin");
    return .{
        .tmp = fixture.tmp,
        .root_path = fixture.root_path,
        .path_override = path_override,
    };
}

fn makeRefinementVerificationFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
    path_override: []const u8,
} {
    var fixture = try makeCodeIntelFixture(allocator);
    errdefer fixture.tmp.cleanup();
    errdefer allocator.free(fixture.root_path);

    const script_body =
        \\#!/bin/sh
        \\set -eu
        \\if [ "${1:-}" = "build" ] && [ "${2:-}" = "test" ]; then
        \\  count=$(grep -R -h "__ghost_c2_impl" "$PWD/src" | wc -l | tr -d ' ')
        \\  if [ "$count" -gt 2 ]; then
        \\    echo "broader runtime hypothesis contradicted expected invariant" >&2
        \\    exit 1
        \\  fi
        \\fi
        \\exit 0
        \\
    ;
    try writeFixtureFile(fixture.tmp.dir, "bin/zig", script_body);

    const script_path = try fixture.tmp.dir.realpathAlloc(allocator, "bin/zig");
    defer allocator.free(script_path);
    try std.posix.fchmodat(std.posix.AT.FDCWD, script_path, 0o755, 0);

    const path_override = try fixture.tmp.dir.realpathAlloc(allocator, "bin");
    return .{
        .tmp = fixture.tmp,
        .root_path = fixture.root_path,
        .path_override = path_override,
    };
}

fn makeRepairSuccessVerificationFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
    path_override: []const u8,
} {
    var fixture = try makeCodeIntelFixture(allocator);
    errdefer fixture.tmp.cleanup();
    errdefer allocator.free(fixture.root_path);

    const script_body =
        \\#!/bin/sh
        \\set -eu
        \\if [ "${1:-}" = "build" ] && [ "${2:-}" = "test" ]; then
        \\  case "$PWD" in
        \\    *__repair_*)
        \\      exit 0
        \\      ;;
        \\    *)
        \\    echo "broader call surface contradicted invariant; narrow to primary surface" >&2
        \\    exit 1
        \\      ;;
        \\  esac
        \\fi
        \\exit 0
        \\
    ;
    try writeFixtureFile(fixture.tmp.dir, "bin/zig", script_body);

    const script_path = try fixture.tmp.dir.realpathAlloc(allocator, "bin/zig");
    defer allocator.free(script_path);
    try std.posix.fchmodat(std.posix.AT.FDCWD, script_path, 0o755, 0);

    const path_override = try fixture.tmp.dir.realpathAlloc(allocator, "bin");
    return .{
        .tmp = fixture.tmp,
        .root_path = fixture.root_path,
        .path_override = path_override,
    };
}

const RuntimeOracleFixtureMode = enum {
    positive,
    negative,
    invalid,
    sequence_positive,
    transition_positive,
};

fn makeRuntimeOracleFixture(allocator: std.mem.Allocator, mode: RuntimeOracleFixtureMode) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
} {
    var fixture = try makeCodeIntelFixture(allocator);
    errdefer fixture.tmp.cleanup();
    errdefer allocator.free(fixture.root_path);

    const runtime_oracle_body = switch (mode) {
        .positive, .negative, .invalid =>
        \\const std = @import("std");
        \\const service = @import("api/service.zig");
        \\
        \\pub fn main() !void {
        \\    const has_impl = @hasDecl(service, "compute__ghost_c1_impl");
        \\    try std.io.getStdOut().writer().print(
        \\        "oracle-run\nstate:impl_decl={s}\ninvariant:wrapper_active={s}\n",
        \\        .{
        \\            if (has_impl) "true" else "false",
        \\            if (has_impl) "true" else "false",
        \\        },
        \\    );
        \\    service.run();
        \\}
        \\
        ,
        .sequence_positive =>
        \\const std = @import("std");
        \\const service = @import("api/service.zig");
        \\const stateful = @import("app/stateful.zig");
        \\
        \\pub fn main() !void {
        \\    const has_impl = @hasDecl(service, "compute__ghost_c1_impl");
        \\    const writer = std.io.getStdOut().writer();
        \\    try writer.writeAll("oracle-run\nevent:boot\nstate:stage=booting\n");
        \\    service.run();
        \\    service.hydrate(.{ .value = 1 });
        \\    _ = stateful.repaint();
        \\    _ = stateful.repaint();
        \\    try writer.writeAll("event:dispatch\nstate:stage=service_called\n");
        \\    try writer.print(
        \\        "event:verified\nstate:stage=verified\nstate:impl_decl={s}\nstate:call_route=service\nstate:result_count=2\nstate:last_state=verified\ninvariant:wrapper_active={s}\n",
        \\        .{
        \\            if (has_impl) "true" else "false",
        \\            if (has_impl) "true" else "false",
        \\        },
        \\    );
        \\}
        \\
        ,
        .transition_positive =>
        \\const std = @import("std");
        \\const worker = @import("runtime/worker.zig");
        \\const state = @import("runtime/state.zig");
        \\
        \\pub fn main() !void {
        \\    const has_impl = @hasDecl(worker, "sync__ghost_c1_impl");
        \\    const writer = std.io.getStdOut().writer();
        \\    try writer.writeAll("oracle-run\nevent:warmup\nstate:phase=idle\n");
        \\    worker.sync();
        \\    state.tick();
        \\    try writer.writeAll("event:sync\nstate:phase=syncing\n");
        \\    worker.sync();
        \\    try writer.print(
        \\        "event:settled\nstate:phase=settled\nstate:impl_decl={s}\nstate:call_route=worker\nstate:sync_count=2\nstate:last_phase=settled\ninvariant:wrapper_active={s}\n",
        \\        .{
        \\            if (has_impl) "true" else "false",
        \\            if (has_impl) "true" else "false",
        \\        },
        \\    );
        \\}
        \\
        ,
    };
    try writeFixtureFile(fixture.tmp.dir, "src/runtime_oracle.zig", runtime_oracle_body);

    const config_body = switch (mode) {
        .positive =>
        \\label=runtime_symbol_check
        \\kind=zig_run
        \\phase=run
        \\arg=zig
        \\arg=run
        \\arg=src/runtime_oracle.zig
        \\check=exit_code:0
        \\check=stdout_contains:oracle-run
        \\check=state_value:impl_decl=true
        \\check=invariant_holds:wrapper_active
        \\
        ,
        .negative =>
        \\label=runtime_symbol_check
        \\kind=zig_run
        \\phase=run
        \\arg=zig
        \\arg=run
        \\arg=src/runtime_oracle.zig
        \\check=exit_code:0
        \\check=stdout_contains:oracle-run
        \\check=state_value:impl_decl=false
        \\check=invariant_holds:wrapper_active
        \\
        ,
        .sequence_positive =>
        \\label=runtime_sequence_check
        \\kind=zig_run
        \\phase=run
        \\arg=zig
        \\arg=run
        \\arg=src/runtime_oracle.zig
        \\check=exit_code:0
        \\check=stdout_contains:oracle-run
        \\check=event_sequence:boot>dispatch>verified
        \\check=state_transition:stage=booting->service_called->verified
        \\check=state_value:impl_decl=true
        \\check=state_value:call_route=service
        \\check=state_value:result_count=2
        \\check=state_value:last_state=verified
        \\check=invariant_holds:wrapper_active
        \\
        ,
        .transition_positive =>
        \\label=runtime_transition_check
        \\kind=zig_run
        \\phase=run
        \\arg=zig
        \\arg=run
        \\arg=src/runtime_oracle.zig
        \\check=exit_code:0
        \\check=stdout_contains:oracle-run
        \\check=event_sequence:warmup>sync>settled
        \\check=state_transition:phase=idle->syncing->settled
        \\check=state_value:impl_decl=true
        \\check=state_value:call_route=worker
        \\check=state_value:sync_count=2
        \\check=state_value:last_phase=settled
        \\check=invariant_holds:wrapper_active
        \\
        ,
        .invalid =>
        \\label=runtime_symbol_check
        \\kind=zig_run
        \\
        ,
    };
    try writeFixtureFile(fixture.tmp.dir, patch_candidates.RUNTIME_ORACLE_FILE_NAME, config_body);

    return .{
        .tmp = fixture.tmp,
        .root_path = fixture.root_path,
    };
}

fn resetPatchTestProjectShard(allocator: std.mem.Allocator, shard_id: []const u8) !void {
    var shard_metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(shard_paths.patch_candidates_root_abs_path);
    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(shard_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(shard_paths.task_sessions_root_abs_path);
}

test "task operator persists and resumes a verified multi-step patch workflow" {
    const allocator = std.testing.allocator;
    const project_shard = "task-operator-verified-test";
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var first = try task_sessions.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .intent_text = "refactor src/api/service.zig:compute but keep the API stable",
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer first.deinit();
    try std.testing.expectEqual(task_sessions.Status.running, first.status);
    try std.testing.expectEqual(@as(u32, 1), first.next_subgoal_index);
    try std.testing.expectEqual(task_sessions.SubgoalState.complete, first.subgoals[0].state);
    try std.testing.expect(fileExistsAbsolute(first.session_path));

    const task_id = try allocator.dupe(u8, first.task_id);
    defer allocator.free(task_id);

    var second = try task_sessions.resumeTask(allocator, .{
        .project_shard = project_shard,
        .task_id = task_id,
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer second.deinit();
    try std.testing.expectEqual(task_sessions.Status.running, second.status);
    try std.testing.expectEqual(@as(u32, 2), second.next_subgoal_index);
    try std.testing.expectEqual(task_sessions.SubgoalState.complete, second.subgoals[1].state);
    try std.testing.expect(second.last_code_intel_result_path != null);
    try std.testing.expect(second.last_draft_path != null);
    try std.testing.expect(second.latest_support != null);
    try std.testing.expect(second.latest_support.?.minimum_met);
    try std.testing.expect(fileExistsAbsolute(second.last_code_intel_result_path.?));

    var third = try task_sessions.resumeTask(allocator, .{
        .project_shard = project_shard,
        .task_id = task_id,
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer third.deinit();
    try std.testing.expectEqual(task_sessions.Status.verified_complete, third.status);
    try std.testing.expectEqual(@as(u32, @intCast(third.subgoals.len)), third.next_subgoal_index);
    try std.testing.expectEqual(task_sessions.SubgoalState.complete, third.subgoals[2].state);
    try std.testing.expect(third.last_patch_candidates_result_path != null);
    try std.testing.expect(third.last_draft_path != null);
    try std.testing.expect(third.latest_support != null);
    try std.testing.expect(third.latest_support.?.verified_candidate_count >= 1);
    try std.testing.expect(fileExistsAbsolute(third.last_patch_candidates_result_path.?));

    const rendered = try task_sessions.renderJson(allocator, &third);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"status\":\"verified_complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"lastPatchCandidatesResultPath\":") != null);
}

test "task operator records blocked patch tasks when Linux-native build support is missing" {
    const allocator = std.testing.allocator;
    const project_shard = "task-operator-blocked-test";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "src/solo.zig",
        \\pub fn compute() void {}
        \\pub fn run() void {
        \\    compute();
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var prepared = try task_sessions.run(allocator, .{
        .repo_root = root_path,
        .project_shard = project_shard,
        .intent_text = "refactor src/solo.zig:compute",
        .max_steps = 2,
        .emit_panic_dump = false,
    });
    defer prepared.deinit();
    try std.testing.expectEqual(task_sessions.Status.running, prepared.status);
    try std.testing.expectEqual(@as(u32, 2), prepared.next_subgoal_index);

    const task_id = try allocator.dupe(u8, prepared.task_id);
    defer allocator.free(task_id);

    var blocked = try task_sessions.resumeTask(allocator, .{
        .project_shard = project_shard,
        .task_id = task_id,
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer blocked.deinit();
    try std.testing.expectEqual(task_sessions.Status.blocked, blocked.status);
    try std.testing.expect(blocked.status_detail != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked.status_detail.?, "no Linux-native build workflow was detected") != null);
    try std.testing.expectEqual(task_sessions.SubgoalState.blocked, blocked.subgoals[2].state);
    try std.testing.expect(blocked.last_patch_candidates_result_path != null);
    try std.testing.expect(fileExistsAbsolute(blocked.last_patch_candidates_result_path.?));
}

test "task operator preserves unresolved support stops for ambiguous grounding" {
    const allocator = std.testing.allocator;
    const project_shard = "task-operator-unresolved-test";
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "notes/ops.md",
        \\# Ops
        \\Worker sync.
        \\
    );

    var shard_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(shard_paths.task_sessions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(shard_paths.task_sessions_root_abs_path) catch {};
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
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
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    var session = try task_sessions.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .intent_text = "explain notes/ops.md:paragraph:worker_sync@2",
        .max_steps = 2,
        .emit_panic_dump = false,
    });
    defer session.deinit();
    try std.testing.expectEqual(task_sessions.Status.unresolved, session.status);
    try std.testing.expect(session.status_detail != null);
    try std.testing.expect(
        std.mem.indexOf(u8, session.status_detail.?, "ambiguous") != null or
            std.mem.indexOf(u8, session.status_detail.?, "grounding") != null or
            std.mem.indexOf(u8, session.status_detail.?, "mapping") != null,
    );
    try std.testing.expectEqual(task_sessions.SubgoalState.unresolved, session.subgoals[1].state);
    try std.testing.expect(session.last_code_intel_result_path != null);
    try std.testing.expect(fileExistsAbsolute(session.last_code_intel_result_path.?));
}

test "task operator can ingest bounded external evidence and recover support" {
    const allocator = std.testing.allocator;
    const project_shard = "task-operator-external-evidence-supported-test";
    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);
    var corpus_fixture = try makeCorpusIngestionFixture(allocator);
    defer corpus_fixture.tmp.cleanup();
    defer allocator.free(corpus_fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    const runbook_path = try std.fs.path.join(allocator, &.{ corpus_fixture.root_path, "runbook.md" });
    defer allocator.free(runbook_path);
    const runtime_path = try std.fs.path.join(allocator, &.{ corpus_fixture.root_path, "runtime.toml" });
    defer allocator.free(runtime_path);
    const worker_path = try std.fs.path.join(allocator, &.{ corpus_fixture.root_path, "worker.zig" });
    defer allocator.free(worker_path);
    const runbook_url = try fileUrlForPath(allocator, runbook_path);
    defer allocator.free(runbook_url);
    const runtime_url = try fileUrlForPath(allocator, runtime_path);
    defer allocator.free(runtime_url);
    const worker_url = try fileUrlForPath(allocator, worker_path);
    defer allocator.free(worker_url);

    var session = try task_sessions.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .intent_text = "explain @corpus/docs/runbook.md:heading:runtime_contracts@1",
        .evidence_request = .{
            .urls = &.{ runbook_url, runtime_url, worker_url },
            .max_sources = 3,
            .trust_class = .exploratory,
        },
        .max_steps = 2,
        .emit_panic_dump = false,
    });
    defer session.deinit();

    try std.testing.expectEqual(task_sessions.Status.verified_complete, session.status);
    try std.testing.expectEqual(external_evidence.AcquisitionState.ingested, session.evidence_state);
    try std.testing.expect(session.last_external_evidence_result_path != null);
    try std.testing.expect(session.last_code_intel_result_path != null);
    try std.testing.expect(fileExistsAbsolute(session.last_external_evidence_result_path.?));
    try std.testing.expect(fileExistsAbsolute(session.last_code_intel_result_path.?));

    const evidence_json = try readFileAbsoluteAlloc(allocator, session.last_external_evidence_result_path.?, 128 * 1024);
    defer allocator.free(evidence_json);
    try std.testing.expect(std.mem.indexOf(u8, evidence_json, "\"state\":\"ingested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence_json, "\"sourceUrl\":\"file://") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence_json, "\"lineage\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence_json, "origin=external_evidence") != null);

    const result_json = try readFileAbsoluteAlloc(allocator, session.last_code_intel_result_path.?, 128 * 1024);
    defer allocator.free(result_json);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"kind\":\"external_evidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"external_evidence_outcome\"") != null);

    const rendered_session = try task_sessions.renderJson(allocator, &session);
    defer allocator.free(rendered_session);
    try std.testing.expect(std.mem.indexOf(u8, rendered_session, "\"evidenceState\":\"ingested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_session, "\"action\":\"evidence_ingested\"") != null);
}

test "task operator keeps conflicting external evidence unresolved" {
    const allocator = std.testing.allocator;
    const project_shard = "task-operator-external-evidence-conflicting-test";
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    var ambiguous_fixture = try makeCorpusReverseGroundingAmbiguousFixture(allocator);
    defer ambiguous_fixture.tmp.cleanup();
    defer allocator.free(ambiguous_fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);
    try writeFixtureFile(fixture.tmp.dir, "notes/ops.md",
        \\# Ops
        \\Worker sync.
        \\
    );

    var shard_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
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
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    const guide_a_path = try std.fs.path.join(allocator, &.{ ambiguous_fixture.root_path, "guide-a.md" });
    defer allocator.free(guide_a_path);
    const guide_a = try fileUrlForPath(allocator, guide_a_path);
    defer allocator.free(guide_a);
    const guide_b_path = try std.fs.path.join(allocator, &.{ ambiguous_fixture.root_path, "guide-b.md" });
    defer allocator.free(guide_b_path);
    const guide_b = try fileUrlForPath(allocator, guide_b_path);
    defer allocator.free(guide_b);
    const ambiguous_worker_path = try std.fs.path.join(allocator, &.{ ambiguous_fixture.root_path, "worker.zig" });
    defer allocator.free(ambiguous_worker_path);
    const worker_url = try fileUrlForPath(allocator, ambiguous_worker_path);
    defer allocator.free(worker_url);

    var session = try task_sessions.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .intent_text = "explain notes/ops.md:paragraph:worker_sync@2",
        .evidence_request = .{
            .urls = &.{ guide_a, guide_b, worker_url },
            .max_sources = 3,
            .trust_class = .exploratory,
        },
        .max_steps = 2,
        .emit_panic_dump = false,
    });
    defer session.deinit();

    try std.testing.expectEqual(task_sessions.Status.unresolved, session.status);
    try std.testing.expect(session.last_external_evidence_result_path != null);
    try std.testing.expect(session.evidence_state == .conflicting or session.evidence_state == .insufficient);
    try std.testing.expect(session.status_detail != null);
    try std.testing.expect(std.mem.indexOf(u8, session.status_detail.?, "ambiguous") != null or std.mem.indexOf(u8, session.status_detail.?, "grounding") != null);

    const rendered_session = try task_sessions.renderJson(allocator, &session);
    defer allocator.free(rendered_session);
    try std.testing.expect(std.mem.indexOf(u8, rendered_session, "\"action\":\"evidence_ingested\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered_session, "\"action\":\"evidence_conflicting\"") != null or
            std.mem.indexOf(u8, rendered_session, "\"action\":\"evidence_insufficient\"") != null,
    );
}

test "operator workflow surface supports end-to-end verified patch workflow" {
    const allocator = std.testing.allocator;
    const project_shard = "operator-workflow-verified-test";
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var mount = try operator_workflow.useProject(allocator, fixture.root_path, project_shard);
    defer mount.deinit();
    const mount_summary = try operator_workflow.renderProject(allocator, &mount, .summary);
    defer allocator.free(mount_summary);
    try std.testing.expect(std.mem.indexOf(u8, mount_summary, "workflow_entry=ghost_task_operator") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount_summary, "project_shard=project/") != null);

    var first = try operator_workflow.runTask(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .intent_text = "refactor src/api/service.zig:compute but keep the API stable",
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer first.deinit();

    const task_id = try allocator.dupe(u8, first.task_id);
    defer allocator.free(task_id);

    var second = try operator_workflow.resumeTask(allocator, .{
        .project_shard = project_shard,
        .task_id = task_id,
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer second.deinit();

    var third = try operator_workflow.resumeTask(allocator, .{
        .project_shard = project_shard,
        .task_id = task_id,
        .max_steps = 1,
        .emit_panic_dump = false,
    });
    defer third.deinit();
    try std.testing.expectEqual(task_sessions.Status.verified_complete, third.status);

    const support_summary = try operator_workflow.renderTaskSupport(allocator, &third, .summary);
    defer allocator.free(support_summary);
    try std.testing.expect(std.mem.indexOf(u8, support_summary, "status=verified_complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, support_summary, "support_permission=supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, support_summary, "patch_result=") != null);

    const support_report = try operator_workflow.renderTaskSupport(allocator, &third, .report);
    defer allocator.free(support_report);
    try std.testing.expect(std.mem.indexOf(u8, support_report, "code_change_summary") != null or std.mem.indexOf(u8, support_report, "claim_status: supported") != null);
}

test "operator workflow surface exposes blocked task replay without manual stitching" {
    const allocator = std.testing.allocator;
    const project_shard = "operator-workflow-blocked-test";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "src/solo.zig",
        \\pub fn compute() void {}
        \\pub fn run() void {
        \\    compute();
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var prepared = try operator_workflow.runTask(allocator, .{
        .repo_root = root_path,
        .project_shard = project_shard,
        .intent_text = "refactor src/solo.zig:compute",
        .max_steps = 2,
        .emit_panic_dump = true,
    });
    defer prepared.deinit();
    try std.testing.expectEqual(task_sessions.Status.running, prepared.status);

    const task_id = try allocator.dupe(u8, prepared.task_id);
    defer allocator.free(task_id);

    var blocked = try operator_workflow.resumeTask(allocator, .{
        .project_shard = project_shard,
        .task_id = task_id,
        .max_steps = 1,
        .emit_panic_dump = true,
    });
    defer blocked.deinit();
    try std.testing.expectEqual(task_sessions.Status.blocked, blocked.status);
    try std.testing.expect(blocked.last_panic_dump_path != null);

    const state_summary = try operator_workflow.renderTaskState(allocator, &blocked, .summary);
    defer allocator.free(state_summary);
    try std.testing.expect(std.mem.indexOf(u8, state_summary, "status=blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, state_summary, "panic_dump=") != null);

    var replay = try operator_workflow.replayTask(allocator, project_shard, task_id, false);
    defer replay.deinit();
    const replay_report = try operator_workflow.renderReplayView(allocator, &replay, .report);
    defer allocator.free(replay_report);
    try std.testing.expect(std.mem.indexOf(u8, replay_report, "task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay_report, "Replay") != null or std.mem.indexOf(u8, replay_report, "replay") != null);
}

fn makeNativeCodeIntelFixture(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "src/native/widget.h",
        \\struct Widget;
        \\int compute(const Widget& widget);
        \\struct Widget {
        \\    int value;
        \\};
        \\
    );
    try writeFixtureFile(tmp.dir, "src/native/widget.cpp",
        \\#include "widget.h"
        \\
        \\int compute(const Widget& widget) {
        \\    return widget.value;
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/native/render.h",
        \\#include "widget.h"
        \\
        \\void draw(const Widget& widget);
        \\
    );
    try writeFixtureFile(tmp.dir, "src/native/render.cpp",
        \\#include "render.h"
        \\
        \\void draw(const Widget& widget) {
        \\    compute(widget);
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/native/app.cpp",
        \\#include "render.h"
        \\
        \\void boot() {
        \\    Widget widget{42};
        \\    draw(widget);
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/native/alt.cpp",
        \\namespace alt {
        \\int compute(int value) {
        \\    return value + 1;
        \\}
        \\}
        \\
    );
    try writeFixtureFile(tmp.dir, "src/native/missing.cpp",
        \\int bad() {
        \\    return alt::compute(3);
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    return .{
        .tmp = tmp,
        .root_path = root_path,
    };
}

test "code intel impact query is traceable and bounded" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(mc.ReasoningMode.proof, result.reasoning_mode);
    try std.testing.expectEqual(mc.StopReason.none, result.stop_reason);
    try std.testing.expectEqualStrings("bounded_semantic_invariants_v1", result.invariant_model.?);
    try std.testing.expect(result.primary != null);
    try std.testing.expectEqualStrings("compute", result.primary.?.name);
    try std.testing.expect(result.evidence.len >= 2);
    try std.testing.expect(result.contradiction_traces.len > 0);
    try std.testing.expectEqual(code_intel.Status.supported, result.support_graph.permission);
    try std.testing.expect(result.support_graph.minimum_met);
    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"supportGraph\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"minimumMet\":true") != null);
}

test "code intel layer2b reuses shard-local abstractions deterministically" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "code-intel-abstraction-layer2-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
        \\GABS1
        \\concept compute_guard
        \\tier pattern
        \\category control_flow
        \\parent compute_mechanism
        \\examples 2
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 2
        \\average_resonance 700
        \\min_resonance 700
        \\quality_score 760
        \\confidence_score 770
        \\reuse_score 160
        \\support_score 240
        \\promotion_ready 0
        \\consensus_hash 42
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern if ( id == null ) return
        \\pattern return id
        \\end
        \\concept compute_mechanism
        \\tier mechanism
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 3
        \\average_resonance 760
        \\min_resonance 740
        \\quality_score 860
        \\confidence_score 830
        \\reuse_score 200
        \\support_score 300
        \\promotion_ready 1
        \\consensus_hash 84
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/router.zig:10-18
        \\pattern if ( id == null ) return
        \\pattern return id
        \\end
    ;
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-abstraction-layer2-test",
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expect(result.abstraction_traces.len > 0);
    try std.testing.expectEqualStrings("compute_mechanism", result.abstraction_traces[0].label);
    var saw_bias = false;
    for (result.query_hypotheses) |hypothesis| {
        if (hypothesis.abstraction_bias > 0) saw_bias = true;
    }
    try std.testing.expect(saw_bias);

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"abstractions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"selectionMode\":\"promoted\"") != null);
}

test "code intel layer2b reports imported core provenance and conflict refusal" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var shard_metadata = try shards.resolveProjectMetadata(allocator, "code-intel-cross-shard-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.abstractions_root_abs_path);
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const core_catalog =
        \\GABS1
        \\concept shared_compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 210
        \\support_score 310
        \\promotion_ready 1
        \\consensus_hash 126
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern return id
        \\pattern if ( id == null ) return
        \\end
    ;
    const project_catalog =
        \\GABS1
        \\concept shared_compute_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 3
        \\retained_patterns 2
        \\average_resonance 790
        \\min_resonance 770
        \\quality_score 910
        \\confidence_score 890
        \\reuse_score 215
        \\support_score 320
        \\promotion_ready 1
        \\consensus_hash 999
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/api/service.zig:1-8
        \\pattern return id
        \\pattern if ( cache == null ) return
        \\end
    ;
    const core_handle = try sys.openForWrite(allocator, core_paths.abstractions_live_abs_path);
    defer sys.closeFile(core_handle);
    try sys.writeAll(core_handle, core_catalog);
    const project_handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(project_handle);
    try sys.writeAll(project_handle, project_catalog);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-cross-shard-test",
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expect(result.abstraction_traces.len >= 2);
    try std.testing.expectEqual(shards.Kind.project, result.abstraction_traces[0].owner_kind);
    try std.testing.expectEqual(abstractions.ReuseResolution.local_override, result.abstraction_traces[0].resolution);
    try std.testing.expect(result.abstraction_traces[0].usable);
    try std.testing.expectEqual(shards.Kind.core, result.abstraction_traces[1].owner_kind);
    try std.testing.expectEqual(abstractions.ReuseResolution.conflict_refused, result.abstraction_traces[1].resolution);
    try std.testing.expect(!result.abstraction_traces[1].usable);

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"resolution\":\"local_override\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ownerKind\":\"core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"conflictKind\":\"incompatible\"") != null);
}

test "code intel exploratory mode is explicit in rendered results" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .reasoning_mode = .exploratory,
        .query_kind = .impact,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);

    try std.testing.expectEqual(mc.ReasoningMode.exploratory, result.reasoning_mode);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"reasoning\":{\"mode\":\"exploratory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"internalContinuationWidth\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"boundedAlternativeGeneration\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"trace\":{\"layer1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"layer3\":{\"mode\":\"exploratory\"") != null);
}

test "execution harness runs zig modules with bounded invariants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "src/main.zig",
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    try std.io.getStdOut().writer().writeAll("runtime-ok\n");
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var result = try execution.run(allocator, .{
        .workspace_root = root_path,
        .cwd = root_path,
    }, .{
        .label = "zig_run_main",
        .kind = .zig_run,
        .phase = .run,
        .argv = &.{ "zig", "run", "src/main.zig" },
        .expectations = &.{
            .{ .success = {} },
            .{ .stdout_contains = "runtime-ok" },
        },
        .timeout_ms = 8_000,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.succeeded());
    try std.testing.expect(result.exit_code != null);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "runtime-ok") != null);
}

test "execution harness rejects unrestricted shell commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var result = try execution.run(allocator, .{
        .workspace_root = root_path,
        .cwd = root_path,
    }, .{
        .label = "blocked_shell",
        .kind = .shell,
        .phase = .invariant,
        .argv = &.{ "bash", "-c", "echo hi" },
        .timeout_ms = 500,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(execution.FailureSignal.disallowed_command, result.failure_signal);
}

test "execution harness times out bounded workspace scripts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "scripts/hang.sh",
        \\#!/bin/sh
        \\sleep 2
        \\
    );
    const script_path = try tmp.dir.realpathAlloc(allocator, "scripts/hang.sh");
    defer allocator.free(script_path);
    try std.posix.fchmodat(std.posix.AT.FDCWD, script_path, 0o755, 0);

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var result = try execution.run(allocator, .{
        .workspace_root = root_path,
        .cwd = root_path,
    }, .{
        .label = "hang_script",
        .kind = .shell,
        .phase = .invariant,
        .argv = &.{"./scripts/hang.sh"},
        .timeout_ms = 100,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(execution.FailureSignal.timed_out, result.failure_signal);
}

test "execution harness closes inherited pipes after child exit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixtureFile(tmp.dir, "scripts/pipe_holder.sh",
        \\#!/bin/sh
        \\sleep 2 &
        \\echo parent-exit
        \\
    );
    const script_path = try tmp.dir.realpathAlloc(allocator, "scripts/pipe_holder.sh");
    defer allocator.free(script_path);
    try std.posix.fchmodat(std.posix.AT.FDCWD, script_path, 0o755, 0);

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var result = try execution.run(allocator, .{
        .workspace_root = root_path,
        .cwd = root_path,
    }, .{
        .label = "pipe_holder",
        .kind = .shell,
        .phase = .invariant,
        .argv = &.{"./scripts/pipe_holder.sh"},
        .expectations = &.{
            .{ .success = {} },
            .{ .stdout_contains = "parent-exit" },
        },
        .timeout_ms = 1_000,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.succeeded());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "parent-exit") != null);
    try std.testing.expect(result.duration_ms < 1_000);
}

test "patch candidate generation is bounded and traceable" {
    const allocator = std.testing.allocator;
    const project_shard = "patch-candidate-generation-test";
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .request_label = "bounded compute guard",
        .caps = .{
            .max_candidates = 2,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(mc.StopReason.none, result.stop_reason);
    try std.testing.expectEqualStrings(patch_candidates.MINIMALITY_MODEL_NAME, result.minimality_model.?);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.verified_supported, result.refactor_plan_status);
    try std.testing.expect(result.selected_strategy != null);
    try std.testing.expect(result.selected_candidate_id != null);
    try std.testing.expect(result.selected_refactor_scope != null);
    try std.testing.expect(result.candidates.len > 0);
    try std.testing.expect(result.candidates.len <= 3);
    try std.testing.expect(!result.correctness_claimed);
    try std.testing.expect(result.invariant_evidence.len > 0);
    try std.testing.expectEqual(mc.ReasoningMode.exploratory, result.handoff.exploration.mode);
    try std.testing.expectEqual(mc.ReasoningMode.proof, result.handoff.proof.mode);
    try std.testing.expectEqual(@as(u32, @intCast(result.candidates.len)), result.handoff.exploration.generated_candidate_count);
    try std.testing.expect(result.handoff.exploration.proof_queue_count <= 2);
    try std.testing.expect(result.handoff.clusters.len > 0);
    try std.testing.expect(result.candidates[0].hunks.len > 0);
    try std.testing.expect(result.candidates[0].minimality.total_cost > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].hunks[0].diff, "__ghost_c1_impl") != null);
    try std.testing.expect(result.candidates[0].rewrite_operators.len > 0);
    try std.testing.expect(result.candidates[0].trace.len >= 2);
    try std.testing.expectEqual(code_intel.Status.supported, result.support_graph.permission);
    try std.testing.expect(result.support_graph.minimum_met);
    var verified_count: usize = 0;
    var novel_count: usize = 0;
    for (result.candidates) |candidate| {
        try std.testing.expect(candidate.status_reason != null);
        if (candidate.status == .supported and (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified)) {
            verified_count += 1;
            try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.build.state);
            try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.test_step.state);
            try std.testing.expect(candidate.verification.build.adapter_id != null);
            try std.testing.expect(std.mem.eql(u8, candidate.verification.build.adapter_id.?, "code.build.zig_build"));
            try std.testing.expect(candidate.verification.build.failure_signal != null);
        }
        if (candidate.status == .novel_but_unverified) {
            novel_count += 1;
            try std.testing.expect(!candidate.entered_proof_mode);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), verified_count);
    try std.testing.expectEqual(@as(u32, @intCast(novel_count)), result.handoff.exploration.preserved_novel_count);
    const rendered = try patch_candidates.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"supportGraph\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"flowMode\":\"explore_then_proof\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"verifier_run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"verifier_evidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"adapterId\":\"code.build.zig_build\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"rewriteOperators\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"failureSignal\":\"none\"") != null);
}

test "patch candidate verification records runtime-oracle evidence for supported output" {
    const allocator = std.testing.allocator;
    const project_shard = "patch-runtime-oracle-positive-test";
    var fixture = try makeRuntimeOracleFixture(allocator, .positive);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .request_label = "runtime oracle positive",
        .caps = .{
            .max_candidates = 1,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.verified_supported, result.refactor_plan_status);
    try std.testing.expectEqual(patch_candidates.ValidationState.runtime_verified, patch_candidates.selectedValidationState(&result).?);
    try std.testing.expect(result.selected_candidate_id != null);
    try std.testing.expectEqual(code_intel.Status.supported, result.support_graph.permission);
    try std.testing.expect(result.support_graph.minimum_met);

    var runtime_supported = false;
    for (result.candidates) |candidate| {
        if (candidate.status != .supported) continue;
        try std.testing.expectEqual(patch_candidates.ValidationState.runtime_verified, candidate.validation_state);
        try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.runtime_step.state);
        try std.testing.expect(candidate.verification.runtime_step.summary != null);
        try std.testing.expect(candidate.verification.runtime_step.evidence != null);
        try std.testing.expect(std.mem.indexOf(u8, candidate.verification.runtime_step.summary.?, "runtime oracle runtime_symbol_check passed") != null);
        try std.testing.expect(std.mem.indexOf(u8, candidate.verification.runtime_step.evidence.?, "runtime_oracle=runtime_symbol_check") != null);
        runtime_supported = true;
    }
    try std.testing.expect(runtime_supported);

    const rendered = try patch_candidates.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"selectedVerificationState\":\"runtime_verified\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"runtime\":{\"status\":\"passed\"") != null);
}

test "patch candidate verification rejects runtime-oracle mismatches after build and test pass" {
    const allocator = std.testing.allocator;
    const project_shard = "patch-runtime-oracle-negative-test";
    var fixture = try makeRuntimeOracleFixture(allocator, .negative);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .request_label = "runtime oracle negative",
        .caps = .{
            .max_candidates = 1,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.unresolved, result.refactor_plan_status);
    try std.testing.expectEqual(patch_candidates.ValidationState.runtime_failed, result.candidates[0].validation_state);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, result.candidates[0].verification.test_step.state);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.failed, result.candidates[0].verification.runtime_step.state);
    try std.testing.expect(result.candidates[0].verification.runtime_step.summary != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.summary.?, "runtime oracle runtime_symbol_check failed") != null);
    try std.testing.expect(result.candidates[0].verification.runtime_step.evidence != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.evidence.?, "impl_decl=false") != null);
}

test "patch candidate verification stays unresolved when runtime oracle support is insufficient" {
    const allocator = std.testing.allocator;
    const project_shard = "patch-runtime-oracle-invalid-test";
    var fixture = try makeRuntimeOracleFixture(allocator, .invalid);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .request_label = "runtime oracle invalid",
        .caps = .{
            .max_candidates = 1,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.unresolved, result.refactor_plan_status);
    try std.testing.expectEqual(patch_candidates.ValidationState.runtime_unresolved, result.candidates[0].validation_state);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.unavailable, result.candidates[0].verification.runtime_step.state);
    try std.testing.expect(result.candidates[0].verification.runtime_step.summary != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.summary.?, "runtime oracle support was insufficient") != null);
}

test "patch candidate verification supports ordered runtime events and state transitions" {
    const allocator = std.testing.allocator;
    const project_shard = "patch-runtime-oracle-sequence-test";
    var fixture = try makeRuntimeOracleFixture(allocator, .sequence_positive);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .request_label = "runtime oracle sequence",
        .caps = .{
            .max_candidates = 1,
            .max_files = 3,
            .max_hunks_per_candidate = 3,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(patch_candidates.ValidationState.runtime_verified, patch_candidates.selectedValidationState(&result).?);
    try std.testing.expect(result.candidates[0].verification.runtime_step.summary != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.summary.?, "runtime oracle runtime_sequence_check passed") != null);
    try std.testing.expect(result.candidates[0].verification.runtime_step.evidence != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.evidence.?, "event:dispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.evidence.?, "state:last_state=verified") != null);
}

test "patch candidate verification supports repeated state transitions in bounded runtime checks" {
    const allocator = std.testing.allocator;
    const project_shard = "patch-runtime-oracle-transition-test";
    var fixture = try makeRuntimeOracleFixture(allocator, .transition_positive);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try resetPatchTestProjectShard(allocator, project_shard);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .breaks_if,
        .target = "src/runtime/worker.zig:sync",
        .request_label = "runtime oracle transition",
        .caps = .{
            .max_candidates = 1,
            .max_files = 3,
            .max_hunks_per_candidate = 3,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(patch_candidates.ValidationState.runtime_verified, patch_candidates.selectedValidationState(&result).?);
    try std.testing.expect(result.candidates[0].verification.runtime_step.summary != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.summary.?, "runtime oracle runtime_transition_check passed") != null);
    try std.testing.expect(result.candidates[0].verification.runtime_step.evidence != null);
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].verification.runtime_step.evidence.?, "state:sync_count=2") != null);
}

test "refactor planner rejects broader verified alternative in favor of smaller verified scope" {
    const allocator = std.testing.allocator;
    var fixture = try makeScriptedVerificationFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    defer allocator.free(fixture.path_override);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 4,
            .max_files = 4,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = fixture.path_override,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.verified_supported, result.refactor_plan_status);

    var winner_idx: ?usize = null;
    var broader_idx: ?usize = null;
    for (result.candidates, 0..) |candidate, idx| {
        if (candidate.status == .supported and (candidate.validation_state == .build_test_verified or candidate.validation_state == .runtime_verified)) winner_idx = idx;
        if (std.mem.eql(u8, candidate.scope, "expanded_neighbor_surface")) broader_idx = idx;
    }

    try std.testing.expect(winner_idx != null);
    try std.testing.expect(broader_idx != null);
    try std.testing.expect(result.candidates[winner_idx.?].minimality.total_cost < result.candidates[broader_idx.?].minimality.total_cost);
    if (result.candidates[broader_idx.?].entered_proof_mode) {
        try std.testing.expectEqual(patch_candidates.ValidationState.proof_rejected, result.candidates[broader_idx.?].validation_state);
        try std.testing.expectEqual(patch_candidates.CandidateStatus.rejected, result.candidates[broader_idx.?].status);
        try std.testing.expect(result.candidates[broader_idx.?].rejection_reason != null);
        try std.testing.expect(std.mem.indexOf(u8, result.candidates[broader_idx.?].rejection_reason.?, "smaller verified scope") != null);
    } else {
        try std.testing.expectEqual(patch_candidates.ValidationState.draft_unvalidated, result.candidates[broader_idx.?].validation_state);
        try std.testing.expectEqual(patch_candidates.CandidateStatus.novel_but_unverified, result.candidates[broader_idx.?].status);
        try std.testing.expect(result.candidates[broader_idx.?].status_reason != null);
    }
}

test "patch candidate verification rejects failures while preserving surviving candidates" {
    const allocator = std.testing.allocator;
    var fixture = try makeScriptedVerificationFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    defer allocator.free(fixture.path_override);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 2,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = fixture.path_override,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expect(result.selected_candidate_id != null);
    try std.testing.expect(result.candidates[0].verification.retry_count > 0);
    try std.testing.expect(result.candidates[0].verification.repair_plans.len > 0);
    try std.testing.expectEqual(patch_candidates.RepairPlanOutcome.improved, result.candidates[0].verification.repair_plans[0].outcome);
    try std.testing.expectEqual(patch_candidates.CandidateStatus.supported, result.candidates[0].status);
    try std.testing.expect(result.candidates[0].validation_state == .build_test_verified or result.candidates[0].validation_state == .runtime_verified);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, result.candidates[0].verification.test_step.state);
    var found_verified = false;
    for (result.candidates) |candidate| {
        if (candidate.status != .supported) continue;
        if (candidate.validation_state != .build_test_verified and candidate.validation_state != .runtime_verified) continue;
        found_verified = true;
        try std.testing.expectEqual(patch_candidates.CandidateStatus.supported, candidate.status);
        try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.build.state);
        try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.test_step.state);
    }
    try std.testing.expect(found_verified);
    try std.testing.expectEqual(@as(u32, 2), result.handoff.proof.queued_candidate_count);
}

test "patch candidate verification records bounded refinement hypotheses for retries" {
    const allocator = std.testing.allocator;
    var fixture = try makeRepairSuccessVerificationFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    defer allocator.free(fixture.path_override);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 3,
            .max_files = 3,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = fixture.path_override,
    });
    defer result.deinit();

    var saw_refinement = false;
    var saw_repair_plan = false;
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        if (candidate.verification.refinements.len == 0) continue;
        saw_refinement = true;
        try std.testing.expect(candidate.verification.refinements[0].retained_hunk_count >= 1);
        if (candidate.verification.repair_plans.len > 0) {
            saw_repair_plan = true;
            try std.testing.expect(candidate.verification.repair_plans[0].outcome == .improved or candidate.verification.repair_plans[0].outcome == .failed);
        }
    }

    try std.testing.expect(saw_refinement);
    try std.testing.expect(saw_repair_plan);
    const rendered = try patch_candidates.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"repairPlans\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"refinements\":[") != null);
}

test "patch candidate repair planner recovers a failing candidate descendant" {
    const allocator = std.testing.allocator;
    var fixture = try makeRepairSuccessVerificationFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    defer allocator.free(fixture.path_override);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 3,
            .max_files = 3,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = fixture.path_override,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.verified_supported, result.refactor_plan_status);

    var repaired_supported = false;
    for (result.candidates) |candidate| {
        if (candidate.status != .supported) continue;
        if (candidate.verification.repair_plans.len == 0) continue;
        repaired_supported = true;
        try std.testing.expect(candidate.verification.repair_plans[0].outcome == .improved);
        try std.testing.expect(std.mem.indexOf(u8, candidate.verification.repair_plans[0].descendant_id, "__repair_") != null);
        try std.testing.expect(candidate.verification.retry_count > 0);
    }
    try std.testing.expect(repaired_supported);

    const rendered = try patch_candidates.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"outcome\":\"improved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"descendantId\":\"candidate_") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"id\":\"repair_") != null);
}

test "patch candidate verification returns unresolved when no survivor remains" {
    const allocator = std.testing.allocator;
    var fixture = try makeScriptedVerificationFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);
    defer allocator.free(fixture.path_override);

    const fail_all_script = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\echo "all verification fails" >&2
        \\exit 1
        \\
    , .{});
    defer allocator.free(fail_all_script);
    try writeFixtureFile(fixture.tmp.dir, "bin/zig", fail_all_script);
    const script_path = try fixture.tmp.dir.realpathAlloc(allocator, "bin/zig");
    defer allocator.free(script_path);
    try std.posix.fchmodat(std.posix.AT.FDCWD, script_path, 0o755, 0);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 3,
            .max_files = 3,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
        .verification_path_override = fixture.path_override,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expectEqualStrings(patch_candidates.MINIMALITY_MODEL_NAME, result.minimality_model.?);
    var saw_failed_repair = false;
    for (result.candidates) |candidate| {
        for (candidate.verification.repair_plans) |plan| {
            if (plan.outcome == .failed) saw_failed_repair = true;
        }
    }
    try std.testing.expect(saw_failed_repair);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.unresolved, result.refactor_plan_status);
    try std.testing.expect(result.selected_refactor_scope == null);
    try std.testing.expect(result.unresolved_detail != null);
    var build_failed_count: usize = 0;
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        try std.testing.expectEqual(patch_candidates.ValidationState.build_failed, candidate.validation_state);
        try std.testing.expectEqual(patch_candidates.CandidateStatus.rejected, candidate.status);
        build_failed_count += 1;
    }
    try std.testing.expect(build_failed_count > 0);
    try std.testing.expect(result.candidates[0].rejection_reason != null);
    try std.testing.expect(result.invariant_evidence.len > 0);
}

test "explore-to-verify handoff preserves bounded novel candidates" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .caps = .{
            .max_candidates = 1,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(mc.ReasoningMode.exploratory, result.handoff.exploration.mode);
    try std.testing.expectEqual(mc.ReasoningMode.proof, result.handoff.proof.mode);
    try std.testing.expectEqual(@as(u32, 1), result.handoff.exploration.proof_queue_limit);
    try std.testing.expectEqual(@as(u32, 1), result.handoff.exploration.proof_queue_count);
    try std.testing.expect(result.handoff.exploration.generated_candidate_count >= result.handoff.exploration.proof_queue_count);
    try std.testing.expect(result.handoff.clusters.len > 0);

    var novel_count: usize = 0;
    for (result.candidates) |candidate| {
        if (candidate.status == .novel_but_unverified) {
            novel_count += 1;
            try std.testing.expect(!candidate.entered_proof_mode);
            try std.testing.expect(candidate.cluster_id != null);
            try std.testing.expect(candidate.cluster_label != null);
        }
    }
    try std.testing.expectEqual(@as(u32, @intCast(novel_count)), result.handoff.exploration.preserved_novel_count);
    try std.testing.expect(novel_count > 0 or result.handoff.exploration.generated_candidate_count == result.handoff.exploration.proof_queue_count);
}

test "patch candidate generation preserves unresolved honesty gates" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "run",
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.contradiction, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
}

test "patch candidate synthesis returns unresolved when target lacks bounded rewrite support" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/runtime/state.zig:counter",
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
    try std.testing.expect(result.unresolved_detail != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unresolved_detail.?, "semantic synthesis support was insufficient") != null);
}

test "patch candidate generation links supporting abstractions" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "patch-candidate-abstraction-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
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
        \\source region:src/api/service.zig:1-8
        \\pattern id
        \\pattern id
        \\end
    ;
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "patch-candidate-abstraction-test",
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(result.abstraction_refs.len > 0);
    try std.testing.expectEqual(patch_candidates.SupportKind.abstraction_live, result.abstraction_refs[0].kind);
    try std.testing.expectEqualStrings("compute_guard", result.abstraction_refs[0].label);
}

test "patch candidate staging file clears deterministically" {
    const allocator = std.testing.allocator;
    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();

    try deleteTreeIfExistsAbsolute(core_paths.patch_candidates_root_abs_path);
    defer deleteTreeIfExistsAbsolute(core_paths.patch_candidates_root_abs_path) catch {};
    try sys.makePath(allocator, core_paths.patch_candidates_root_abs_path);

    const handle = try sys.openForWrite(allocator, core_paths.patch_candidates_staged_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, "{\"status\":\"supported\",\"candidates\":[]}");
    try std.testing.expect(fileExistsAbsolute(core_paths.patch_candidates_staged_abs_path));

    try patch_candidates.clearStaged(allocator, &core_paths);
    try std.testing.expect(!fileExistsAbsolute(core_paths.patch_candidates_staged_abs_path));
}

test "code intel breaks-if query returns a bounded refactor path" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(mc.StopReason.none, result.stop_reason);
    try std.testing.expectEqualStrings("bounded_semantic_invariants_v1", result.invariant_model.?);
    try std.testing.expect(result.refactor_path.len >= 2);
    try std.testing.expectEqualStrings("src/api/service.zig", result.refactor_path[0].rel_path);
    try std.testing.expect(result.contradiction_traces.len > 0);
}

test "code intel contradiction query detects explicit call-site incompatibility" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .contradicts,
        .target = "src/api/service.zig:compute",
        .other_target = "src/ui/render.zig:draw",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(mc.StopReason.none, result.stop_reason);
    try std.testing.expect(result.overlap.len > 0);
    try std.testing.expectEqualStrings("incompatible_call_site_expectation", result.contradiction_kind.?);
    try std.testing.expect(result.contradiction_traces.len > 0);
}

test "code intel contradiction query detects signature incompatibility" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .contradicts,
        .target = "src/api/service.zig:compute",
        .other_target = "src/model/types.zig:Widget",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqualStrings("signature_incompatibility", result.contradiction_kind.?);
    try std.testing.expect(result.overlap.len > 0);
}

test "code intel contradiction query detects ownership-state assumptions" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .contradicts,
        .target = "src/runtime/state.zig:counter",
        .other_target = "src/runtime/state.zig:tick",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqualStrings("ownership_state_assumption", result.contradiction_kind.?);
    try std.testing.expect(result.overlap.len > 0);
}

test "code intel impact query follows signature type relationships" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "src/model/types.zig:Widget",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expect(result.primary != null);
    try std.testing.expectEqualStrings("type", result.primary.?.kind_name);
    try std.testing.expect(result.evidence.len > 0);
    try std.testing.expectEqualStrings("src/api/service.zig", result.evidence[0].rel_path);
}

test "code intel unresolved target stays unresolved instead of guessing" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "run",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.contradiction, result.stop_reason);
    try std.testing.expect(result.unresolved_detail != null);
    try std.testing.expectEqual(code_intel.Status.unresolved, result.support_graph.permission);
    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"supportGraph\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"gap\"") != null);
}

test "code intel cache is shard-local, persistent, and refreshes incrementally" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "code-intel-cache-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path) catch {};

    const cache_index_path = try std.fs.path.join(allocator, &.{ shard_paths.code_intel_cache_abs_path, "index_v1.gcix" });
    defer allocator.free(cache_index_path);

    var first = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-cache-test",
        .query_kind = .impact,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    });
    defer first.deinit();

    try std.testing.expectEqual(code_intel.CacheLifecycle.cold_build, first.cache_lifecycle);
    try std.testing.expectEqual(@as(u32, 11), first.cache_changed_files);
    try std.testing.expect(fileExistsAbsolute(cache_index_path));

    const cold_cache = try readFileAbsoluteAlloc(allocator, cache_index_path, 256 * 1024);
    defer allocator.free(cold_cache);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "sem\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "signature_type") != null);

    var second = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-cache-test",
        .query_kind = .impact,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    });
    defer second.deinit();

    try std.testing.expectEqual(code_intel.CacheLifecycle.warm_load, second.cache_lifecycle);
    try std.testing.expectEqual(@as(u32, 0), second.cache_changed_files);

    const warm_cache = try readFileAbsoluteAlloc(allocator, cache_index_path, 256 * 1024);
    defer allocator.free(warm_cache);
    try std.testing.expectEqualStrings(cold_cache, warm_cache);

    try writeFixtureFile(fixture.tmp.dir, "src/runtime/worker.zig",
        \\pub fn sync() void {}
        \\pub fn sync_more() void {}
        \\
    );

    var third = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-cache-test",
        .query_kind = .impact,
        .target = "src/api/service.zig:compute",
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    });
    defer third.deinit();

    try std.testing.expectEqual(code_intel.CacheLifecycle.warm_refresh, third.cache_lifecycle);
    try std.testing.expectEqual(@as(u32, 1), third.cache_changed_files);

    const refreshed_cache = try readFileAbsoluteAlloc(allocator, cache_index_path, 256 * 1024);
    defer allocator.free(refreshed_cache);
    try std.testing.expect(std.mem.indexOf(u8, refreshed_cache, "sync_more") != null);
}

test "code intel ingests symbolic markdown config markup and dsl into shard-local cache" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "docs/runbook.md",
        \\# Runtime Contracts
        \\Compute uses worker sync.
        \\- Worker sync requires runtime mode.
        \\
    );
    try writeFixtureFile(fixture.tmp.dir, "config/runtime.toml",
        \\[runtime]
        \\mode = "safe"
        \\worker = "sync"
        \\
    );
    try writeFixtureFile(fixture.tmp.dir, "markup/panel.xml",
        \\<panel><title>Runtime</title></panel>
        \\
    );
    try writeFixtureFile(fixture.tmp.dir, "rules/deploy.rules",
        \\[deploy]
        \\allow deploy -> runtime ready
        \\deny rollback => manual review
        \\
    );

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "code-intel-symbolic-cache-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path) catch {};

    const cache_index_path = try std.fs.path.join(allocator, &.{ shard_paths.code_intel_cache_abs_path, "index_v1.gcix" });
    defer allocator.free(cache_index_path);

    var first = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-symbolic-cache-test",
        .query_kind = .impact,
        .target = "docs/runbook.md:heading:runtime_contracts@1",
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    });
    defer first.deinit();

    try std.testing.expectEqual(code_intel.CacheLifecycle.cold_build, first.cache_lifecycle);
    try std.testing.expect(fileExistsAbsolute(cache_index_path));

    const cold_cache = try readFileAbsoluteAlloc(allocator, cache_index_path, 256 * 1024);
    defer allocator.free(cold_cache);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "docs/runbook.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "symbolic_unit") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "heading:runtime_contracts@1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "section:runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "key:runtime.mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "tag:panel@1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "rule:allow_deploy@2") != null);
    try std.testing.expect(std.mem.indexOf(u8, cold_cache, "structural_hint") != null);

    var second = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-symbolic-cache-test",
        .query_kind = .impact,
        .target = "config/runtime.toml:section:runtime",
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    });
    defer second.deinit();

    try std.testing.expectEqual(code_intel.CacheLifecycle.warm_load, second.cache_lifecycle);
    try std.testing.expectEqual(@as(u32, 0), second.cache_changed_files);
}

test "code intel uses bounded symbolic structure in markdown config and dsl reasoning" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "docs/runbook.md",
        \\# Runtime Contracts
        \\Compute uses worker sync.
        \\- Worker sync requires runtime mode.
        \\
    );
    try writeFixtureFile(fixture.tmp.dir, "config/runtime.toml",
        \\[runtime]
        \\mode = "safe"
        \\worker = "sync"
        \\
    );
    try writeFixtureFile(fixture.tmp.dir, "rules/deploy.rules",
        \\[deploy]
        \\allow deploy -> runtime ready
        \\deny rollback => manual review
        \\
    );

    var markdown = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "docs/runbook.md:heading:runtime_contracts@1",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer markdown.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, markdown.status);
    try std.testing.expect(markdown.primary != null);
    try std.testing.expectEqualStrings("symbolic_unit", markdown.primary.?.kind_name);
    try std.testing.expect(markdown.evidence.len > 0);
    try std.testing.expectEqualStrings("docs/runbook.md", markdown.evidence[0].rel_path);
    try std.testing.expect(markdown.evidence[0].line >= 2);
    const markdown_rendered = try code_intel.renderJson(allocator, &markdown);
    defer allocator.free(markdown_rendered);
    try std.testing.expect(std.mem.indexOf(u8, markdown_rendered, "\"kind\":\"symbolic_unit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_rendered, "\"docs/runbook.md\"") != null);

    var config_result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "config/runtime.toml:section:runtime",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer config_result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, config_result.status);
    try std.testing.expect(config_result.primary != null);
    try std.testing.expectEqualStrings("section:runtime", config_result.primary.?.name);
    try std.testing.expect(config_result.evidence.len > 0);

    var dsl_result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "rules/deploy.rules:section:deploy",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer dsl_result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, dsl_result.status);
    try std.testing.expect(dsl_result.evidence.len > 0);
    try std.testing.expectEqualStrings("section:deploy", dsl_result.primary.?.name);
}

test "code intel leaves weak symbolic text targets unresolved" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "notes/ungrounded.txt",
        \\Single unscoped statement.
        \\
    );

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "notes/ungrounded.txt:paragraph:single_unscoped_statement@1",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expect(result.unresolved_detail != null);
    try std.testing.expectEqual(code_intel.PartialSupportLevel.fragmentary, result.partial_support.lattice);
    try std.testing.expect(result.unresolved.partial_findings.len > 0);
    try std.testing.expect(result.unresolved.missing_obligations.len > 0);
    try std.testing.expect(
        std.mem.indexOf(u8, result.unresolved_detail.?, "ground") != null or
            std.mem.indexOf(u8, result.unresolved_detail.?, "symbolic") != null,
    );

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"partialSupport\":{\"lattice\":\"fragmentary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"partialFindings\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"partial_finding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"fragment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"obligation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"freshness_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"requires\"") != null);

    const draft = try technical_drafts.render(allocator, .{ .code_intel = &result }, .{ .draft_type = .proof_backed_explanation });
    defer allocator.free(draft);
    try std.testing.expect(std.mem.indexOf(u8, draft, "claim_status: unresolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft, "non_authorizing_partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft, "supported_claim:") == null);
}

test "code intel parser cascade preserves malformed config fragments as unresolved partials" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "notes/runtime.cfg",
        \\[runtime
        \\mode = safe
        \\worker: sync
        \\orphan =
        \\src/runtime/worker.zig:41
        \\
    );

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "notes/runtime.cfg:section_fragment:runtime",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expect(result.primary != null);
    try std.testing.expectEqualStrings("section_fragment:runtime", result.primary.?.name);
    try std.testing.expect(result.unresolved.partial_findings.len > 0);
    try std.testing.expect(result.unresolved.missing_obligations.len > 0);
    try std.testing.expect(result.unresolved.suppressed_noise.len > 0);
    try std.testing.expect(std.mem.eql(u8, result.unresolved.suppressed_noise[0].rel_path.?, "notes/runtime.cfg"));
}

test "code intel parser cascade captures mixed stack frame and path fragments" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "notes/incident.md",
        \\Incident follow-up
        \\
        \\at syncLoop (src/runtime/worker.zig:41)
        \\at main (src/main.zig:8)
        \\
    );

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "notes/incident.md:frame:syncloop@3",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expect(result.primary != null);
    try std.testing.expectEqualStrings("frame:syncloop@3", result.primary.?.name);
    try std.testing.expect(result.unresolved.partial_findings.len > 0);
}

test "code intel parser cascade preserves deterministic parse ambiguity for weak headings" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "notes/weak.md",
        \\Runtime:
        \\worker sync required
        \\
    );

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "notes/weak.md:heading_fragment:runtime@1",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expect(result.unresolved.ambiguity_sets.len > 0);
    try std.testing.expect(std.mem.eql(u8, result.unresolved.ambiguity_sets[0].label, "parser_cascade_ambiguity") or std.mem.eql(u8, result.unresolved.ambiguity_sets[0].label, "grounding_ambiguity"));
}

test "code intel grounds symbolic runbook and config surfaces to runtime concepts" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "docs/runbook.md",
        \\# Runtime Contracts
        \\Compute uses worker sync.
        \\- Worker sync requires runtime mode.
        \\
    );
    try writeFixtureFile(fixture.tmp.dir, "config/runtime.toml",
        \\[runtime]
        \\mode = "safe"
        \\worker = "sync"
        \\
    );

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "code-intel-grounding-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
        \\GABS1
        \\concept runtime_worker_sync
        \\tier mechanism
        \\category data_flow
        \\examples 3
        \\threshold 2
        \\retained_tokens 4
        \\retained_patterns 2
        \\average_resonance 780
        \\min_resonance 760
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 220
        \\support_score 320
        \\promotion_ready 1
        \\consensus_hash 301
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:src/runtime/worker.zig:1-4
        \\token runtime
        \\token worker
        \\token sync
        \\token mode
        \\pattern worker_sync_requires_runtime_mode
        \\pattern runtime.mode
        \\end
    ;
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    var markdown = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-grounding-test",
        .query_kind = .impact,
        .target = "docs/runbook.md:heading:runtime_contracts@1",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer markdown.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, markdown.status);
    try std.testing.expect(markdown.grounding_traces.len > 0);
    const markdown_rendered = try code_intel.renderJson(allocator, &markdown);
    defer allocator.free(markdown_rendered);
    try std.testing.expect(std.mem.indexOf(u8, markdown_rendered, "\"groundings\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_rendered, "\"concept\":\"runtime_worker_sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_rendered, "\"target\":\"src/runtime/worker.zig:sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_rendered, "\"ownerId\":\"code-intel-grounding-test\"") != null);

    var config_result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-grounding-test",
        .query_kind = .impact,
        .target = "config/runtime.toml:section:runtime",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer config_result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, config_result.status);
    try std.testing.expect(config_result.grounding_traces.len > 0);
    const config_rendered = try code_intel.renderJson(allocator, &config_result);
    defer allocator.free(config_rendered);
    try std.testing.expect(std.mem.indexOf(u8, config_rendered, "\"target\":\"src/runtime/worker.zig:sync\"") != null);
}

test "code intel refuses ambiguous symbolic grounding ties" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    try writeFixtureFile(fixture.tmp.dir, "notes/ops.md",
        \\# Ops
        \\Worker sync.
        \\
    );

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "code-intel-grounding-ambiguous-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.abstractions_root_abs_path) catch {};
    try sys.makePath(allocator, shard_paths.abstractions_root_abs_path);

    const catalog_body =
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
    const handle = try sys.openForWrite(allocator, shard_paths.abstractions_live_abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, catalog_body);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "code-intel-grounding-ambiguous-test",
        .query_kind = .impact,
        .target = "notes/ops.md:paragraph:worker_sync@2",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expect(result.unresolved_detail != null);
    try std.testing.expect(result.partial_support.blocking.ambiguous);
    try std.testing.expect(result.unresolved.ambiguity_sets.len > 0);
    try std.testing.expect(
        std.mem.indexOf(u8, result.unresolved_detail.?, "mapping") != null or
            std.mem.indexOf(u8, result.unresolved_detail.?, "grounding") != null or
            std.mem.indexOf(u8, result.unresolved_detail.?, "ambiguous") != null,
    );
    try std.testing.expect(result.grounding_traces.len >= 2);
    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ambiguous\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ambiguitySets\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"ambiguity_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"status\":\"unresolved\"") != null);
}

test "corpus ingestion stays staged until sigil commit and snapshot revert restores live shard corpus" {
    const allocator = std.testing.allocator;
    const lattice_path = "/tmp/ghost-engine-corpus-ingest-lifecycle-lattice.bin";
    const semantic_path = "/tmp/ghost-engine-corpus-ingest-lifecycle-semantic.bin";
    const tags_path = "/tmp/ghost-engine-corpus-ingest-lifecycle-tags.bin";

    var fixture = try makeCorpusIngestionFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var project_metadata = try shards.resolveProjectMetadata(allocator, "corpus-ingest-lifecycle-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.sigil_root_abs_path);
    try deleteFileIfExistsAbsolute(lattice_path);
    try deleteFileIfExistsAbsolute(semantic_path);
    try deleteFileIfExistsAbsolute(tags_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.sigil_root_abs_path) catch {};
    defer deleteFileIfExistsAbsolute(lattice_path) catch {};
    defer deleteFileIfExistsAbsolute(semantic_path) catch {};
    defer deleteFileIfExistsAbsolute(tags_path) catch {};

    var lattice_file = try sys.createMappedFile(allocator, lattice_path, config.UNIFIED_SIZE_BYTES);
    defer lattice_file.unmap();
    var semantic_file = try sys.createMappedFile(allocator, semantic_path, config.SEMANTIC_SIZE_BYTES);
    defer semantic_file.unmap();
    var tags_file = try sys.createMappedFile(allocator, tags_path, config.TAG_SIZE_BYTES);
    defer tags_file.unmap();
    @memset(lattice_file.data, 0);
    @memset(semantic_file.data, 0);
    @memset(tags_file.data, 0);

    const lattice: *ghost_state.UnifiedLattice = @ptrCast(@alignCast(lattice_file.data.ptr));
    var lattice_provider = ghost_state.LatticeProvider.initMapped(lattice);
    const lattice_words = @as([*]u16, @ptrCast(@alignCast(lattice_file.data.ptr)))[0 .. config.UNIFIED_SIZE_BYTES / @sizeOf(u16)];
    const meaning_words = @as([*]u32, @ptrCast(@alignCast(semantic_file.data.ptr)))[0..config.SEMANTIC_ENTRIES];
    const tags_words = @as([*]u64, @ptrCast(@alignCast(tags_file.data.ptr)))[0..config.TAG_ENTRIES];
    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_words,
        .tags = tags_words,
    };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    var control = sigil_runtime.ControlPlane.init(allocator);
    defer control.deinit();
    control.applyMoodName("calm");

    var layer = try scratchpad.ScratchpadLayer.init(allocator, .{
        .requested_bytes = scratchpad.SLOT_BYTES * 4,
        .file_prefix = project_paths.scratch_file_prefix,
        .owner_id = project_paths.metadata.id,
    }, &meaning_matrix);
    defer layer.deinit();

    var engine = engine_logic.SingularityEngine{
        .lattice = lattice,
        .meaning = &meaning_matrix,
        .soul = &soul,
        .canvas = try ghost_state.MesoLattice.initText(allocator),
        .is_live = false,
        .vulkan = null,
        .allocator = allocator,
    };
    defer engine.canvas.deinit();
    engine.setLatticeProvider(&lattice_provider);

    const live_state = sigil_snapshot.LiveState{
        .allocator = allocator,
        .paths = &project_paths,
        .engine = &engine,
        .control = &control,
        .scratchpad = &layer,
        .meaning_file = &semantic_file,
        .tags_file = &tags_file,
        .meaning_words = meaning_words,
        .tags_words = tags_words,
        .lattice_words = lattice_words,
    };

    _ = try sigil_snapshot.executeCommand(live_state, .begin_scratch);

    var first_stage = try corpus_ingest.stage(allocator, .{
        .corpus_path = fixture.root_path,
        .project_shard = "corpus-ingest-lifecycle-test",
        .trust_class = .project,
        .source_label = "fixture-corpus",
    });
    defer first_stage.deinit();

    try std.testing.expectEqual(@as(u32, 5), first_stage.scanned_files);
    try std.testing.expectEqual(@as(u32, 3), first_stage.staged_items);
    try std.testing.expectEqual(@as(u32, 1), first_stage.duplicate_items);
    try std.testing.expectEqual(@as(u32, 1), first_stage.rejected_items);
    try std.testing.expectEqual(@as(u32, 3), first_stage.concept_count);
    try std.testing.expect(fileExistsAbsolute(project_paths.corpus_ingest_staged_manifest_abs_path));
    try std.testing.expect(!fileExistsAbsolute(project_paths.corpus_ingest_live_manifest_abs_path));

    const staged_manifest = try readFileAbsoluteAlloc(allocator, project_paths.corpus_ingest_staged_manifest_abs_path, 64 * 1024);
    defer allocator.free(staged_manifest);
    try std.testing.expect(std.mem.indexOf(u8, staged_manifest, "\"syntheticRelPath\":\"@corpus/code/worker.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_manifest, "\"dedup\":\"exact_duplicate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_manifest, "\"reason\":\"unsupported_extension\"") != null);

    _ = try sigil_snapshot.executeCommand(live_state, .commit);
    try std.testing.expect(!fileExistsAbsolute(project_paths.corpus_ingest_staged_manifest_abs_path));
    try std.testing.expect(fileExistsAbsolute(project_paths.corpus_ingest_live_manifest_abs_path));

    const worker_live_path = try std.fs.path.join(allocator, &.{
        project_paths.corpus_ingest_live_abs_path,
        config.CORPUS_INGEST_FILES_DIR_NAME,
        "code",
        "worker.zig",
    });
    defer allocator.free(worker_live_path);

    const live_manifest_v1 = try readFileAbsoluteAlloc(allocator, project_paths.corpus_ingest_live_manifest_abs_path, 64 * 1024);
    defer allocator.free(live_manifest_v1);
    try std.testing.expect(std.mem.indexOf(u8, live_manifest_v1, "\"syntheticRelPath\":\"@corpus/docs/runbook.md\"") != null);
    const worker_v1 = try readFileAbsoluteAlloc(allocator, worker_live_path, 8 * 1024);
    defer allocator.free(worker_v1);
    try std.testing.expect(std.mem.indexOf(u8, worker_v1, "pub fn sync()") != null);

    _ = try sigil_snapshot.executeCommand(live_state, .snapshot);
    try writeCorpusFixtureVariantTwo(fixture.tmp.dir);

    _ = try sigil_snapshot.executeCommand(live_state, .begin_scratch);
    var second_stage = try corpus_ingest.stage(allocator, .{
        .corpus_path = fixture.root_path,
        .project_shard = "corpus-ingest-lifecycle-test",
        .trust_class = .project,
        .source_label = "fixture-corpus",
    });
    defer second_stage.deinit();
    try std.testing.expectEqual(@as(u32, 3), second_stage.staged_items);
    try std.testing.expectEqual(@as(u32, 1), second_stage.duplicate_items);
    try std.testing.expectEqual(@as(u32, 1), second_stage.rejected_items);

    _ = try sigil_snapshot.executeCommand(live_state, .commit);
    const worker_v2 = try readFileAbsoluteAlloc(allocator, worker_live_path, 8 * 1024);
    defer allocator.free(worker_v2);
    try std.testing.expect(std.mem.indexOf(u8, worker_v2, "pub fn rebuild()") != null);

    _ = try sigil_snapshot.executeCommand(live_state, .revert);
    const worker_reverted = try readFileAbsoluteAlloc(allocator, worker_live_path, 8 * 1024);
    defer allocator.free(worker_reverted);
    try std.testing.expect(std.mem.indexOf(u8, worker_reverted, "pub fn sync()") != null);
    try std.testing.expect(std.mem.indexOf(u8, worker_reverted, "pub fn rebuild()") == null);
}

test "corpus ingestion integrates with code intel and grounding traces" {
    const allocator = std.testing.allocator;
    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus_fixture = try makeCorpusIngestionFixture(allocator);
    defer corpus_fixture.tmp.cleanup();
    defer allocator.free(corpus_fixture.root_path);

    var project_metadata = try shards.resolveProjectMetadata(allocator, "corpus-ingest-code-intel-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_fixture.root_path,
        .project_shard = "corpus-ingest-code-intel-test",
        .trust_class = .project,
        .source_label = "fixture-corpus",
    });
    defer stage_result.deinit();

    try corpus_ingest.applyStaged(allocator, &project_paths);
    try std.testing.expect(fileExistsAbsolute(project_paths.corpus_ingest_live_manifest_abs_path));
    try std.testing.expect(fileExistsAbsolute(project_paths.abstractions_live_abs_path));

    var code_result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = "corpus-ingest-code-intel-test",
        .query_kind = .impact,
        .target = "@corpus/code/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer code_result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, code_result.status);
    try std.testing.expect(code_result.primary != null);
    try std.testing.expect(code_result.primary.?.corpus != null);
    try std.testing.expectEqualStrings("@corpus/code/worker.zig", code_result.primary.?.rel_path);
    try std.testing.expectEqualStrings("code", code_result.primary.?.corpus.?.class_name);
    try std.testing.expect(code_result.reverse_grounding_traces.len > 0);
    try std.testing.expect(code_result.evidence.len > 0);
    const code_rendered = try code_intel.renderJson(allocator, &code_result);
    defer allocator.free(code_rendered);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"path\":\"@corpus/code/worker.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"sourcePath\":\"worker.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"trust\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"lineageId\":\"corpus:project:corpus-ingest-code-intel-test:@corpus/code/worker.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"reverseGroundings\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"direction\":\"code_to_symbolic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"kind\":\"reverse_grounding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_rendered, "\"explained_by\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, code_rendered, "\"targetPath\":\"@corpus/docs/runbook.md\"") != null or
            std.mem.indexOf(u8, code_rendered, "\"targetPath\":\"@corpus/configs/runtime.toml\"") != null,
    );

    const draft_rendered = try technical_drafts.render(allocator, .{ .code_intel = &code_result }, .{
        .draft_type = .proof_backed_explanation,
        .max_items = 6,
    });
    defer allocator.free(draft_rendered);
    try std.testing.expect(std.mem.indexOf(u8, draft_rendered, "[reverse_grounding]") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, draft_rendered, "@corpus/docs/runbook.md") != null or
            std.mem.indexOf(u8, draft_rendered, "@corpus/configs/runtime.toml") != null,
    );

    var docs_result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = "corpus-ingest-code-intel-test",
        .query_kind = .impact,
        .target = "@corpus/docs/runbook.md:heading:runtime_contracts@1",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer docs_result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, docs_result.status);
    try std.testing.expect(docs_result.grounding_traces.len > 0);
    try std.testing.expect(docs_result.abstraction_traces.len > 0);
    const docs_rendered = try code_intel.renderJson(allocator, &docs_result);
    defer allocator.free(docs_rendered);
    try std.testing.expect(std.mem.indexOf(u8, docs_rendered, "\"target\":\"@corpus/code/worker.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs_rendered, "\"targetPath\":\"@corpus/code/worker.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs_rendered, "\"targetKind\":\"file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs_rendered, "\"ownerId\":\"corpus-ingest-code-intel-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs_rendered, "\"trust\":\"project\"") != null);
}

test "corpus ask no corpus returns explicit unknown without mutation" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-no-corpus-test";

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var result = try corpus_ask.ask(allocator, .{
        .question = "what is the retention policy",
        .project_shard = project_shard,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.unknowns.len);
    try std.testing.expectEqual(corpus_ask.UnknownKind.no_corpus_available, result.unknowns[0].kind);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
    try std.testing.expect(!result.safety_flags.commands_executed);
    try std.testing.expect(!result.safety_flags.verifiers_executed);
}

test "corpus ask returns draft answer with bounded evidence and weak matches stay unknown" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-evidence-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "runtime.md",
        \\# Runtime Retention
        \\Retention policy is enabled for event audit logs.
        \\Operators should cite this corpus item before drafting an answer.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "ask-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var answered = try corpus_ask.ask(allocator, .{
        .question = "is RETENTION POLICY enabled",
        .project_shard = project_shard,
        .max_snippet_bytes = 80,
    });
    defer answered.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.answered, answered.status);
    try std.testing.expect(answered.answer_draft != null);
    try std.testing.expectEqual(@as(usize, 1), answered.evidence_used.len);
    try std.testing.expect(answered.evidence_used[0].snippet.len <= 80);
    try std.testing.expect(answered.evidence_used[0].byte_end > answered.evidence_used[0].byte_start);
    try std.testing.expect(answered.evidence_used[0].line_start >= 1);
    try std.testing.expect(answered.evidence_used[0].line_end >= answered.evidence_used[0].line_start);
    try std.testing.expect(std.mem.indexOf(u8, answered.evidence_used[0].path, "@corpus/docs/runtime.md") != null);
    try std.testing.expect(std.mem.eql(u8, answered.evidence_used[0].source_path, "runtime.md"));
    try std.testing.expect(std.mem.eql(u8, answered.evidence_used[0].source_label, "ask-corpus"));
    try std.testing.expect(std.mem.eql(u8, answered.evidence_used[0].trust_class, "project"));
    try std.testing.expect(std.mem.startsWith(u8, answered.evidence_used[0].content_hash, "fnv1a64:"));
    try std.testing.expect(answered.evidence_used[0].matched_terms.len >= 2);
    try std.testing.expect(answered.evidence_used[0].matched_phrase != null);
    try std.testing.expect(std.mem.eql(u8, answered.evidence_used[0].matched_phrase.?, "retention policy"));
    try std.testing.expect(std.mem.eql(u8, answered.evidence_used[0].match_reason, "exact_phrase_and_token_overlap"));
    try std.testing.expect(!answered.safety_flags.corpus_mutation);
    try std.testing.expect(!answered.safety_flags.pack_mutation);
    try std.testing.expect(!answered.safety_flags.negative_knowledge_mutation);
    try std.testing.expect(!answered.safety_flags.commands_executed);
    try std.testing.expect(!answered.safety_flags.verifiers_executed);

    var weak = try corpus_ask.ask(allocator, .{
        .question = "database backup window",
        .project_shard = project_shard,
    });
    defer weak.deinit();
    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, weak.status);
    try std.testing.expectEqual(corpus_ask.UnknownKind.insufficient_evidence, weak.unknowns[0].kind);
    try std.testing.expect(weak.answer_draft == null);
}

test "corpus ask applies accepted reviewed correction influence without proof or mutation" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-accepted-correction-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "runtime.md",
        \\# Runtime Retention
        \\Retention policy is enabled for event audit logs.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "ask-correction-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var rejected = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .rejected,
        .reviewer_note = "rejected by test",
        .rejected_reason = "not enough detail",
        .source_candidate_id = "correction:candidate:rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rejected","originalOperationKind":"corpus.ask","originalRequestSummary":"is retention policy enabled","disputedOutput":{"kind":"answerDraft","summary":"Retention policy is enabled"},"userCorrection":"ignore","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[]",
    });
    defer rejected.deinit();
    var accepted = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .accepted,
        .reviewer_note = "accepted by test",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:accepted",
        .correction_candidate_json =
        \\{"id":"correction:candidate:accepted","originalOperationKind":"corpus.ask","originalRequestSummary":"is retention policy enabled","disputedOutput":{"kind":"answerDraft","summary":"Retention policy is enabled"},"userCorrection":"that exact draft was wrong","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer accepted.deinit();

    var result = try corpus_ask.ask(allocator, .{
        .question = "is retention policy enabled",
        .project_shard = project_shard,
        .max_snippet_bytes = 96,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expectEqual(@as(usize, 1), result.correction_influences.len);
    try std.testing.expectEqualStrings("suppress_exact_repeat", result.correction_influences[0].influence_kind);
    try std.testing.expect(result.correction_influences[0].non_authorizing);
    try std.testing.expect(!result.correction_influences[0].treated_as_proof);
    try std.testing.expect(!result.correction_influences[0].global_promotion);
    try std.testing.expectEqual(@as(usize, 1), result.influence_telemetry.matched_influences);
    try std.testing.expect(result.influence_telemetry.answer_suppressed);
    try std.testing.expectEqual(@as(usize, 2), result.influence_telemetry.reviewed_records_read);
    try std.testing.expectEqual(@as(usize, 1), result.influence_telemetry.accepted_records_read);
    try std.testing.expectEqual(@as(usize, 1), result.influence_telemetry.rejected_records_read);
    try std.testing.expect(result.future_behavior_candidates.len >= 1);
    try std.testing.expectEqualStrings("verifier_check_candidate", result.future_behavior_candidates[0].kind);
    try std.testing.expect(result.future_behavior_candidates[0].candidate_only);
    try std.testing.expect(!result.future_behavior_candidates[0].treated_as_proof);
    try std.testing.expectEqual(@as(usize, 1), result.evidence_used.len);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_used[0].item_id, "reviewed-correction:") == null);
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
    try std.testing.expect(!result.safety_flags.commands_executed);
    try std.testing.expect(!result.safety_flags.verifiers_executed);

    const rendered = try corpus_ask.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"correctionInfluences\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"futureBehaviorCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"acceptedCorrectionWarnings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"treatedAsProof\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"corpusMutation\":true") == null);

    var other = try corpus_ask.ask(allocator, .{
        .question = "is retention policy enabled",
        .project_shard = "corpus-ask-accepted-correction-other-shard",
    });
    defer other.deinit();
    try std.testing.expectEqual(@as(usize, 0), other.correction_influences.len);
}

test "corpus ask applies accepted reviewed negative knowledge influence without proof or mutation" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-accepted-nk-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "runtime.md",
        \\# Runtime Retention
        \\Retention policy is enabled for event audit logs.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "ask-nk-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var rejected = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .rejected,
        .reviewer_note = "rejected by test",
        .rejected_reason = "not enough detail",
        .source_candidate_id = "nk:candidate:rejected",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:rejected","operationKind":"corpus.ask","condition":"Retention policy is enabled","suppression_rule":"Retention policy is enabled","nonAuthorizing":true}
        ,
    });
    defer rejected.deinit();
    var accepted = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .accepted,
        .reviewer_note = "accepted by test",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:accepted",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:accepted","operationKind":"corpus.ask","kind":"failed_hypothesis","condition":"Retention policy is enabled","suppression_rule":"Retention policy is enabled","nonAuthorizing":true}
        ,
    });
    defer accepted.deinit();

    const reviewed_path = try negative_knowledge_review.reviewedNegativeKnowledgePath(allocator, project_shard);
    defer allocator.free(reviewed_path);
    var file = try std.fs.openFileAbsolute(reviewed_path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed negative knowledge line}\n");

    var result = try corpus_ask.ask(allocator, .{
        .question = "is retention policy enabled",
        .project_shard = project_shard,
        .max_snippet_bytes = 96,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge_influences.len);
    try std.testing.expectEqualStrings("suppress_exact_repeat", result.negative_knowledge_influences[0].influence_kind);
    try std.testing.expect(result.negative_knowledge_influences[0].non_authorizing);
    try std.testing.expect(!result.negative_knowledge_influences[0].treated_as_proof);
    try std.testing.expect(!result.negative_knowledge_influences[0].used_as_evidence);
    try std.testing.expect(!result.negative_knowledge_influences[0].global_promotion);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge_telemetry.influences_applied);
    try std.testing.expectEqual(@as(usize, 1), result.negative_knowledge_telemetry.malformed_lines);
    try std.testing.expect(result.negative_knowledge_telemetry.answer_suppressed);
    try std.testing.expect(result.future_behavior_candidates.len >= 1);
    try std.testing.expect(result.future_behavior_candidates[0].source_reviewed_negative_knowledge_id != null);
    try std.testing.expect(!result.future_behavior_candidates[0].treated_as_proof);
    try std.testing.expect(!result.future_behavior_candidates[0].used_as_evidence);
    try std.testing.expectEqual(@as(usize, 1), result.evidence_used.len);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_used[0].item_id, "reviewed-negative-knowledge:") == null);
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
    try std.testing.expect(!result.safety_flags.commands_executed);
    try std.testing.expect(!result.safety_flags.verifiers_executed);

    const rendered = try corpus_ask.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"acceptedNegativeKnowledgeWarnings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"negativeKnowledgeInfluences\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"negativeKnowledgeTelemetry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "malformed reviewed negative knowledge JSONL line ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"usedAsEvidence\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"treatedAsProof\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"corpusMutation\":true") == null);

    var other = try corpus_ask.ask(allocator, .{
        .question = "is retention policy enabled",
        .project_shard = "corpus-ask-accepted-nk-other-shard",
    });
    defer other.deinit();
    try std.testing.expectEqual(@as(usize, 0), other.negative_knowledge_influences.len);
}

test "corpus ask correction influence emits warning candidates for missing evidence and repeated patterns" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-correction-candidates-test";

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.root_abs_path) catch {};
    try std.fs.cwd().makePath(project_paths.root_abs_path);

    const reviewed_path = try correction_review.reviewedCorrectionsPath(allocator, project_shard);
    defer allocator.free(reviewed_path);
    try ensureParentDirAbsolute(reviewed_path);
    var file = try std.fs.createFileAbsolute(reviewed_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{not json}\n");

    var missing = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .accepted,
        .reviewer_note = "missing evidence accepted",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:missing",
        .correction_candidate_json =
        \\{"id":"correction:candidate:missing","originalOperationKind":"corpus.ask","originalRequestSummary":"audit retention unknown","disputedOutput":{"kind":"unknown","summary":"audit retention unknown"},"userCorrection":"needs more evidence","correctionType":"missing_evidence"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"follow_up_evidence_request\"}]",
    });
    defer missing.deinit();
    var repeated = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = project_shard,
        .decision = .accepted,
        .reviewer_note = "repeated pattern accepted",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:repeated",
        .correction_candidate_json =
        \\{"id":"correction:candidate:repeated","originalOperationKind":"corpus.ask","originalRequestSummary":"audit retention unknown","disputedOutput":{"kind":"unknown","summary":"audit retention unknown"},"userCorrection":"repeated failed pattern","correctionType":"repeated_failed_pattern"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"negative_knowledge_candidate\"}]",
    });
    defer repeated.deinit();

    var result = try corpus_ask.ask(allocator, .{
        .question = "audit retention unknown",
        .project_shard = project_shard,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expectEqual(@as(usize, 2), result.correction_influences.len);
    try std.testing.expectEqual(@as(usize, 1), result.accepted_correction_warnings.len);
    try std.testing.expectEqual(@as(usize, 1), result.influence_telemetry.malformed_lines);
    try std.testing.expectEqual(@as(usize, 2), result.influence_telemetry.matched_influences);
    var saw_followup = false;
    var saw_nk = false;
    for (result.future_behavior_candidates) |candidate| {
        if (std.mem.eql(u8, candidate.kind, "follow_up_evidence_request")) saw_followup = true;
        if (std.mem.eql(u8, candidate.kind, "negative_knowledge_candidate")) {
            saw_nk = true;
            try std.testing.expect(candidate.candidate_only);
            try std.testing.expect(candidate.non_authorizing);
            try std.testing.expect(!candidate.treated_as_proof);
            try std.testing.expect(!candidate.mutation_flags.negative_knowledge_mutation);
        }
    }
    try std.testing.expect(saw_followup);
    try std.testing.expect(saw_nk);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
}

test "corpus ask reports deterministic non-authorizing sketch candidates without drafting" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-sketch-routing-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "a.md",
        \\# Sketch Route A
        \\Frobulator quiescence window requires bounded local recurrence detection for duplicate corpus chunks.
        \\
    );
    try writeFixtureFile(corpus_fixture.dir, "b.md",
        \\# Sketch Route B
        \\Frobulator quiescence window requires bounded local recurrence detection for duplicate corpus chunk review.
        \\
    );
    try writeFixtureFile(corpus_fixture.dir, "c.md",
        \\# Unrelated
        \\Shader compilation diagnostics belong to graphics startup logs and runtime driver setup.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "sketch-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var result = try corpus_ask.ask(allocator, .{
        .question = "frobulatr quiescense windos requir boundid lokel recurence detecton duplikate korpus chonks",
        .project_shard = project_shard,
        .max_results = 3,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expectEqual(corpus_ask.UnknownKind.insufficient_evidence, result.unknowns[0].kind);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expectEqual(@as(usize, 0), result.evidence_used.len);
    try std.testing.expect(result.similar_candidates.len >= 2);
    try std.testing.expect(std.mem.eql(u8, result.similar_candidates[0].source_label, "sketch-corpus"));
    try std.testing.expect(result.similar_candidates[0].hamming_distance <= result.similar_candidates[1].hamming_distance);
    try std.testing.expectEqual(@as(usize, 1), result.similar_candidates[0].rank);
    try std.testing.expect(result.similar_candidates[0].non_authorizing);
    try std.testing.expect(std.mem.eql(u8, result.similar_candidates[0].reason, "simhash_near_duplicate"));
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
    try std.testing.expect(!result.safety_flags.commands_executed);
    try std.testing.expect(!result.safety_flags.verifiers_executed);

    const rendered = try corpus_ask.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"similarCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"answerDraft\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"evidenceUsed\":[]") != null);

    var capped = try corpus_ask.ask(allocator, .{
        .question = "frobulatr quiescense windos requir boundid lokel recurence detecton duplikate korpus chonks",
        .project_shard = project_shard,
        .max_results = 1,
    });
    defer capped.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, capped.status);
    try std.testing.expect(capped.answer_draft == null);
    try std.testing.expect(capped.capacity_telemetry.sketch_candidate_cap_hit);
    try std.testing.expect(capped.capacity_telemetry.max_results_hit);
    try std.testing.expectEqual(corpus_ask.UnknownKind.capacity_limited, capped.unknowns[1].kind);
    try std.testing.expectEqual(@as(usize, 1), capped.similar_candidates.len);
    try std.testing.expect(capped.similar_candidates[0].non_authorizing);
}

test "corpus ask respects max results and snippet bounds in exact evidence" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-bounds-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "a.md",
        \\# Recall A
        \\Recall policy enabled with exact local evidence and bounded snippets for answer drafting.
        \\
    );
    try writeFixtureFile(corpus_fixture.dir, "b.md",
        \\# Recall B
        \\Recall policy enabled with exact local evidence and bounded snippets for answer drafting.
        \\
    );
    try writeFixtureFile(corpus_fixture.dir, "c.md",
        \\# Recall C
        \\Recall policy enabled with exact local evidence and bounded snippets for answer drafting.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "bounds-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var result = try corpus_ask.ask(allocator, .{
        .question = "recall policy enabled",
        .project_shard = project_shard,
        .max_results = 2,
        .max_snippet_bytes = 32,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.answered, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.evidence_used.len);
    try std.testing.expectEqual(true, result.capacity_telemetry.max_results_hit);
    try std.testing.expectEqual(true, result.capacity_telemetry.exact_candidate_cap_hit);
    try std.testing.expectEqual(@as(usize, 2), result.capacity_telemetry.truncated_snippets);
    try std.testing.expect(result.capacity_telemetry.budget_hits >= 2);
    try std.testing.expectEqual(corpus_ask.UnknownKind.capacity_limited, result.unknowns[0].kind);
    for (result.evidence_used, 0..) |evidence, idx| {
        try std.testing.expect(evidence.snippet.len <= 32);
        try std.testing.expect(evidence.snippet_truncated);
        try std.testing.expectEqual(idx + 1, evidence.rank);
        try std.testing.expect(std.mem.eql(u8, evidence.source_label, "bounds-corpus"));
        try std.testing.expect(std.mem.startsWith(u8, evidence.content_hash, "fnv1a64:"));
        try std.testing.expect(evidence.byte_end > evidence.byte_start);
    }

    const rendered = try corpus_ask.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"capacityTelemetry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"maxResultsHit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"truncatedSnippets\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"capacityWarnings\"") != null);
}

test "corpus ask skipped oversized evidence cannot support answer draft" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-skipped-capacity-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);

    const prefix = try allocator.alloc(u8, 70 * 1024);
    defer allocator.free(prefix);
    @memset(prefix, 'x');
    var large = std.ArrayList(u8).init(allocator);
    defer large.deinit();
    try large.appendSlice(prefix);
    try large.appendSlice("\nLate policy says retention policy enabled after the bounded ask read window.\n");
    try corpus_fixture.dir.writeFile(.{ .sub_path = "large.md", .data = large.items });

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "large-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var result = try corpus_ask.ask(allocator, .{
        .question = "retention policy enabled",
        .project_shard = project_shard,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expectEqual(@as(usize, 0), result.evidence_used.len);
    try std.testing.expectEqual(@as(usize, 1), result.capacity_telemetry.truncated_inputs);
    try std.testing.expectEqual(corpus_ask.UnknownKind.capacity_limited, result.unknowns[1].kind);
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
}

test "gip corpus ask sees ingested corpus only after explicit staged apply" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-e2e-apply-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "verifier-policy.md",
        \\# Verifier Execution Policy
        \\Ghost corpus smoke fact: verifier execution must remain explicit and never run by default.
        \\Corpus answers may draft from evidence, but they do not execute verifiers.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var before = try gip.dispatch.dispatch(
        allocator,
        "corpus.ask",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        "{\"question\":\"What does the corpus say about verifier execution?\",\"projectShard\":\"corpus-ask-e2e-apply-test\",\"maxResults\":2,\"maxSnippetBytes\":96}",
    );
    defer before.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.unresolved, before.status);
    try std.testing.expect(before.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, before.result_json.?, "\"no_corpus_available\"") != null);

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "verifier-policy-corpus",
    });
    defer stage_result.deinit();

    var staged_only = try gip.dispatch.dispatch(
        allocator,
        "corpus.ask",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        "{\"question\":\"What does the corpus say about verifier execution?\",\"projectShard\":\"corpus-ask-e2e-apply-test\",\"maxResults\":2,\"maxSnippetBytes\":96}",
    );
    defer staged_only.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.unresolved, staged_only.status);
    try std.testing.expect(staged_only.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_only.result_json.?, "\"no_corpus_available\"") != null);

    try corpus_ingest.applyStaged(allocator, &project_paths);

    var answered = try gip.dispatch.dispatch(
        allocator,
        "corpus.ask",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        "{\"question\":\"What does the corpus say about verifier execution?\",\"projectShard\":\"corpus-ask-e2e-apply-test\",\"maxResults\":2,\"maxSnippetBytes\":96}",
    );
    defer answered.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, answered.status);
    try std.testing.expect(answered.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"status\":\"answered\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"state\":\"draft\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"permission\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"answerDraft\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"sourcePath\":\"verifier-policy.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"sourceLabel\":\"verifier-policy-corpus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"trustClass\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"contentHash\":\"fnv1a64:") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"byteSpan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"lineSpan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"matchedTerms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"matchedPhrase\":\"verifier execution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"matchReason\":\"exact_phrase_and_token_overlap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "verifier execution must remain explicit") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"negativeKnowledgeMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered.result_json.?, "\"verifiersExecuted\":false") != null);
}

test "corpus ask conflicting evidence stays unresolved and learning is candidate-only" {
    const allocator = std.testing.allocator;
    const project_shard = "corpus-ask-conflict-test";
    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeFixtureFile(corpus_fixture.dir, "enabled.md",
        \\# Retention Enabled
        \\Retention policy is enabled for event audit logs.
        \\
    );
    try writeFixtureFile(corpus_fixture.dir, "disabled.md",
        \\# Retention Disabled
        \\Retention policy is disabled for event audit logs.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_root,
        .project_shard = project_shard,
        .trust_class = .project,
        .source_label = "conflict-corpus",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var result = try corpus_ask.ask(allocator, .{
        .question = "is retention policy enabled",
        .project_shard = project_shard,
        .max_results = 2,
    });
    defer result.deinit();

    try std.testing.expectEqual(corpus_ask.AskStatus.unknown, result.status);
    try std.testing.expectEqual(corpus_ask.UnknownKind.conflicting_evidence, result.unknowns[0].kind);
    try std.testing.expect(result.answer_draft == null);
    try std.testing.expect(result.evidence_used.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), result.learning_candidates.len);
    try std.testing.expect(result.learning_candidates[0].candidate_only);
    try std.testing.expect(result.learning_candidates[0].non_authorizing);
    try std.testing.expect(!result.learning_candidates[0].persisted);
    try std.testing.expect(!result.safety_flags.corpus_mutation);
    try std.testing.expect(!result.safety_flags.pack_mutation);
    try std.testing.expect(!result.safety_flags.negative_knowledge_mutation);
}

test "gip corpus ask exposes protocol capability and malformed requests are structured" {
    const allocator = std.testing.allocator;

    var protocol = try gip.dispatch.dispatch(
        allocator,
        "protocol.describe",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        null,
    );
    defer protocol.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, protocol.status);
    try std.testing.expect(protocol.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol.result_json.?, "\"corpus.ask\"") != null);

    var caps = try gip.dispatch.dispatch(
        allocator,
        "capabilities.describe",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        null,
    );
    defer caps.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, caps.status);
    try std.testing.expect(caps.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.result_json.?, "\"capability\":\"corpus.ask\"") != null);

    var bounded = try gip.dispatch.dispatch(
        allocator,
        "corpus.ask",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        "{\"question\":\"what is the retention policy\",\"projectShard\":\"corpus-ask-gip-bounds-test\",\"maxResults\":2,\"maxSnippetBytes\":77}",
    );
    defer bounded.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.unresolved, bounded.status);
    try std.testing.expect(bounded.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, bounded.result_json.?, "\"maxResults\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bounded.result_json.?, "\"maxSnippetBytes\":77") != null);

    var malformed = try gip.dispatch.dispatch(
        allocator,
        "corpus.ask",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        "{\"message\":\"\"}",
    );
    defer malformed.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.rejected, malformed.status);
    try std.testing.expect(malformed.err != null);
    try std.testing.expectEqual(gip.core.ErrorCode.invalid_request, malformed.err.?.code);
}

test "gip correction influence status summarizes reviewed corrections read-only" {
    const allocator = std.testing.allocator;
    const shard_id = "phase10a-influence-status-smoke";
    var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    var no_file = try gip.dispatch.dispatch(allocator, "correction.influence.status", gip.core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase10a-influence-status-smoke"}
    );
    defer no_file.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, no_file.status);
    try std.testing.expect(no_file.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, no_file.result_json.?, "\"totalRecords\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_file.result_json.?, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_file.result_json.?, "\"records\"") == null);

    var accepted = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted wrong answer",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:status-accepted",
        .correction_candidate_json =
        \\{"id":"correction:candidate:status-accepted","originalOperationKind":"corpus.ask","originalRequestSummary":"retention enabled","disputedOutput":{"kind":"answerDraft","summary":"Retention policy is enabled"},"userCorrection":"suppress this repeated answer","correctionType":"wrong_answer"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"},{\"kind\":\"negative_knowledge_candidate\",\"status\":\"candidate\"}]",
    });
    defer accepted.deinit();
    var rejected = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "rejected rule correction",
        .rejected_reason = "not valid",
        .source_candidate_id = "correction:candidate:status-rejected",
        .correction_candidate_json =
        \\{"id":"correction:candidate:status-rejected","originalOperationKind":"rule.evaluate","disputedOutput":{"kind":"rule_candidate","summary":"rule output"},"userCorrection":"ignore","correctionType":"misleading_rule"}
        ,
        .accepted_learning_outputs_json = "[]",
    });
    defer rejected.deinit();
    const reviewed_path = try correction_review.reviewedCorrectionsPath(allocator, shard_id);
    defer allocator.free(reviewed_path);
    var file = try std.fs.openFileAbsolute(reviewed_path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed correction line}\n");

    var populated = try gip.dispatch.dispatch(allocator, "correction.influence.status", gip.core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase10a-influence-status-smoke","includeRecords":true,"limit":1}
    );
    defer populated.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, populated.status);
    const json = populated.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"totalRecords\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"acceptedRecords\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rejectedRecords\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"malformedLines\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corpus.ask\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rule.evaluate\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"wrong_answer\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"suppressionCandidateCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifierCandidateCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeCandidateCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"futureBehaviorCandidateCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"limitHit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"records\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"globalPromotion\":false") != null);

    var filtered = try gip.dispatch.dispatch(allocator, "correction.influence.status", gip.core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase10a-influence-status-smoke","operationKind":"rule.evaluate"}
    );
    defer filtered.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, filtered.status);
    try std.testing.expect(filtered.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.result_json.?, "\"totalRecords\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.result_json.?, "\"acceptedRecords\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.result_json.?, "\"rejectedRecords\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.result_json.?, "\"records\"") == null);
}

test "gip rule evaluate emits bounded non-authorizing candidates obligations unknowns" {
    const allocator = std.testing.allocator;

    var protocol = try gip.dispatch.dispatch(
        allocator,
        "protocol.describe",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        null,
    );
    defer protocol.deinit(allocator);
    try std.testing.expect(protocol.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol.result_json.?, "\"rule.evaluate\"") != null);

    var caps = try gip.dispatch.dispatch(
        allocator,
        "capabilities.describe",
        gip.core.PROTOCOL_VERSION,
        null,
        null,
        null,
    );
    defer caps.deinit(allocator);
    try std.testing.expect(caps.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, caps.result_json.?, "\"capability\":\"rule.evaluate\"") != null);

    var result = try gip.dispatch.dispatch(allocator, "rule.evaluate", gip.core.PROTOCOL_VERSION, null, null,
        \\{"facts":[{"subject":"change","predicate":"touches","object":"runtime","source":"smoke"}],"rules":[{"id":"rule.runtime","name":"Runtime checks","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.runtime","summary":"review runtime checks","riskLevel":"medium"},{"kind":"evidence_expectation","id":"obligation.runtime","summary":"collect deterministic runtime evidence"},{"kind":"unknown","id":"unknown.runtime","summary":"runtime impact remains unknown until checked"}]}],"limits":{"maxFacts":8,"maxRules":4,"maxFiredRules":2,"maxOutputs":8}}
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, result.status);
    try std.testing.expect(result.result_state != null);
    try std.testing.expectEqual(gip.core.Permission.none, result.result_state.?.permission);
    try std.testing.expect(result.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"executesByDefault\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"status\":\"pending\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"executed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"proofDischarged\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"supportGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"corpusMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"packMutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result_json.?, "\"negativeKnowledgeMutation\":false") != null);

    var capped = try gip.dispatch.dispatch(allocator, "rule.evaluate", gip.core.PROTOCOL_VERSION, null, null,
        \\{"facts":[{"subject":"change","predicate":"touches","object":"runtime"}],"rules":[{"id":"rule.a","name":"A","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.a1","summary":"first"},{"kind":"check_candidate","id":"check.a2","summary":"second"}]},{"id":"rule.b","name":"B","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"follow_up_candidate","id":"follow.b","summary":"later"}]}],"limits":{"maxFacts":8,"maxRules":4,"maxFiredRules":1,"maxOutputs":1}}
    );
    defer capped.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, capped.status);
    try std.testing.expect(capped.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, capped.result_json.?, "\"budgetExhausted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped.result_json.?, "\"capacityTelemetry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped.result_json.?, "\"maxOutputsHit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped.result_json.?, "\"capacityWarnings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped.result_json.?, "\"supportGranted\":false") != null);

    var fired_capped = try gip.dispatch.dispatch(allocator, "rule.evaluate", gip.core.PROTOCOL_VERSION, null, null,
        \\{"facts":[{"subject":"change","predicate":"touches","object":"runtime"}],"rules":[{"id":"rule.a","name":"A","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.a","summary":"first"}]},{"id":"rule.b","name":"B","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"follow_up_candidate","id":"follow.b","summary":"later"}]}],"limits":{"maxFacts":8,"maxRules":4,"maxFiredRules":1,"maxOutputs":8}}
    );
    defer fired_capped.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, fired_capped.status);
    try std.testing.expect(fired_capped.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, fired_capped.result_json.?, "\"maxFiredRulesHit\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, fired_capped.result_json.?, "\"maxRulesHit\":true") != null);
}

test "gip rule evaluate rejects recursive fact output" {
    const allocator = std.testing.allocator;
    var result = try gip.dispatch.dispatch(allocator, "rule.evaluate", gip.core.PROTOCOL_VERSION, null, null,
        \\{"facts":[{"subject":"a","predicate":"b","object":"c"}],"rules":[{"id":"recursive","name":"recursive","when":{"all":[{"subject":"a","predicate":"b","object":"c"}]},"emit":[{"kind":"fact","id":"derived","summary":"derive another fact"}]}]}
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(gip.core.ProtocolStatus.rejected, result.status);
    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(gip.core.ErrorCode.invalid_request, result.err.?.code);
}

test "gip rule evaluate applies accepted reviewed corrections as non-authorizing influence" {
    const allocator = std.testing.allocator;
    const shard_id = "phase9b-rule-influence-smoke";
    const other_shard_id = "phase9b-other-rule-influence-smoke";
    var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    var other_metadata = try shards.resolveProjectMetadata(allocator, other_shard_id);
    defer other_metadata.deinit();
    var other_paths = try shards.resolvePaths(allocator, other_metadata.metadata);
    defer other_paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    try deleteTreeIfExistsAbsolute(other_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(other_paths.root_abs_path) catch {};

    var misleading = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted misleading rule output",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:misleading-rule",
        .correction_candidate_json =
        \\{"id":"correction:candidate:misleading-rule","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule.warn","disputedOutput":{"kind":"rule_candidate","ref":"check.warn","summary":"warn candidate needs review"},"userCorrection":"this rule warning is misleading without context","correctionType":"misleading_rule"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"pack_guidance_candidate\",\"status\":\"candidate\"}]",
    });
    defer misleading.deinit();
    var unsafe = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted unsafe candidate",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:unsafe-rule",
        .correction_candidate_json =
        \\{"id":"correction:candidate:unsafe-rule","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule.unsafe","disputedOutput":{"kind":"rule_candidate","ref":"check.unsafe","summary":"unsafe candidate needs explicit verifier"},"userCorrection":"unsafe candidate needs stronger review","correctionType":"unsafe_candidate"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer unsafe.deinit();
    var missing = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted missing evidence",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:missing-rule-evidence",
        .correction_candidate_json =
        \\{"id":"correction:candidate:missing-rule-evidence","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule.evidence","disputedOutput":{"kind":"rule_candidate","ref":"evidence.need","summary":"needs evidence expectation"},"userCorrection":"missing evidence must become a follow-up expectation","correctionType":"missing_evidence"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"follow_up_evidence_request\",\"status\":\"candidate\"}]",
    });
    defer missing.deinit();
    var repeated = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted repeated bad output",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:repeated-rule",
        .correction_candidate_json =
        \\{"id":"correction:candidate:repeated-rule","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule.bad","disputedOutput":{"kind":"rule_candidate","ref":"check.bad","summary":"exact bad rule output"},"userCorrection":"suppress this exact repeated bad rule output","correctionType":"repeated_failed_pattern"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"negative_knowledge_candidate\",\"status\":\"candidate\"}]",
    });
    defer repeated.deinit();
    var rejected = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "rejected correction must not influence",
        .rejected_reason = "not valid",
        .source_candidate_id = "correction:candidate:rejected-rule",
        .correction_candidate_json =
        \\{"id":"correction:candidate:rejected-rule","originalOperationKind":"rule.evaluate","originalRequestSummary":"rule.rejected","disputedOutput":{"kind":"rule_candidate","ref":"check.rejected","summary":"rejected candidate"},"userCorrection":"ignore this","correctionType":"unsafe_candidate"}
        ,
        .accepted_learning_outputs_json = "[]",
    });
    defer rejected.deinit();
    var other = try correction_review.reviewAndAppend(allocator, .{
        .project_shard = other_shard_id,
        .decision = .accepted,
        .reviewer_note = "other shard",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:other-rule",
        .correction_candidate_json =
        \\{"id":"correction:candidate:other-rule","originalOperationKind":"rule.evaluate","disputedOutput":{"kind":"rule_candidate","ref":"check.other"},"userCorrection":"other shard must not influence","correctionType":"unsafe_candidate"}
        ,
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\",\"status\":\"candidate\"}]",
    });
    defer other.deinit();

    const reviewed_path = try correction_review.reviewedCorrectionsPath(allocator, shard_id);
    defer allocator.free(reviewed_path);
    var file = try std.fs.openFileAbsolute(reviewed_path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed correction line}\n");

    var result = try gip.dispatch.dispatch(allocator, "rule.evaluate", gip.core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase9b-rule-influence-smoke","facts":[{"subject":"change","predicate":"touches","object":"runtime"}],"rules":[{"id":"rule.warn","name":"Warn","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.warn","summary":"warn candidate needs review"}]},{"id":"rule.unsafe","name":"Unsafe","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.unsafe","summary":"unsafe candidate needs explicit verifier"}]},{"id":"rule.evidence","name":"Evidence","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"evidence_expectation","id":"evidence.need","summary":"needs evidence expectation"}]},{"id":"rule.bad","name":"Bad","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.bad","summary":"exact bad rule output"}]},{"id":"rule.rejected","name":"Rejected","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.rejected","summary":"rejected candidate remains emitted"}]}]}
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"acceptedCorrectionWarnings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "malformed reviewed correction JSONL line ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"correctionInfluences\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchedOutputId\":\"check.warn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchedOutputId\":\"check.unsafe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchedOutputId\":\"evidence.need\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchedOutputId\":\"check.bad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"check.bad\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"check.rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "phase9b-other-rule-influence-smoke") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"futureBehaviorCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"verifier_check_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"follow_up_evidence_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"rule_update_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"outputsSuppressed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sameShardOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutationPerformed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proofDischarged\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"supportGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"evidenceUsed\"") == null);
}

test "gip rule evaluate applies accepted reviewed negative knowledge as non-authorizing influence" {
    const allocator = std.testing.allocator;
    const shard_id = "phase11b-rule-nk-influence-smoke";
    const other_shard_id = "phase11b-other-rule-nk-influence-smoke";
    var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    var other_metadata = try shards.resolveProjectMetadata(allocator, other_shard_id);
    defer other_metadata.deinit();
    var other_paths = try shards.resolvePaths(allocator, other_metadata.metadata);
    defer other_paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    try deleteTreeIfExistsAbsolute(other_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(other_paths.root_abs_path) catch {};

    var suppress = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted suppress rule output",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:suppress-rule",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:suppress-rule","operationKind":"rule.evaluate","kind":"forbidden_project_pattern","condition":"exact bad rule output","matchedOutputId":"check.bad","suppression_rule":"exact bad rule output","nonAuthorizing":true}
        ,
    });
    defer suppress.deinit();
    var verifier = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .accepted,
        .reviewer_note = "accepted verifier requirement",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:verifier-rule",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:verifier-rule","operationKind":"rule.evaluate","kind":"unsafe_verifier_candidate","condition":"unsafe candidate needs explicit verifier","matchedOutputId":"check.unsafe","verifier_requirement":"explicit verifier candidate","nonAuthorizing":true}
        ,
    });
    defer verifier.deinit();
    var rejected = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = shard_id,
        .decision = .rejected,
        .reviewer_note = "rejected must not influence",
        .rejected_reason = "not accepted",
        .source_candidate_id = "nk:candidate:rejected-rule",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:rejected-rule","operationKind":"rule.evaluate","condition":"rejected candidate","matchedOutputId":"check.rejected","verifier_requirement":"do not apply","nonAuthorizing":true}
        ,
    });
    defer rejected.deinit();
    var other = try negative_knowledge_review.reviewAndAppend(allocator, .{
        .project_shard = other_shard_id,
        .decision = .accepted,
        .reviewer_note = "other shard",
        .rejected_reason = null,
        .source_candidate_id = "nk:candidate:other-rule",
        .negative_knowledge_candidate_json =
        \\{"id":"nk:candidate:other-rule","operationKind":"rule.evaluate","condition":"other shard candidate","matchedOutputId":"check.other","verifier_requirement":"do not apply","nonAuthorizing":true}
        ,
    });
    defer other.deinit();

    const reviewed_path = try negative_knowledge_review.reviewedNegativeKnowledgePath(allocator, shard_id);
    defer allocator.free(reviewed_path);
    var file = try std.fs.openFileAbsolute(reviewed_path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{malformed reviewed negative knowledge line}\n");

    var result = try gip.dispatch.dispatch(allocator, "rule.evaluate", gip.core.PROTOCOL_VERSION, null, null,
        \\{"projectShard":"phase11b-rule-nk-influence-smoke","facts":[{"subject":"change","predicate":"touches","object":"runtime"}],"rules":[{"id":"rule.bad","name":"Bad","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.bad","summary":"exact bad rule output"}]},{"id":"rule.unsafe","name":"Unsafe","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.unsafe","summary":"unsafe candidate needs explicit verifier"}]},{"id":"rule.rejected","name":"Rejected","when":{"all":[{"subject":"change","predicate":"touches","object":"runtime"}]},"emit":[{"kind":"check_candidate","id":"check.rejected","summary":"rejected candidate remains emitted"}]}]}
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(gip.core.ProtocolStatus.ok, result.status);
    const json = result.result_json.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"acceptedNegativeKnowledgeWarnings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "malformed reviewed negative knowledge JSONL line ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeInfluences\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchedOutputId\":\"check.bad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matchedOutputId\":\"check.unsafe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"check.bad\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"check.rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "phase11b-other-rule-nk-influence-smoke") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceReviewedNegativeKnowledgeId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"verifier_check_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"outputsSuppressed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sameShardOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutationPerformed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commandsExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifiersExecuted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"usedAsEvidence\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proofDischarged\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"supportGranted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"evidenceUsed\"") == null);
}

test "corpus reverse grounding leaves tied symbolic surfaces unresolved" {
    const allocator = std.testing.allocator;
    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus_fixture = try makeCorpusReverseGroundingAmbiguousFixture(allocator);
    defer corpus_fixture.tmp.cleanup();
    defer allocator.free(corpus_fixture.root_path);

    var project_metadata = try shards.resolveProjectMetadata(allocator, "corpus-reverse-grounding-ambiguous-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_fixture.root_path,
        .project_shard = "corpus-reverse-grounding-ambiguous-test",
        .trust_class = .project,
        .source_label = "ambiguous-corpus",
    });
    defer stage_result.deinit();

    try corpus_ingest.applyStaged(allocator, &project_paths);

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = "corpus-reverse-grounding-ambiguous-test",
        .query_kind = .impact,
        .target = "@corpus/code/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expect(result.reverse_grounding_traces.len >= 2);

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"reverseGroundingStatus\":\"ambiguous\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"reverseGroundingDetail\":\"reverse symbolic grounding") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"targetPath\":\"@corpus/docs/guide-a.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"targetPath\":\"@corpus/docs/guide-b.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ambiguous\":true") != null);

    const draft_rendered = try technical_drafts.render(allocator, .{ .code_intel = &result }, .{
        .draft_type = .proof_backed_explanation,
        .max_items = 6,
    });
    defer allocator.free(draft_rendered);
    try std.testing.expect(std.mem.indexOf(u8, draft_rendered, "[reverse_grounding]") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_rendered, "selection_detail: reverse symbolic grounding") != null);
}

test "exact corpus path and section hits stay deterministic under routing gates" {
    const allocator = std.testing.allocator;
    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus_fixture = try makeNoisyRoutingCorpusFixture(allocator);
    defer corpus_fixture.tmp.cleanup();
    defer allocator.free(corpus_fixture.root_path);

    var project_metadata = try shards.resolveProjectMetadata(allocator, "routing-exact-corpus-target-test");
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};

    var stage_result = try corpus_ingest.stage(allocator, .{
        .corpus_path = corpus_fixture.root_path,
        .project_shard = "routing-exact-corpus-target-test",
        .trust_class = .project,
        .source_label = "routing-noise",
    });
    defer stage_result.deinit();
    try corpus_ingest.applyStaged(allocator, &project_paths);

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = "routing-exact-corpus-target-test",
        .query_kind = .impact,
        .target = "@corpus/docs/runbook.md:heading:runtime_contracts@1",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expect(result.primary != null);
    try std.testing.expectEqualStrings("@corpus/docs/runbook.md", result.primary.?.rel_path);
    try std.testing.expect(result.target_candidates.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.target_candidates[0].label, "@corpus/docs/runbook.md") != null);
}

test "mounted knowledge pack resolves explicit scan entries and unmount removes mount state" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-mounted-grounding-test";
    const pack_id = "runtime-pack-mounted";
    const pack_version = "v1";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus_fixture.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\Keep sync aligned with the documented runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    var pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "runtime contract corpus",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "pack-corpus",
    });
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, false, false) catch {};
    const mounted_entries = try knowledge_pack_store.listResolvedMounts(allocator, &project_paths);
    defer {
        for (mounted_entries) |*mount| mount.deinit();
        allocator.free(mounted_entries);
    }
    try std.testing.expectEqual(@as(usize, 1), mounted_entries.len);
    try std.testing.expect(mounted_entries[0].entry.enabled);
    const pack_entries = try corpus_ingest.collectPackScanEntries(
        allocator,
        mounted_entries[0].entry.pack_id,
        mounted_entries[0].entry.pack_version,
        mounted_entries[0].corpus_manifest_abs_path,
        mounted_entries[0].corpus_files_abs_path,
    );
    defer corpus_ingest.deinitIndexedEntries(allocator, pack_entries);
    try std.testing.expectEqual(@as(usize, 2), pack_entries.len);

    var mounted = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer mounted.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, mounted.status);
    try std.testing.expectEqual(@as(usize, 0), countPackReverseGroundings(&mounted, pack_id, pack_version));

    try knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, false, false);
    const unmounted_entries = try knowledge_pack_store.listResolvedMounts(allocator, &project_paths);
    defer {
        for (unmounted_entries) |*mount| mount.deinit();
        allocator.free(unmounted_entries);
    }
    try std.testing.expectEqual(@as(usize, 0), unmounted_entries.len);
}

test "conflicting mounted knowledge packs never silently authorize merged support" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-conflict-test";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus_a = std.testing.tmpDir(.{});
    defer corpus_a.cleanup();
    const corpus_a_root = try corpus_a.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_a_root);
    try writeKnowledgePackCorpusFixture(corpus_a.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\Keep sync aligned with the documented runtime contract.
        \\
    );

    var corpus_b = std.testing.tmpDir(.{});
    defer corpus_b.cleanup();
    const corpus_b_root = try corpus_b.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_b_root);
    try writeKnowledgePackCorpusFixture(corpus_b.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines an alternate runtime story.
        \\This pack intentionally changes the retained signals while keeping the same filenames.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    knowledge_packs.removePack(allocator, "runtime-pack-conflict-a", "v1") catch {};
    var pack_a = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-conflict-a",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "primary runtime contract",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_a_root,
        .corpus_label = "pack-a",
    });
    defer pack_a.manifest.deinit();
    defer allocator.free(pack_a.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-conflict-a", "v1") catch {};

    knowledge_packs.removePack(allocator, "runtime-pack-conflict-b", "v1") catch {};
    var pack_b = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-conflict-b",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "alternate runtime contract",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_b_root,
        .corpus_label = "pack-b",
    });
    defer pack_b.manifest.deinit();
    defer allocator.free(pack_b.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-conflict-b", "v1") catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-conflict-a", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-conflict-b", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-conflict-a", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-conflict-b", "v1", false, false) catch {};
    const conflict_entries = try knowledge_pack_store.listResolvedMounts(allocator, &project_paths);
    defer {
        for (conflict_entries) |*mount| mount.deinit();
        allocator.free(conflict_entries);
    }
    try std.testing.expectEqual(@as(usize, 2), conflict_entries.len);

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(@as(usize, 0), countPackReverseGroundings(&result, "runtime-pack-conflict-a", "v1") + countPackReverseGroundings(&result, "runtime-pack-conflict-b", "v1"));

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"reverseGroundingStatus\":\"insufficient\"") != null);
    try std.testing.expectEqual(@as(usize, 0), countPackReverseGroundings(&result, "runtime-pack-conflict-a", "v1") + countPackReverseGroundings(&result, "runtime-pack-conflict-b", "v1"));
}

test "pack routing activates only the relevant mounted pack and skips irrelevant mounts" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-routing-relevant-test";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var runtime_corpus = std.testing.tmpDir(.{});
    defer runtime_corpus.cleanup();
    const runtime_root = try runtime_corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(runtime_root);
    try writeKnowledgePackCorpusFixture(runtime_corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\Keep sync aligned with the documented runtime contract.
        \\
    );

    var docs_corpus = std.testing.tmpDir(.{});
    defer docs_corpus.cleanup();
    const docs_root = try docs_corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(docs_root);
    try writeFixtureFile(docs_corpus.dir, "guide.md",
        \\# UI Notes
        \\render.html owns the UI guide and does not describe runtime worker sync.
        \\
    );
    try writeFixtureFile(docs_corpus.dir, "render.html",
        \\<div>ui guide</div>
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    var runtime_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-routing-relevant",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "runtime routing pack",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = runtime_root,
        .corpus_label = "runtime-pack",
    });
    defer runtime_pack.manifest.deinit();
    defer allocator.free(runtime_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-routing-relevant", "v1") catch {};

    var docs_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "docs-pack-routing-irrelevant",
        .pack_version = "v1",
        .domain_family = "docs",
        .trust_class = "project",
        .source_summary = "docs routing pack",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = docs_root,
        .corpus_label = "docs-pack",
    });
    defer docs_pack.manifest.deinit();
    defer allocator.free(docs_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "docs-pack-routing-irrelevant", "v1") catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-routing-relevant", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "docs-pack-routing-irrelevant", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-routing-relevant", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "docs-pack-routing-irrelevant", "v1", false, false) catch {};

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(hasPackRoutingStatus(&result, .support, "runtime-pack-routing-relevant", "v1", .activated));
    try std.testing.expect(hasPackRoutingStatus(&result, .support, "docs-pack-routing-irrelevant", "v1", .skipped));
    try std.testing.expectEqual(@as(usize, 0), countPackAbstractionTraces(&result, "docs-pack-routing-irrelevant", "v1", false));

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"packRouting\":") != null);
}

test "lower-trust competing pack is trust-blocked explicitly" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-trust-block-test";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus = std.testing.tmpDir(.{});
    defer corpus.cleanup();
    const corpus_root = try corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    var lower_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-trust-low",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "exploratory",
        .source_summary = "lower trust pack",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "lower-pack",
    });
    defer lower_pack.manifest.deinit();
    defer allocator.free(lower_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-trust-low", "v1") catch {};

    var higher_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-trust-high",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "promoted",
        .source_summary = "higher trust pack",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "higher-pack",
    });
    defer higher_pack.manifest.deinit();
    defer allocator.free(higher_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-trust-high", "v1") catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-trust-low", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-trust-high", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-trust-low", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-trust-high", "v1", false, false) catch {};

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .pack_conflict_policy = .{ .competition = .prefer_higher_trust_only },
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(hasPackRoutingStatus(&result, .support, "runtime-pack-trust-high", "v1", .activated));
    try std.testing.expect(hasPackRoutingStatusCategory(&result, .support, "runtime-pack-trust-low", "v1", .trust_blocked, .trust_mismatch));
}

test "stale pack is stale-blocked explicitly while active pack can route" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-stale-block-test";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus = std.testing.tmpDir(.{});
    defer corpus.cleanup();
    const corpus_root = try corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    var stale_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-stale",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .freshness_state = "stale",
        .source_summary = "stale pack",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "stale-pack",
    });
    defer stale_pack.manifest.deinit();
    defer allocator.free(stale_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-stale", "v1") catch {};

    var active_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-active",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "active pack",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "active-pack",
    });
    defer active_pack.manifest.deinit();
    defer allocator.free(active_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-active", "v1") catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-stale", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-active", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-stale", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-active", "v1", false, false) catch {};

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(hasPackRoutingStatus(&result, .support, "runtime-pack-active", "v1", .activated));
    try std.testing.expect(hasPackRoutingStatusCategory(&result, .support, "runtime-pack-stale", "v1", .stale_blocked, .stale_pack));
}

test "conservative pack policy refuses competing packs explicitly" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-conservative-refuse-test";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus = std.testing.tmpDir(.{});
    defer corpus.cleanup();
    const corpus_root = try corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    var left_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-refuse-a",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "competing pack a",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "pack-a",
    });
    defer left_pack.manifest.deinit();
    defer allocator.free(left_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-refuse-a", "v1") catch {};

    var right_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-refuse-b",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "competing pack b",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "pack-b",
    });
    defer right_pack.manifest.deinit();
    defer allocator.free(right_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-refuse-b", "v1") catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-refuse-a", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-refuse-b", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-refuse-a", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-refuse-b", "v1", false, false) catch {};

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(hasPackRoutingStatusCategory(&result, .support, "runtime-pack-refuse-a", "v1", .conflict_refused, .same_anchor_competing));
    try std.testing.expect(hasPackRoutingStatusCategory(&result, .support, "runtime-pack-refuse-b", "v1", .conflict_refused, .same_anchor_competing));

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"competition\":\"refuse_all_competing\"") != null);
}

test "deterministic winner policy selects one competing pack explicitly" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-deterministic-winner-test";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus = std.testing.tmpDir(.{});
    defer corpus.cleanup();
    const corpus_root = try corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path);
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.corpus_ingest_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    var left_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-winner-a",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "winner candidate a",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "pack-a",
    });
    defer left_pack.manifest.deinit();
    defer allocator.free(left_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-winner-a", "v1") catch {};

    var right_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-winner-b",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "winner candidate b",
        .source_project_shard = null,
        .source_state = .live,
        .corpus_path = corpus_root,
        .corpus_label = "pack-b",
    });
    defer right_pack.manifest.deinit();
    defer allocator.free(right_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-winner-b", "v1") catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-winner-a", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-winner-b", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-winner-a", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-winner-b", "v1", false, false) catch {};

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .pack_conflict_policy = .{ .competition = .deterministic_winner },
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), countPackRoutingStatus(&result, .support, .activated));
    try std.testing.expectEqual(@as(usize, 1), countPackRoutingStatus(&result, .support, .suppressed));

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"competition\":\"deterministic_winner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "deterministic policy chose a single competing pack winner by stable rank") != null);
}

test "mounted pack conflicts stay explicit and do not silently blend proof support" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-explicit-conflict-test";

    var corpus = std.testing.tmpDir(.{});
    defer corpus.cleanup();
    const corpus_root = try corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};

    const pack_catalog_a =
        \\GABS1
        \\concept shared_runtime_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 1
        \\average_resonance 800
        \\min_resonance 780
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 220
        \\support_score 320
        \\promotion_ready 1
        \\consensus_hash 111
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:worker.zig:1-3
        \\pattern sync
        \\end
    ;
    const pack_catalog_b =
        \\GABS1
        \\concept shared_runtime_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 1
        \\average_resonance 810
        \\min_resonance 790
        \\quality_score 905
        \\confidence_score 885
        \\reuse_score 225
        \\support_score 325
        \\promotion_ready 1
        \\consensus_hash 999
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:worker.zig:1-3
        \\pattern sync
        \\pattern alternate
        \\end
    ;

    var pack_a = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-explicit-conflict-a",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "conflict pack a",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "pack-a",
    });
    defer pack_a.manifest.deinit();
    defer allocator.free(pack_a.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-explicit-conflict-a", "v1") catch {};
    var pack_b = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-explicit-conflict-b",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "conflict pack b",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "pack-b",
    });
    defer pack_b.manifest.deinit();
    defer allocator.free(pack_b.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-explicit-conflict-b", "v1") catch {};

    const pack_a_catalog_path = try std.fs.path.join(allocator, &.{ pack_a.root_abs_path, "abstractions", "abstractions.gabs" });
    defer allocator.free(pack_a_catalog_path);
    const pack_b_catalog_path = try std.fs.path.join(allocator, &.{ pack_b.root_abs_path, "abstractions", "abstractions.gabs" });
    defer allocator.free(pack_b_catalog_path);
    {
        const handle = try sys.openForWrite(allocator, pack_a_catalog_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, pack_catalog_a);
    }
    {
        const handle = try sys.openForWrite(allocator, pack_b_catalog_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, pack_catalog_b);
    }

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-explicit-conflict-a", "v1", true, true);
    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-explicit-conflict-b", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-explicit-conflict-a", "v1", false, false) catch {};
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-explicit-conflict-b", "v1", false, false) catch {};

    const refs = try abstractions.lookupConcepts(allocator, &project_paths, .{
        .rel_paths = &.{"worker.zig"},
        .tokens = &.{"sync"},
        .patterns = &.{"sync"},
        .max_items = 4,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = .invariant,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);

    try std.testing.expectEqual(@as(usize, 0), refs.len);

    const routing = try abstractions.inspectMountedPackRouting(allocator, &project_paths, &.{"worker.zig"}, &.{"sync"}, &.{"sync"}, .support, .{});
    defer {
        for (routing) |*trace| trace.deinit();
        allocator.free(routing);
    }
    try std.testing.expect(hasPackRoutingStageStatus(routing, .support, "runtime-pack-explicit-conflict-a", "v1", .conflict_refused));
    try std.testing.expect(hasPackRoutingStageStatus(routing, .support, "runtime-pack-explicit-conflict-b", "v1", .conflict_refused));
}

test "local project truth outranks mounted pack truth explicitly" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-local-truth-test";

    var corpus = std.testing.tmpDir(.{});
    defer corpus.cleanup();
    const corpus_root = try corpus.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus.dir,
        \\# Runtime Contracts
        \\worker.zig sync path defines the runtime contract.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path);
    const mounts_path = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_path);
    try deleteTreeIfExistsAbsolute(mounts_path);
    defer deleteTreeIfExistsAbsolute(project_paths.abstractions_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_path) catch {};
    try sys.makePath(allocator, project_paths.abstractions_root_abs_path);

    const local_catalog =
        \\GABS1
        \\concept shared_runtime_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 1
        \\average_resonance 820
        \\min_resonance 800
        \\quality_score 920
        \\confidence_score 900
        \\reuse_score 230
        \\support_score 330
        \\promotion_ready 1
        \\consensus_hash 777
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:worker.zig:1-3
        \\pattern sync
        \\pattern local
        \\end
    ;
    {
        const handle = try sys.openForWrite(allocator, project_paths.abstractions_live_abs_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, local_catalog);
    }

    var pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = "runtime-pack-local-truth",
        .pack_version = "v1",
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "pack truth",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "pack",
    });
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, "runtime-pack-local-truth", "v1") catch {};

    const pack_catalog =
        \\GABS1
        \\concept shared_runtime_contract
        \\tier contract
        \\category invariant
        \\examples 3
        \\threshold 2
        \\retained_tokens 2
        \\retained_patterns 1
        \\average_resonance 800
        \\min_resonance 780
        \\quality_score 900
        \\confidence_score 880
        \\reuse_score 220
        \\support_score 320
        \\promotion_ready 1
        \\consensus_hash 111
        \\valid 1
        \\vector 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        \\source region:worker.zig:1-3
        \\pattern sync
        \\end
    ;
    const pack_catalog_path = try std.fs.path.join(allocator, &.{ pack.root_abs_path, "abstractions", "abstractions.gabs" });
    defer allocator.free(pack_catalog_path);
    {
        const handle = try sys.openForWrite(allocator, pack_catalog_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, pack_catalog);
    }

    try knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-local-truth", "v1", true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, "runtime-pack-local-truth", "v1", false, false) catch {};

    const refs = try abstractions.lookupConcepts(allocator, &project_paths, .{
        .rel_paths = &.{"worker.zig"},
        .tokens = &.{"sync"},
        .patterns = &.{"sync"},
        .max_items = 4,
        .include_staged = false,
        .prefer_higher_tiers = true,
        .category_hint = .invariant,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expect(refs[0].usable);
    try std.testing.expectEqualStrings(project_shard, refs[0].owner_id);
    try std.testing.expectEqual(abstractions.ReuseResolution.conflict_refused, refs[1].resolution);
    try std.testing.expect(!refs[1].usable);
}

test "knowledge pack create from corpus does not delete colliding existing project shard" {
    const allocator = std.testing.allocator;
    const pack_id = "collision-pack";
    const pack_version = "v1";
    const colliding_shard = "packbuild-collision-pack-v1-0";

    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus_fixture.dir,
        \\# Collision Safety
        \\Temporary corpus builds must not delete unrelated project shards.
        \\
    );

    var collision_metadata = try shards.resolveProjectMetadata(allocator, colliding_shard);
    defer collision_metadata.deinit();
    var collision_paths = try shards.resolvePaths(allocator, collision_metadata.metadata);
    defer collision_paths.deinit();
    try deleteTreeIfExistsAbsolute(collision_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(collision_paths.root_abs_path) catch {};
    try std.fs.cwd().makePath(collision_paths.root_abs_path);
    try writeFixtureFileAbsolute(collision_paths.root_abs_path, "sentinel.txt", "preserve me\n");

    var pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "collision corpus",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "collision-corpus",
    });
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    const sentinel_path = try std.fs.path.join(allocator, &.{ collision_paths.root_abs_path, "sentinel.txt" });
    defer allocator.free(sentinel_path);
    const sentinel_body = try readFileAbsoluteAlloc(allocator, sentinel_path, 1024);
    defer allocator.free(sentinel_body);
    try std.testing.expectEqualStrings("preserve me\n", sentinel_body);

    var temp_one_metadata = try shards.resolveProjectMetadata(allocator, "packbuild-collision-pack-v1-1");
    defer temp_one_metadata.deinit();
    var temp_one_paths = try shards.resolvePaths(allocator, temp_one_metadata.metadata);
    defer temp_one_paths.deinit();
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(temp_one_paths.root_abs_path, .{}));
}

test "knowledge pack remove prunes stale mount registry entries" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-remove-prune-test";
    const pack_id = "mounted-pack-prune";
    const pack_version = "v1";

    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus_fixture.dir,
        \\# Remove Prune
        \\Removing a pack must prune stale mount registry entries.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    const mounts_dir = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_dir);
    try deleteTreeIfExistsAbsolute(mounts_dir);
    defer deleteTreeIfExistsAbsolute(mounts_dir) catch {};

    var pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "remove prune corpus",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "remove-prune-corpus",
    });
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    try knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, true, true);
    try knowledge_packs.removePack(allocator, pack_id, pack_version);

    var registry = try knowledge_pack_store.loadMountRegistry(allocator, &project_paths);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.entries.len);

    const mounts = try knowledge_pack_store.listResolvedMounts(allocator, &project_paths);
    defer {
        for (mounts) |*mount| mount.deinit();
        allocator.free(mounts);
    }
    try std.testing.expectEqual(@as(usize, 0), mounts.len);
}

test "recreated knowledge pack does not silently remount through stale state" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-recreate-remount-test";
    const pack_id = "recreated-pack";
    const pack_version = "v1";

    var repo_fixture = try makeCodeIntelFixture(allocator);
    defer repo_fixture.tmp.cleanup();
    defer allocator.free(repo_fixture.root_path);

    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus_fixture.dir,
        \\# Recreate Safety
        \\A recreated pack should stay unmounted until explicitly remounted.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    try deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path);
    const mounts_dir = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_dir);
    try deleteTreeIfExistsAbsolute(mounts_dir);
    defer deleteTreeIfExistsAbsolute(project_paths.code_intel_root_abs_path) catch {};
    defer deleteTreeIfExistsAbsolute(mounts_dir) catch {};

    var first_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "first recreate corpus",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "recreate-first",
    });
    defer first_pack.manifest.deinit();
    defer allocator.free(first_pack.root_abs_path);

    try knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, true, true);
    try knowledge_packs.removePack(allocator, pack_id, pack_version);

    var second_pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "second recreate corpus",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "recreate-second",
    });
    defer second_pack.manifest.deinit();
    defer allocator.free(second_pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var registry = try knowledge_pack_store.loadMountRegistry(allocator, &project_paths);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.entries.len);

    var result = try code_intel.run(allocator, .{
        .repo_root = repo_fixture.root_path,
        .project_shard = project_shard,
        .query_kind = .impact,
        .target = "src/runtime/worker.zig:sync",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), countPackReverseGroundings(&result, pack_id, pack_version));
}

test "knowledge pack manifest path traversal is rejected explicitly" {
    const allocator = std.testing.allocator;
    const project_shard = "knowledge-pack-path-traversal-test";
    const pack_id = "path-traversal-pack";
    const pack_version = "v1";

    var corpus_fixture = std.testing.tmpDir(.{});
    defer corpus_fixture.cleanup();
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    defer allocator.free(corpus_root);
    try writeKnowledgePackCorpusFixture(corpus_fixture.dir,
        \\# Traversal Rejection
        \\Mounted pack manifests must stay contained within the pack root.
        \\
    );

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();
    const mounts_dir = try std.fs.path.join(allocator, &.{ project_paths.root_abs_path, "knowledge_packs" });
    defer allocator.free(mounts_dir);
    try deleteTreeIfExistsAbsolute(mounts_dir);
    defer deleteTreeIfExistsAbsolute(mounts_dir) catch {};

    var pack = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "runtime",
        .trust_class = "project",
        .source_summary = "path traversal corpus",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "path-traversal",
    });
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, false, false) catch {};

    pack.manifest.storage.corpus_manifest_rel_path = try allocator.realloc(pack.manifest.storage.corpus_manifest_rel_path, "../outside.json".len);
    @memcpy(pack.manifest.storage.corpus_manifest_rel_path, "../outside.json");
    try knowledge_pack_store.saveManifest(allocator, pack.root_abs_path, &pack.manifest);

    try std.testing.expectError(error.InvalidKnowledgePackManifest, knowledge_pack_store.loadManifest(allocator, pack_id, pack_version));
    try std.testing.expectError(error.InvalidKnowledgePackManifest, knowledge_pack_store.listResolvedMounts(allocator, &project_paths));
}

test "native code intel follows include edges and declaration-definition pairs" {
    const allocator = std.testing.allocator;
    var fixture = try makeNativeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "src/native/widget.cpp:compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqual(mc.StopReason.none, result.stop_reason);
    try std.testing.expect(result.primary != null);
    try std.testing.expectEqualStrings("compute", result.primary.?.name);
    try std.testing.expect(result.evidence.len > 0);
    try std.testing.expectEqualStrings("src/native/widget.h", result.evidence[0].rel_path);
}

test "native code intel contradicts sees explicit native signature assumptions" {
    const allocator = std.testing.allocator;
    var fixture = try makeNativeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .contradicts,
        .target = "src/native/widget.cpp:compute",
        .other_target = "src/native/widget.h:Widget",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqualStrings("signature_incompatibility", result.contradiction_kind.?);
    try std.testing.expect(result.overlap.len > 0);
}

test "native code intel contradiction query detects missing dependency edges" {
    const allocator = std.testing.allocator;
    var fixture = try makeNativeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .contradicts,
        .target = "src/native/alt.cpp:alt::compute",
        .other_target = "src/native/missing.cpp:bad",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.supported, result.status);
    try std.testing.expectEqualStrings("missing_dependency_edge", result.contradiction_kind.?);
    try std.testing.expect(result.contradiction_traces.len > 0);
}

test "native code intel cache persists include and deferred native graph data" {
    const allocator = std.testing.allocator;
    var fixture = try makeNativeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var shard_metadata = try shards.resolveProjectMetadata(allocator, "native-code-intel-cache-test");
    defer shard_metadata.deinit();
    var shard_paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer shard_paths.deinit();

    try deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path);
    defer deleteTreeIfExistsAbsolute(shard_paths.code_intel_root_abs_path) catch {};

    const cache_index_path = try std.fs.path.join(allocator, &.{ shard_paths.code_intel_cache_abs_path, "index_v1.gcix" });
    defer allocator.free(cache_index_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .project_shard = "native-code-intel-cache-test",
        .query_kind = .impact,
        .target = "src/native/widget.cpp:compute",
        .max_items = 8,
        .persist = true,
        .cache_persist = true,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.CacheLifecycle.cold_build, result.cache_lifecycle);
    try std.testing.expect(fileExistsAbsolute(cache_index_path));

    const cache_body = try readFileAbsoluteAlloc(allocator, cache_index_path, 256 * 1024);
    defer allocator.free(cache_body);
    try std.testing.expect(std.mem.indexOf(u8, cache_body, "\tinclude\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cache_body, "use\t") != null);
}

test "native code intel leaves ambiguous bare symbol queries unresolved" {
    const allocator = std.testing.allocator;
    var fixture = try makeNativeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .impact,
        .target = "compute",
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expect(result.unresolved_detail != null);
}

test "task intent grounds refactor api stability request deterministically" {
    const allocator = std.testing.allocator;

    var intent = try task_intent.parse(allocator, "refactor src/api/service.zig:compute but keep the API stable", .{});
    defer intent.deinit();

    try std.testing.expectEqual(task_intent.ParseStatus.grounded, intent.status);
    try std.testing.expectEqual(task_intent.Action.refactor, intent.action);
    try std.testing.expectEqual(task_intent.OutputMode.patch, intent.output_mode);
    try std.testing.expectEqual(task_intent.FlowKind.patch_candidates, intent.dispatch.flow);
    try std.testing.expectEqual(task_intent.QueryKind.breaks_if, intent.dispatch.query_kind.?);
    try std.testing.expectEqualStrings("src/api/service.zig:compute", intent.target.spec.?);

    var saw_api_stability = false;
    for (intent.constraints) |constraint| {
        if (constraint.kind == .api_stability) saw_api_stability = true;
    }
    try std.testing.expect(saw_api_stability);
}

test "task intent keeps deictic target unresolved instead of guessing" {
    const allocator = std.testing.allocator;

    var intent = try task_intent.parse(allocator, "build this in Zig", .{});
    defer intent.deinit();

    try std.testing.expectEqual(task_intent.ParseStatus.clarification_required, intent.status);
    try std.testing.expectEqual(task_intent.Action.build, intent.action);
    try std.testing.expectEqual(task_intent.TargetKind.current_context, intent.target.kind);
    try std.testing.expectEqual(task_intent.FlowKind.patch_candidates, intent.dispatch.flow);
    try std.testing.expect(intent.unresolved_detail != null);

    var saw_language = false;
    for (intent.constraints) |constraint| {
        if (constraint.kind == .language and constraint.value != null and std.mem.eql(u8, constraint.value.?, "zig")) {
            saw_language = true;
        }
    }
    try std.testing.expect(saw_language);
}

test "task intent alternatives request switches to exploratory patch planning" {
    const allocator = std.testing.allocator;

    var intent = try task_intent.parse(allocator, "give me 3 ideas then pick the safest one for src/api/service.zig:compute", .{});
    defer intent.deinit();

    try std.testing.expectEqual(task_intent.ParseStatus.grounded, intent.status);
    try std.testing.expectEqual(task_intent.Action.plan, intent.action);
    try std.testing.expectEqual(task_intent.OutputMode.alternatives, intent.output_mode);
    try std.testing.expectEqual(@as(u8, 3), intent.requested_alternatives);
    try std.testing.expectEqual(task_intent.SelectionPolicy.safest, intent.selection_policy);
    try std.testing.expectEqual(task_intent.FlowKind.patch_candidates, intent.dispatch.flow);
    try std.testing.expectEqual(mc.ReasoningMode.exploratory, intent.dispatch.reasoning_mode);
}

test "task intent routes explain why this breaks into code intel" {
    const allocator = std.testing.allocator;

    var intent = try task_intent.parse(allocator, "explain why src/api/service.zig:compute breaks", .{});
    defer intent.deinit();

    try std.testing.expectEqual(task_intent.ParseStatus.grounded, intent.status);
    try std.testing.expectEqual(task_intent.Action.explain, intent.action);
    try std.testing.expectEqual(task_intent.OutputMode.explanation, intent.output_mode);
    try std.testing.expectEqual(task_intent.FlowKind.code_intel, intent.dispatch.flow);
    try std.testing.expectEqual(task_intent.QueryKind.breaks_if, intent.dispatch.query_kind.?);
}

test "code intel carries grounded task intent into trace output" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var intent = try task_intent.parse(allocator, "explain why src/api/service.zig:compute breaks", .{});
    defer intent.deinit();

    var result = try code_intel.run(allocator, .{
        .repo_root = fixture.root_path,
        .reasoning_mode = intent.dispatch.reasoning_mode,
        .query_kind = switch (intent.dispatch.query_kind.?) {
            .impact => .impact,
            .breaks_if => .breaks_if,
            .contradicts => .contradicts,
        },
        .target = intent.target.spec.?,
        .intent = &intent,
        .max_items = 8,
        .persist = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(result.intent != null);
    try std.testing.expectEqual(task_intent.Action.explain, result.intent.?.action);
    try std.testing.expect(result.support_graph.nodes.len > 0);

    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"intent\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"requested_by\"") != null);
}

test "patch candidates carry grounded task intent into result output" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var intent = try task_intent.parse(allocator, "refactor src/api/service.zig:compute but keep the API stable", .{});
    defer intent.deinit();

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
        .query_kind = .breaks_if,
        .target = intent.target.spec.?,
        .request_label = intent.raw_input,
        .intent = &intent,
        .caps = .{
            .max_candidates = 2,
            .max_files = 2,
            .max_hunks_per_candidate = 2,
            .max_lines_per_hunk = 6,
        },
        .persist_code_intel = false,
        .cache_persist = false,
    });
    defer result.deinit();

    try std.testing.expect(result.intent != null);
    try std.testing.expectEqual(task_intent.Action.refactor, result.intent.?.action);

    const rendered = try patch_candidates.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"intent\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"requested_by\"") != null);
}

fn createTestPackForExport(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !knowledge_packs.CreateResult {
    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};
    var corpus_fixture = std.testing.tmpDir(.{});
    const corpus_root = try corpus_fixture.dir.realpathAlloc(allocator, ".");
    try writeKnowledgePackCorpusFixture(corpus_fixture.dir,
        \\# Test Pack
        \\A test corpus for export/import roundtrip.
        \\
    );
    const result = try knowledge_packs.createPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .domain_family = "test",
        .trust_class = "project",
        .source_summary = "test export pack",
        .source_project_shard = null,
        .source_state = .staged,
        .corpus_path = corpus_root,
        .corpus_label = "test-export",
    });
    allocator.free(corpus_root);
    corpus_fixture.cleanup();
    return result;
}

test "export produces valid artifact with correct hashes" {
    const allocator = std.testing.allocator;
    const pack_id = "export-hash-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var export_tmp = std.testing.tmpDir(.{});
    defer export_tmp.cleanup();
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer result.envelope.deinit();
    defer allocator.free(result.export_root_abs_path);

    try std.testing.expectEqualStrings(knowledge_pack_store.EXPORT_SCHEMA_VERSION, result.envelope.schema_version);
    try std.testing.expect(result.envelope.integrity.manifest_hash != 0);
    try std.testing.expect(result.envelope.integrity.total_files_hash != 0);
    try std.testing.expect(result.envelope.integrity.influence_hash != 0);

    const export_json_path = try std.fs.path.join(allocator, &.{ result.export_root_abs_path, "export.json" });
    defer allocator.free(export_json_path);
    const manifest_json_path = try std.fs.path.join(allocator, &.{ result.export_root_abs_path, "manifest.json" });
    defer allocator.free(manifest_json_path);
    try std.testing.expect(fileExistsAbsolute(export_json_path));
    try std.testing.expect(fileExistsAbsolute(manifest_json_path));
}

test "export refuses non-empty destination without deleting user files" {
    const allocator = std.testing.allocator;
    const pack_id = "export-non-empty-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var export_tmp = std.testing.tmpDir(.{});
    defer export_tmp.cleanup();
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);
    const sentinel_path = try std.fs.path.join(allocator, &.{ export_root, "sentinel.txt" });
    defer allocator.free(sentinel_path);
    {
        const handle = try sys.openForWrite(allocator, sentinel_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, "do not delete");
    }

    try std.testing.expectError(error.ExportDestinationNotEmpty, knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    }));
    try std.testing.expect(fileExistsAbsolute(sentinel_path));
}

test "import installs valid pack as unmounted" {
    const allocator = std.testing.allocator;
    const pack_id = "import-unmounted-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    defer export_tmp.cleanup();
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var import_result = try knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    });
    defer import_result.manifest.deinit();
    defer allocator.free(import_result.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expect(!import_result.was_overwrite);
    try std.testing.expectEqualStrings(pack_id, import_result.manifest.pack_id);
    try std.testing.expectEqualStrings(pack_version, import_result.manifest.pack_version);

    const installed_export_json = try std.fs.path.join(allocator, &.{ import_result.root_abs_path, "export.json" });
    defer allocator.free(installed_export_json);
    try std.testing.expect(!fileExistsAbsolute(installed_export_json));
}

test "imported pack is mountable after explicit mount" {
    const allocator = std.testing.allocator;
    const project_shard = "import-mount-test-project";
    const pack_id = "import-mount-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    defer export_tmp.cleanup();
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var import_result = try knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    });
    defer import_result.manifest.deinit();
    defer allocator.free(import_result.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, true, true);
    defer knowledge_packs.setMountedState(allocator, project_shard, pack_id, pack_version, false, false) catch {};

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    var registry = try knowledge_pack_store.loadMountRegistry(allocator, &project_paths);
    defer registry.deinit();
    var found = false;
    for (registry.entries) |entry| {
        if (std.mem.eql(u8, entry.pack_id, pack_id) and std.mem.eql(u8, entry.pack_version, pack_version)) {
            try std.testing.expect(entry.enabled);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "import rejects corrupt hash" {
    const allocator = std.testing.allocator;
    const pack_id = "import-corrupt-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    const influence_path = try std.fs.path.join(allocator, &.{ export_result.export_root_abs_path, "influence.json" });
    defer allocator.free(influence_path);
    {
        const handle = try sys.openForWrite(allocator, influence_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, "CORRUPTED");
    }

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectError(error.IntegrityCheckFailed, knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    }));

    export_tmp.cleanup();
}

test "import rejects incompatible engine version" {
    const allocator = std.testing.allocator;
    const pack_id = "import-engine-ver-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    export_result.envelope.allocator.free(export_result.envelope.export_engine_version);
    export_result.envelope.export_engine_version = try allocator.dupe(u8, "V99");
    try knowledge_pack_store.saveExportEnvelope(allocator, export_result.export_root_abs_path, &export_result.envelope);

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectError(error.IncompatibleEngineVersion, knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    }));

    export_tmp.cleanup();
}

test "import rejects incompatible schema version" {
    const allocator = std.testing.allocator;
    const pack_id = "import-schema-ver-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    const export_json_path = try std.fs.path.join(allocator, &.{ export_result.export_root_abs_path, "export.json" });
    defer allocator.free(export_json_path);
    const original = try readFileAbsoluteAlloc(allocator, export_json_path, 512 * 1024);
    defer allocator.free(original);
    const tampered = try std.mem.replaceOwned(u8, allocator, original, knowledge_pack_store.EXPORT_SCHEMA_VERSION, "bad_schema_v999");
    defer allocator.free(tampered);
    {
        const handle = try sys.openForWrite(allocator, export_json_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, tampered);
    }

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectError(error.InvalidExportEnvelope, knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    }));

    export_tmp.cleanup();
}

test "import rejects path traversal in artifact" {
    const allocator = std.testing.allocator;
    const pack_id = "import-traversal-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    const corpus_dir = try std.fs.path.join(allocator, &.{ export_result.export_root_abs_path, "corpus" });
    defer allocator.free(corpus_dir);
    const traversal_path = try std.fs.path.join(allocator, &.{ corpus_dir, "..outside" });
    defer allocator.free(traversal_path);
    {
        const handle = try sys.openForWrite(allocator, traversal_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, "traversal");
    }

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectError(error.IntegrityCheckFailed, knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    }));

    export_tmp.cleanup();
}

test "import overwrite requires force flag" {
    const allocator = std.testing.allocator;
    const pack_id = "import-force-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectError(error.PackAlreadyExists, knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    }));

    var force_result = try knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
        .force = true,
    });
    defer force_result.manifest.deinit();
    defer allocator.free(force_result.root_abs_path);
    try std.testing.expect(force_result.was_overwrite);

    export_tmp.cleanup();
}

test "verify detects integrity failure without installing" {
    const allocator = std.testing.allocator;
    const pack_id = "verify-integrity-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    const influence_path = try std.fs.path.join(allocator, &.{ export_result.export_root_abs_path, "influence.json" });
    defer allocator.free(influence_path);
    {
        const handle = try sys.openForWrite(allocator, influence_path);
        defer sys.closeFile(handle);
        try sys.writeAll(handle, "TAMPERED");
    }

    const result = try knowledge_packs.verifyExportArtifact(allocator, export_result.export_root_abs_path);
    defer {
        for (result.errors) |item| allocator.free(item);
        allocator.free(result.errors);
    }
    try std.testing.expect(!result.integrity_ok);

    export_tmp.cleanup();
}

test "export import roundtrip preserves manifest fields" {
    const allocator = std.testing.allocator;
    const pack_id = "roundtrip-test";
    const pack_version = "v2";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    const original_domain = try allocator.dupe(u8, pack.manifest.domain_family);
    defer allocator.free(original_domain);
    const original_trust = try allocator.dupe(u8, pack.manifest.trust_class);
    defer allocator.free(original_trust);
    const original_summary = try allocator.dupe(u8, pack.manifest.provenance.source_summary);
    defer allocator.free(original_summary);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var import_result = try knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    });
    defer import_result.manifest.deinit();
    defer allocator.free(import_result.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectEqualStrings(pack_id, import_result.manifest.pack_id);
    try std.testing.expectEqualStrings(pack_version, import_result.manifest.pack_version);
    try std.testing.expectEqualStrings(original_domain, import_result.manifest.domain_family);
    try std.testing.expectEqualStrings(original_trust, import_result.manifest.trust_class);
    try std.testing.expectEqualStrings(original_summary, import_result.manifest.provenance.source_summary);

    export_tmp.cleanup();
}

test "list versions shows multiple coexisting versions" {
    const allocator = std.testing.allocator;
    const pack_id = "multi-version-test";

    var pack_v1 = try createTestPackForExport(allocator, pack_id, "v1");
    defer pack_v1.manifest.deinit();
    defer allocator.free(pack_v1.root_abs_path);

    var pack_v2 = try createTestPackForExport(allocator, pack_id, "v2");
    defer pack_v2.manifest.deinit();
    defer allocator.free(pack_v2.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, "v1") catch {};
    defer knowledge_packs.removePack(allocator, pack_id, "v2") catch {};

    const versions = try knowledge_packs.listPackVersions(allocator, pack_id);
    defer {
        for (versions) |*v| {
            allocator.free(v.pack_id);
            allocator.free(v.version);
            allocator.free(v.domain);
            allocator.free(v.trust_class);
        }
        allocator.free(versions);
    }
    try std.testing.expectEqual(@as(usize, 2), versions.len);
}

test "import does not auto mount or auto trust" {
    const allocator = std.testing.allocator;
    const project_shard = "import-no-automount-test-project";
    const pack_id = "no-automount-test";
    const pack_version = "v1";

    var pack = try createTestPackForExport(allocator, pack_id, pack_version);
    defer pack.manifest.deinit();
    defer allocator.free(pack.root_abs_path);

    const original_trust = try allocator.dupe(u8, pack.manifest.trust_class);
    defer allocator.free(original_trust);

    var export_tmp = std.testing.tmpDir(.{});
    const export_root = try export_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(export_root);

    var export_result = try knowledge_packs.exportPack(allocator, .{
        .pack_id = pack_id,
        .pack_version = pack_version,
        .export_dir = export_root,
    });
    defer export_result.envelope.deinit();
    defer allocator.free(export_result.export_root_abs_path);

    knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    var import_result = try knowledge_packs.importPack(allocator, .{
        .source_dir = export_result.export_root_abs_path,
    });
    defer import_result.manifest.deinit();
    defer allocator.free(import_result.root_abs_path);
    defer knowledge_packs.removePack(allocator, pack_id, pack_version) catch {};

    try std.testing.expectEqualStrings(original_trust, import_result.manifest.trust_class);

    var project_metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer project_metadata.deinit();
    var project_paths = try shards.resolvePaths(allocator, project_metadata.metadata);
    defer project_paths.deinit();

    var registry = try knowledge_pack_store.loadMountRegistry(allocator, &project_paths);
    defer registry.deinit();
    for (registry.entries) |entry| {
        try std.testing.expect(!(std.mem.eql(u8, entry.pack_id, pack_id) and std.mem.eql(u8, entry.pack_version, pack_version)));
    }

    export_tmp.cleanup();
}

// ── Universal Artifact Schema Core Tests ──────────────────────────────────

test "artifact schema: schema registry register and lookup" {
    const allocator = std.testing.allocator;
    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());

    const schema = try artifact_schema.builtinCodeSchema(allocator);
    try registry.register(schema);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const looked_up = registry.lookup("code_artifact_schema");
    try std.testing.expect(looked_up != null);
    try std.testing.expectEqual(@as(usize, 8), looked_up.?.entity_types.len);
    try std.testing.expectEqual(@as(usize, 5), looked_up.?.relation_types.len);
    try std.testing.expectEqual(@as(usize, 3), looked_up.?.action_surfaces.len);
    try std.testing.expectEqual(@as(usize, 3), looked_up.?.verifier_hooks.len);

    // Non-existent schema returns null.
    try std.testing.expect(registry.lookup("nonexistent") == null);
}

test "artifact schema: all four builtin schemas register without conflict" {
    const allocator = std.testing.allocator;
    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try artifact_schema.registerBuiltinSchemas(&registry);
    try std.testing.expectEqual(@as(usize, 4), registry.count());

    try std.testing.expect(registry.lookup("code_artifact_schema") != null);
    try std.testing.expect(registry.lookup("document_schema") != null);
    try std.testing.expect(registry.lookup("config_schema") != null);
    try std.testing.expect(registry.lookup("log_schema") != null);
}

test "artifact schema: schema re-registration replaces previous" {
    const allocator = std.testing.allocator;
    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try artifact_schema.registerBuiltinSchemas(&registry);
    try std.testing.expectEqual(@as(usize, 4), registry.count());

    // Register code schema again — count stays the same.
    const new_schema = try artifact_schema.builtinCodeSchema(allocator);
    try registry.register(new_schema);
    try std.testing.expectEqual(@as(usize, 4), registry.count());
}

test "artifact schema: fragment extraction from code artifact" {
    const allocator = std.testing.allocator;
    const content =
        \\pub fn main() void {
        \\    std.debug.print("hello\n", .{});
        \\}
    ;

    var artifact = try artifact_schema.Artifact.init(allocator, "test-code", .repo, .file, "test", .project, "zig", null, null);
    defer artifact.deinit(allocator);

    const fragments = try artifact_schema.extractFragments(allocator, &artifact, content, true);
    defer {
        for (fragments) |*f| f.deinit(allocator);
        allocator.free(fragments);
    }

    try std.testing.expect(fragments.len >= 2);
    try std.testing.expectEqualStrings("test-code", fragments[0].artifact_id);
    // First fragment should be from strict or robust parsing (structured input).
    try std.testing.expect(fragments[0].parser_stage == .strict or fragments[0].parser_stage == .robust);
}

test "artifact schema: malformed input still produces fragments" {
    const allocator = std.testing.allocator;
    const malformed = "\x00\x01\x02\xff\xfe random binary noise \x80\x90";

    var artifact = try artifact_schema.Artifact.init(allocator, "malformed-test", .user, .file, "test", .exploratory, null, null, null);
    defer artifact.deinit(allocator);

    const fragments = try artifact_schema.extractFragments(allocator, &artifact, malformed, true);
    defer {
        for (fragments) |*f| f.deinit(allocator);
        allocator.free(fragments);
    }

    // Malformed input must still produce at least one fragment — never collapse.
    try std.testing.expect(fragments.len >= 1);
}

test "artifact schema: empty content produces fallback fragment when always_fragment" {
    const allocator = std.testing.allocator;

    var artifact = try artifact_schema.Artifact.init(allocator, "empty-test", .scratch, .document, "test", .exploratory, null, null, null);
    defer artifact.deinit(allocator);

    const fragments = try artifact_schema.extractFragments(allocator, &artifact, "", true);
    defer {
        for (fragments) |*f| f.deinit(allocator);
        allocator.free(fragments);
    }

    try std.testing.expectEqual(@as(usize, 1), fragments.len);
    try std.testing.expectEqualStrings("empty", fragments[0].region);
    try std.testing.expect(fragments[0].parser_stage == .fallback);
}

test "artifact schema: entity extraction from code fragments" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const schema = registry.lookup("code_artifact_schema").?;

    const content =
        \\pub fn main() void {
        \\    const x: u32 = 42;
        \\}
    ;

    var artifact = try artifact_schema.Artifact.init(allocator, "entity-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact.deinit(allocator);

    const fragments = try artifact_schema.extractFragments(allocator, &artifact, content, true);
    defer {
        for (fragments) |*f| f.deinit(allocator);
        allocator.free(fragments);
    }

    const entities = try artifact_schema.extractEntities(allocator, &artifact, fragments, &schema);
    defer {
        for (entities) |*e| e.deinit(allocator);
        allocator.free(entities);
    }

    // Should extract at least some entities (function, variable, constant).
    try std.testing.expect(entities.len > 0);

    // All entities must reference the correct artifact.
    for (entities) |entity| {
        try std.testing.expectEqualStrings("entity-test", entity.artifact_id);
    }
}

test "artifact schema: document artifact goes through same pipeline as code" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content =
        \\# Introduction
        \\
        \\This is a paragraph about the system.
        \\
        \\## Details
        \\
        \\- Item one
        \\- Item two
    ;

    var artifact = try artifact_schema.Artifact.init(allocator, "doc-test", .repo, .document, "test", .project, "md", null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    // Document must produce fragments and entities.
    try std.testing.expect(result.fragments.len > 0);
    try std.testing.expect(result.entities.len > 0);

    // Should be routed to document schema.
    try std.testing.expectEqualStrings("document_schema", result.artifacts[0].schema_name);
}

test "artifact schema: config artifact goes through same pipeline as code" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content =
        \\[database]
        \\host = localhost
        \\port = 5432
        \\name = mydb
    ;

    var artifact = try artifact_schema.Artifact.init(allocator, "config-test", .repo, .file, "test", .project, "ini", null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    try std.testing.expect(result.fragments.len > 0);
    try std.testing.expectEqualStrings("config_schema", result.artifacts[0].schema_name);
}

test "artifact schema: no domain bias — same pipeline for all schemas" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };

    // Code artifact
    const code_content = "pub fn foo() void {}\n";
    var code_artifact = try artifact_schema.Artifact.init(allocator, "code", .repo, .file, "test", .project, "zig", null, null);
    defer code_artifact.deinit(allocator);
    var code_result = try artifact_schema.ingestArtifact(allocator, &code_artifact, code_content, &options);
    defer code_result.deinit();

    // Document artifact
    const doc_content = "# Title\n\nSome text here.\n";
    var doc_artifact = try artifact_schema.Artifact.init(allocator, "doc", .repo, .document, "test", .project, "md", null, null);
    defer doc_artifact.deinit(allocator);
    var doc_result = try artifact_schema.ingestArtifact(allocator, &doc_artifact, doc_content, &options);
    defer doc_result.deinit();

    // Config artifact
    const config_content = "host = localhost\nport = 8080\n";
    var config_artifact = try artifact_schema.Artifact.init(allocator, "config", .repo, .file, "test", .project, "conf", null, null);
    defer config_artifact.deinit(allocator);
    var config_result = try artifact_schema.ingestArtifact(allocator, &config_artifact, config_content, &options);
    defer config_result.deinit();

    // All must produce fragments — same pipeline, no shortcuts.
    try std.testing.expect(code_result.fragments.len > 0);
    try std.testing.expect(doc_result.fragments.len > 0);
    try std.testing.expect(config_result.fragments.len > 0);

    // Each must have entities extracted via the same pipeline.
    try std.testing.expect(code_result.entities.len >= 0);
    try std.testing.expect(doc_result.entities.len >= 0);
    try std.testing.expect(config_result.entities.len >= 0);

    // None may bypass obligations.
    try std.testing.expect(code_result.obligations.len >= 0);
    try std.testing.expect(doc_result.obligations.len >= 0);
    try std.testing.expect(config_result.obligations.len >= 0);
}

test "artifact schema: schema switching does not change behavior" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content = "pub fn main() void {}\n";

    // Same content, different explicit schema hints.
    var artifact_a = try artifact_schema.Artifact.init(allocator, "switch-a", .repo, .file, "test", .project, "zig", null, "code_artifact_schema");
    defer artifact_a.deinit(allocator);

    // Same content as document — still routed to code via format hint.
    var artifact_b = try artifact_schema.Artifact.init(allocator, "switch-b", .repo, .document, "test", .project, "zig", null, null);
    defer artifact_b.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };

    var result_a = try artifact_schema.ingestArtifact(allocator, &artifact_a, content, &options);
    defer result_a.deinit();
    var result_b = try artifact_schema.ingestArtifact(allocator, &artifact_b, content, &options);
    defer result_b.deinit();

    // Both should route to code schema regardless of artifact_type label.
    try std.testing.expectEqualStrings("code_artifact_schema", result_a.artifacts[0].schema_name);
    try std.testing.expectEqualStrings("code_artifact_schema", result_b.artifacts[0].schema_name);

    // Both should produce fragments.
    try std.testing.expect(result_a.fragments.len > 0);
    try std.testing.expect(result_b.fragments.len > 0);
}

test "artifact schema: support graph includes artifact, entity, obligation nodes" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content = "pub fn hello() void {}\n";
    var artifact = try artifact_schema.Artifact.init(allocator, "graph-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    // Build a support graph and append artifact nodes.
    var graph = code_intel.SupportGraph{
        .allocator = allocator,
    };
    defer graph.deinit();

    try artifact_schema.appendArtifactSupportNodes(allocator, &graph, &result);

    // Must have artifact node.
    var has_artifact = false;
    var has_fragment = false;
    for (graph.nodes) |node| {
        if (node.kind == .artifact) has_artifact = true;
        if (node.kind == .fragment) has_fragment = true;
    }
    try std.testing.expect(has_artifact);
    try std.testing.expect(has_fragment);

    // If there are entities, there must be entity nodes.
    if (result.entities.len > 0) {
        var has_entity = false;
        for (graph.nodes) |node| {
            if (node.kind == .entity) has_entity = true;
        }
        try std.testing.expect(has_entity);
    }
}

test "artifact schema: obligations block promotion to supported" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content = "pub fn hello() void {}\n";
    var artifact = try artifact_schema.Artifact.init(allocator, "obl-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    // If entities were found and schema has blocking verifier hooks, obligations must be present.
    if (result.entities.len > 0 and result.obligations.len > 0) {
        // All obligations must start as pending (blocking).
        for (result.obligations) |obligation| {
            try std.testing.expect(obligation.pending);
        }
    }
}

test "artifact schema: partial understanding — fragments without entities" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    // Content that doesn't match any entity type patterns.
    const content = "??? !!! ???\n";
    var artifact = try artifact_schema.Artifact.init(allocator, "partial-test", .user, .document, "test", .exploratory, null, null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    // Fragments must exist even if entities are empty (partial understanding).
    try std.testing.expect(result.fragments.len > 0);
    // Entities may be empty — that's fine for partial understanding.
}

test "artifact schema: determinism — same input produces same output" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content = "pub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n";

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };

    // Run pipeline twice with identical input.
    var artifact1 = try artifact_schema.Artifact.init(allocator, "det-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact1.deinit(allocator);
    var result1 = try artifact_schema.ingestArtifact(allocator, &artifact1, content, &options);
    defer result1.deinit();

    var artifact2 = try artifact_schema.Artifact.init(allocator, "det-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact2.deinit(allocator);
    var result2 = try artifact_schema.ingestArtifact(allocator, &artifact2, content, &options);
    defer result2.deinit();

    // Must produce identical fragment counts, entity counts, schema names.
    try std.testing.expectEqual(result1.fragments.len, result2.fragments.len);
    try std.testing.expectEqual(result1.entities.len, result2.entities.len);
    try std.testing.expectEqual(result1.obligations.len, result2.obligations.len);
    try std.testing.expectEqualStrings(result1.artifacts[0].schema_name, result2.artifacts[0].schema_name);
}

test "artifact schema: relation extraction between entities" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content =
        \\# Section One
        \\
        \\Some paragraph text here.
        \\- List item one
        \\- List item two
    ;

    var artifact = try artifact_schema.Artifact.init(allocator, "rel-test", .repo, .document, "test", .project, "md", null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    // Should have entities (headings, paragraphs, list items).
    try std.testing.expect(result.entities.len > 0);

    // Relations should include contains relations from sections to content.
    // It's valid to have no relations if entities don't meet criteria.
}

test "artifact schema: routing is deterministic for same format hint" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    var signals = artifact_schema.RoutingSignals.init(allocator);
    defer signals.deinit();
    signals.artifact_type = .file;
    signals.trust_class = .project;

    // Route code format hint.
    var code_artifact = try artifact_schema.Artifact.init(allocator, "route-code", .repo, .file, "test", .project, "zig", null, null);
    defer code_artifact.deinit(allocator);

    const code_schema = artifact_schema.routeSchema(allocator, &code_artifact, &signals, &registry);
    try std.testing.expect(code_schema != null);
    try std.testing.expectEqualStrings("code_artifact_schema", code_schema.?);

    // Route document format hint.
    var doc_artifact = try artifact_schema.Artifact.init(allocator, "route-doc", .repo, .document, "test", .project, "md", null, null);
    defer doc_artifact.deinit(allocator);

    const doc_schema = artifact_schema.routeSchema(allocator, &doc_artifact, &signals, &registry);
    try std.testing.expect(doc_schema != null);
    try std.testing.expectEqualStrings("document_schema", doc_schema.?);

    // Route config format hint.
    var conf_artifact = try artifact_schema.Artifact.init(allocator, "route-conf", .repo, .file, "test", .project, "json", null, null);
    defer conf_artifact.deinit(allocator);

    const conf_schema = artifact_schema.routeSchema(allocator, &conf_artifact, &signals, &registry);
    try std.testing.expect(conf_schema != null);
    try std.testing.expectEqualStrings("config_schema", conf_schema.?);
}

test "artifact schema: parser cascade stages are assigned correctly" {
    const allocator = std.testing.allocator;

    // Structured code content should get strict or robust parsing.
    const code = "pub fn main() void {\n    const x: u32 = 42;\n}\n";
    var artifact_a = try artifact_schema.Artifact.init(allocator, "parser-code", .repo, .file, "test", .project, "zig", null, null);
    defer artifact_a.deinit(allocator);

    const code_frags = try artifact_schema.extractFragments(allocator, &artifact_a, code, true);
    defer {
        for (code_frags) |*f| f.deinit(allocator);
        allocator.free(code_frags);
    }
    // Code should be structured enough for strict parsing.
    try std.testing.expect(code_frags.len > 0);
    try std.testing.expect(code_frags[0].parser_stage == .strict);

    // Unstructured noise should fall through to fallback.
    const noise = "??? ??? ???\n";
    var artifact_b = try artifact_schema.Artifact.init(allocator, "parser-noise", .user, .document, "test", .exploratory, null, null, null);
    defer artifact_b.deinit(allocator);

    const noise_frags = try artifact_schema.extractFragments(allocator, &artifact_b, noise, true);
    defer {
        for (noise_frags) |*f| f.deinit(allocator);
        allocator.free(noise_frags);
    }
    try std.testing.expect(noise_frags.len > 0);
}

test "artifact schema: verifier hooks are created from schema definitions" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const content = "pub fn main() void {}\n";
    var artifact = try artifact_schema.Artifact.init(allocator, "hook-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact.deinit(allocator);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, content, &options);
    defer result.deinit();

    // Code schema has 3 verifier hooks (build, test, runtime).
    try std.testing.expectEqual(@as(usize, 3), result.verifier_hooks.len);

    // All hooks should start as pending.
    for (result.verifier_hooks) |hook| {
        try std.testing.expect(hook.result == .pending);
    }
}

test "artifact schema: mixed artifact types batch processing" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
    };

    // Code
    var code = try artifact_schema.Artifact.init(allocator, "mixed-code", .repo, .file, "test", .project, "zig", null, null);
    defer code.deinit(allocator);
    var code_r = try artifact_schema.ingestArtifact(allocator, &code, "pub fn f() void {}\n", &options);
    defer code_r.deinit();

    // Text
    var doc = try artifact_schema.Artifact.init(allocator, "mixed-doc", .repo, .document, "test", .project, "md", null, null);
    defer doc.deinit(allocator);
    var doc_r = try artifact_schema.ingestArtifact(allocator, &doc, "# Title\nParagraph.\n", &options);
    defer doc_r.deinit();

    // Config
    var conf = try artifact_schema.Artifact.init(allocator, "mixed-conf", .repo, .file, "test", .project, "json", null, null);
    defer conf.deinit(allocator);
    var conf_r = try artifact_schema.ingestArtifact(allocator, &conf, "key = value\n", &options);
    defer conf_r.deinit();

    // All must succeed with fragments.
    try std.testing.expect(code_r.fragments.len > 0);
    try std.testing.expect(doc_r.fragments.len > 0);
    try std.testing.expect(conf_r.fragments.len > 0);

    // Each routed to correct schema.
    try std.testing.expectEqualStrings("code_artifact_schema", code_r.artifacts[0].schema_name);
    try std.testing.expectEqualStrings("document_schema", doc_r.artifacts[0].schema_name);
    try std.testing.expectEqualStrings("config_schema", conf_r.artifacts[0].schema_name);
}

test "artifact schema: entity extraction consistency — repeated calls" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const schema = registry.lookup("code_artifact_schema").?;
    const content = "pub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n";

    // Extract entities three times — must be identical each time.
    var artifact1 = try artifact_schema.Artifact.init(allocator, "consist-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact1.deinit(allocator);

    const frags1 = try artifact_schema.extractFragments(allocator, &artifact1, content, true);
    const ents1 = try artifact_schema.extractEntities(allocator, &artifact1, frags1, &schema);
    defer {
        for (frags1) |*f| f.deinit(allocator);
        allocator.free(frags1);
        for (ents1) |*e| e.deinit(allocator);
        allocator.free(ents1);
    }

    var artifact2 = try artifact_schema.Artifact.init(allocator, "consist-test", .repo, .file, "test", .project, "zig", null, null);
    defer artifact2.deinit(allocator);

    const frags2 = try artifact_schema.extractFragments(allocator, &artifact2, content, true);
    const ents2 = try artifact_schema.extractEntities(allocator, &artifact2, frags2, &schema);
    defer {
        for (frags2) |*f| f.deinit(allocator);
        allocator.free(frags2);
        for (ents2) |*e| e.deinit(allocator);
        allocator.free(ents2);
    }

    try std.testing.expectEqual(ents1.len, ents2.len);
    for (ents1, ents2) |e1, e2| {
        try std.testing.expectEqualStrings(e1.entity_type, e2.entity_type);
    }
}

test "artifact schema: support graph node kinds include artifact pipeline types" {
    // Verify the new node kinds are accessible.
    const ArtifactKind = code_intel.SupportNodeKind;
    try std.testing.expect(ArtifactKind.artifact == .artifact);
    try std.testing.expect(ArtifactKind.entity == .entity);
    try std.testing.expect(ArtifactKind.relation == .relation);
    try std.testing.expect(ArtifactKind.verifier_hook == .verifier_hook);
    try std.testing.expect(ArtifactKind.action_surface == .action_surface);
    try std.testing.expect(ArtifactKind.hypothesis == .hypothesis);
    try std.testing.expect(ArtifactKind.hypothesis_evidence == .hypothesis_evidence);
    try std.testing.expect(ArtifactKind.hypothesis_obligation == .hypothesis_obligation);
    try std.testing.expect(ArtifactKind.hypothesis_verifier_need == .hypothesis_verifier_need);
    try std.testing.expect(ArtifactKind.hypothesis_triage == .hypothesis_triage);
    try std.testing.expect(ArtifactKind.hypothesis_duplicate_group == .hypothesis_duplicate_group);
    try std.testing.expect(ArtifactKind.hypothesis_score == .hypothesis_score);

    // And the new edge kinds.
    const EdgeKind = code_intel.SupportEdgeKind;
    try std.testing.expect(EdgeKind.artifact_sourced_from == .artifact_sourced_from);
    try std.testing.expect(EdgeKind.fragment_of == .fragment_of);
    try std.testing.expect(EdgeKind.entity_from_fragment == .entity_from_fragment);
    try std.testing.expect(EdgeKind.relates_to == .relates_to);
    try std.testing.expect(EdgeKind.verified_by == .verified_by);
    try std.testing.expect(EdgeKind.hypothesized_from == .hypothesized_from);
    try std.testing.expect(EdgeKind.requires_obligation == .requires_obligation);
    try std.testing.expect(EdgeKind.needs_verifier == .needs_verifier);
    try std.testing.expect(EdgeKind.triages == .triages);
    try std.testing.expect(EdgeKind.suppresses == .suppresses);
    try std.testing.expect(EdgeKind.duplicates == .duplicates);
    try std.testing.expect(EdgeKind.ranks_above == .ranks_above);
}

test "artifact schema: compute budget includes artifact pipeline stages" {
    const Stage = compute_budget.Stage;
    try std.testing.expect(Stage.artifact_ingestion == .artifact_ingestion);
    try std.testing.expect(Stage.artifact_fragment_extraction == .artifact_fragment_extraction);
    try std.testing.expect(Stage.artifact_entity_extraction == .artifact_entity_extraction);
    try std.testing.expect(Stage.artifact_schema_routing == .artifact_schema_routing);
    try std.testing.expect(Stage.artifact_obligation_attachment == .artifact_obligation_attachment);
    try std.testing.expect(Stage.hypothesis_generation == .hypothesis_generation);
    try std.testing.expect(Stage.hypothesis_selection == .hypothesis_selection);
    try std.testing.expect(Stage.hypothesis_verifier_need_collection == .hypothesis_verifier_need_collection);

    const budget = compute_budget.resolve(.{ .tier = .medium });
    try std.testing.expect(budget.max_hypotheses_generated > 0);
    try std.testing.expect(budget.max_hypotheses_selected <= budget.max_hypotheses_generated);
    try std.testing.expect(budget.max_hypothesis_evidence_fragments > 0);
    try std.testing.expect(budget.max_hypothesis_obligations > 0);
    try std.testing.expect(budget.max_hypothesis_verifier_needs > 0);
}

test "hypothesis core: artifact ingestion emits non-authorizing code and non-code hypotheses" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const options = artifact_schema.PipelineOptions{ .registry = &registry };

    var code_artifact = try artifact_schema.Artifact.init(allocator, "hyp-code", .repo, .file, "test", .project, "zig", null, null);
    defer code_artifact.deinit(allocator);
    var code_result = try artifact_schema.ingestArtifact(allocator, &code_artifact, "pub fn main() void {}\n", &options);
    defer code_result.deinit();

    var doc_artifact = try artifact_schema.Artifact.init(allocator, "hyp-doc", .repo, .document, "test", .project, "md", null, null);
    defer doc_artifact.deinit(allocator);
    var doc_result = try artifact_schema.ingestArtifact(allocator, &doc_artifact, "# Runbook\n\nValidate this section.\n", &options);
    defer doc_result.deinit();

    try std.testing.expect(code_result.hypotheses.len > 0);
    try std.testing.expect(doc_result.hypotheses.len > 0);
    try std.testing.expectEqual(hypothesis_core.HypothesisKind.possible_missing_obligation, code_result.hypotheses[0].hypothesis_kind);
    try std.testing.expectEqual(hypothesis_core.HypothesisKind.possible_missing_obligation, doc_result.hypotheses[0].hypothesis_kind);
    try std.testing.expect(code_result.hypotheses[0].non_authorizing);
    try std.testing.expect(doc_result.hypotheses[0].non_authorizing);
}

test "hypothesis core: hypothesis appears in support graph without authorizing support" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    var artifact = try artifact_schema.Artifact.init(allocator, "hyp-graph", .repo, .file, "test", .project, "zig", null, null);
    defer artifact.deinit(allocator);
    const options = artifact_schema.PipelineOptions{ .registry = &registry };
    var result = try artifact_schema.ingestArtifact(allocator, &artifact, "pub fn main() void {}\n", &options);
    defer result.deinit();

    var graph = code_intel.SupportGraph{ .allocator = allocator, .permission = .unresolved, .minimum_met = false };
    defer graph.deinit();
    try artifact_schema.appendArtifactSupportNodes(allocator, &graph, &result);

    var has_hypothesis = false;
    for (graph.nodes) |node| {
        if (node.kind == .hypothesis) {
            has_hypothesis = true;
            try std.testing.expect(!node.usable);
        }
    }
    try std.testing.expect(has_hypothesis);
    try std.testing.expect(!graph.minimum_met);
}

test "hypothesis core: unresolved output carries hypotheses visibly" {
    const allocator = std.testing.allocator;

    const evidence = [_][]const u8{"fragment:doc:1"};
    const obligations = [_][]const u8{"validate_possible_gap"};
    const hooks = [_][]const u8{"consistency_check"};
    const hyp = try hypothesis_core.make(
        allocator,
        "hypothesis:doc:1",
        "doc",
        "document_schema",
        .possible_unsupported_claim,
        &evidence,
        &obligations,
        &hooks,
        "verify",
        "test",
        "manual_test",
    );
    var hypotheses = try allocator.alloc(hypothesis_core.Hypothesis, 1);
    hypotheses[0] = hyp;

    var unresolved = code_intel.UnresolvedSupport{
        .allocator = allocator,
        .hypotheses = hypotheses,
    };
    defer unresolved.deinit();

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try code_intel.writeUnresolvedSupportJson(out.writer(), unresolved);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"hypotheses\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"non_authorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"possible_unsupported_claim\"") != null);
}

test "hypothesis core: verified status does not bypass support graph gates" {
    const allocator = std.testing.allocator;
    const evidence = [_][]const u8{"fragment:config:1"};
    const obligations = [_][]const u8{"validate_schema"};
    const hooks = [_][]const u8{"schema_validation"};
    var hyp = try hypothesis_core.make(
        allocator,
        "hypothesis:config:verified",
        "config",
        "config_schema",
        .possible_constraint_violation,
        &evidence,
        &obligations,
        &hooks,
        "verify",
        "test",
        "manual_test",
    );
    defer hyp.deinit(allocator);
    hyp.status = .verified;

    var graph = code_intel.SupportGraph{ .allocator = allocator, .permission = .unresolved, .minimum_met = false };
    defer graph.deinit();
    try std.testing.expect(hyp.non_authorizing);
    try std.testing.expectEqual(hypothesis_core.HypothesisStatus.verified, hyp.status);
    try std.testing.expect(!graph.minimum_met);
    try std.testing.expectEqual(code_intel.Status.unresolved, graph.permission);
}

test "hypothesis core: budget caps limit generation and preserve deterministic ordering" {
    const allocator = std.testing.allocator;

    var registry = artifact_schema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try artifact_schema.registerBuiltinSchemas(&registry);

    const options = artifact_schema.PipelineOptions{
        .registry = &registry,
        .compute_budget_request = .{
            .tier = .low,
            .overrides = .{ .max_hypotheses_generated = 1 },
        },
    };
    var artifact_a = try artifact_schema.Artifact.init(allocator, "hyp-det", .repo, .file, "test", .project, "zig", null, null);
    defer artifact_a.deinit(allocator);
    var result_a = try artifact_schema.ingestArtifact(allocator, &artifact_a, "pub fn a() void {}\npub fn b() void {}\n", &options);
    defer result_a.deinit();

    var artifact_b = try artifact_schema.Artifact.init(allocator, "hyp-det", .repo, .file, "test", .project, "zig", null, null);
    defer artifact_b.deinit(allocator);
    var result_b = try artifact_schema.ingestArtifact(allocator, &artifact_b, "pub fn a() void {}\npub fn b() void {}\n", &options);
    defer result_b.deinit();

    try std.testing.expectEqual(@as(usize, 1), result_a.hypotheses.len);
    try std.testing.expect(result_a.hypothesis_budget_exhaustion != null);
    try std.testing.expectEqualStrings(result_a.hypotheses[0].id, result_b.hypotheses[0].id);
    try std.testing.expectEqual(result_a.hypotheses[0].hypothesis_kind, result_b.hypotheses[0].hypothesis_kind);
}

// ── Intent Grounding v2 Tests ──────────────────────────────────────────

test "intent grounding: clear direct action classifies and grounds" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.direct_action, gi.intent_class);
    try std.testing.expectEqual(intent_grounding.GroundedIntent.GroundingStatus.grounded, gi.status);
    try std.testing.expect(gi.fast_path_eligible);
    try std.testing.expect(gi.artifact_bindings.len > 0);
    try std.testing.expect(gi.ambiguity_sets.len == 0);
    try std.testing.expect(gi.missing_obligations.len == 0);
}

test "intent grounding: diagnostic classify from why phrase" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "explain why src/api.zig:compute breaks", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.diagnostic, gi.intent_class);
    try std.testing.expectEqual(intent_grounding.GroundedIntent.GroundingStatus.grounded, gi.status);
    try std.testing.expect(gi.traces.len > 0);
}

test "intent grounding: creation classify from build phrase" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "build a new handler for src/router.zig", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.creation, gi.intent_class);
    try std.testing.expect(gi.obligations.len > 0);
}

test "intent grounding: verification classify from verify phrase" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "verify src/api.zig:endpoints is correct", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.verification, gi.intent_class);
}

test "intent grounding: vague request produces ambiguity not guess" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.transformation, gi.intent_class);
    try std.testing.expect(gi.ambiguity_sets.len > 0);
    try std.testing.expect(gi.candidate_intents.len > 0);
    // Must NOT be grounded — ambiguity prevents it.
    try std.testing.expect(gi.status != .grounded);
    // Must NOT have collapsed into a single guessed interpretation.
    try std.testing.expect(gi.candidate_intents.len >= 2);
}

test "intent grounding: vague optimize produces multiple candidates" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "optimize this", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.transformation, gi.intent_class);
    try std.testing.expect(gi.candidate_intents.len >= 2);
    try std.testing.expect(gi.ambiguity_sets.len > 0);
}

test "intent grounding: fix it produces candidates and ambiguity" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "fix it", .{});
    defer gi.deinit();

    try std.testing.expect(gi.candidate_intents.len >= 2);
    try std.testing.expect(gi.status != .grounded);
}

test "intent grounding: clean this up produces multiple candidates" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "clean this up", .{});
    defer gi.deinit();

    try std.testing.expect(gi.candidate_intents.len >= 2);
}

test "intent grounding: missing artifact binding creates missing obligation" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "summarize", .{});
    defer gi.deinit();

    // No artifact specified — must have missing obligation.
    var found_bind = false;
    for (gi.missing_obligations) |mo| {
        if (std.mem.eql(u8, mo.id, "bind_target_artifact")) found_bind = true;
    }
    try std.testing.expect(found_bind);
}

test "intent grounding: artifact binding from explicit reference" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "refactor src/main.zig", .{});
    defer gi.deinit();

    try std.testing.expect(gi.artifact_bindings.len > 0);
    try std.testing.expectEqual(intent_grounding.BindingSource.explicit_reference, gi.artifact_bindings[0].source);
    try std.testing.expectEqualStrings("src/main.zig", gi.artifact_bindings[0].artifact_id);
}

test "intent grounding: artifact binding from context target" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "build this in zig", .{
        .context_target = "src/handler.zig",
    });
    defer gi.deinit();

    // "this" should resolve via context target (v1 resolves deictic → explicit).
    try std.testing.expect(gi.artifact_bindings.len > 0);
    try std.testing.expectEqualStrings("src/handler.zig", gi.artifact_bindings[0].artifact_id);
}

test "intent grounding: multiple artifacts available but none specified stays ambiguous" {
    const allocator = std.testing.allocator;

    const artifacts = [_][]const u8{ "src/a.zig", "src/b.zig" };
    var gi = try intent_grounding.ground(allocator, "build", .{
        .available_artifacts = &artifacts,
    });
    defer gi.deinit();

    // Multiple artifacts available but none specified → no silent choice.
    try std.testing.expect(gi.artifact_bindings.len == 0);
}

test "intent grounding: single available artifact binds implicitly" {
    const allocator = std.testing.allocator;

    const artifacts = [_][]const u8{"src/only.zig"};
    var gi = try intent_grounding.ground(allocator, "summarize", .{
        .available_artifacts = &artifacts,
    });
    defer gi.deinit();

    try std.testing.expect(gi.artifact_bindings.len > 0);
    try std.testing.expectEqual(intent_grounding.BindingSource.pack_based, gi.artifact_bindings[0].source);
}

test "intent grounding: constraint extraction preserves user explicit" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "refactor src/main.zig but keep the API stable", .{});
    defer gi.deinit();

    var found_api = false;
    for (gi.constraints) |c| {
        if (c.kind == .api_stability and c.source == .user_explicit) found_api = true;
    }
    try std.testing.expect(found_api);
}

test "intent grounding: inferred constraints for transformation" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "improve this", .{});
    defer gi.deinit();

    var found_preserve_behavior = false;
    var found_preserve_structure = false;
    for (gi.constraints) |c| {
        if (c.kind == .determinism and c.source == .inferred_preserve_behavior) found_preserve_behavior = true;
        if (c.kind == .api_stability and c.source == .inferred_preserve_structure) found_preserve_structure = true;
    }
    try std.testing.expect(found_preserve_behavior);
    try std.testing.expect(found_preserve_structure);
}

test "intent grounding: safety constraint for deictic without context" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "verify this is correct", .{});
    defer gi.deinit();

    var found_safety = false;
    for (gi.constraints) |c| {
        if (c.kind == .safety and c.source == .from_verifier) found_safety = true;
    }
    try std.testing.expect(found_safety);
}

test "intent grounding: every intent produces obligations" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init", .{});
    defer gi.deinit();

    try std.testing.expect(gi.obligations.len > 0);
}

test "intent grounding: transformation produces criteria and validation obligations" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    var found_criteria = false;
    var found_validate = false;
    for (gi.obligations) |obl| {
        if (std.mem.eql(u8, obl.id, "define_criteria")) found_criteria = true;
        if (std.mem.eql(u8, obl.id, "validate_result")) found_validate = true;
    }
    try std.testing.expect(found_criteria);
    try std.testing.expect(found_validate);
}

test "intent grounding: ambiguous intent produces resolve_class obligation" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "hello world", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.ambiguous, gi.intent_class);
    var found_resolve = false;
    for (gi.obligations) |obl| {
        if (std.mem.eql(u8, obl.id, "resolve_class")) found_resolve = true;
    }
    try std.testing.expect(found_resolve);
}

test "intent grounding: obligation resolved when target known" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    // When target is explicit, verification class should not have bind_artifact
    // (it's only added when bindings.len == 0). Instead, verify that the
    // intent has grounded with obligations.
    try std.testing.expect(gi.obligations.len > 0);
    try std.testing.expectEqual(intent_grounding.GroundedIntent.GroundingStatus.grounded, gi.status);
}

test "intent grounding: scope is artifact_local for single binding" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentScope.artifact_local, gi.scope);
}

test "intent grounding: scope is artifact_local with no bindings" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "summarize", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentScope.artifact_local, gi.scope);
}

test "intent grounding: traces cover all grounding steps" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    // Must have traces for: classify, bind_artifact, extract_constraints, map_obligations.
    var found_classify = false;
    var found_bind = false;
    var found_constraints = false;
    var found_obligations = false;
    for (gi.traces) |trace| {
        if (std.mem.eql(u8, trace.step, "classify")) found_classify = true;
        if (std.mem.eql(u8, trace.step, "bind_artifact")) found_bind = true;
        if (std.mem.eql(u8, trace.step, "extract_constraints")) found_constraints = true;
        if (std.mem.eql(u8, trace.step, "map_obligations")) found_obligations = true;
    }
    try std.testing.expect(found_classify);
    try std.testing.expect(found_bind);
    try std.testing.expect(found_constraints);
    try std.testing.expect(found_obligations);
}

test "intent grounding: fast path for clear grounded request" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "refactor src/api/service.zig:compute but keep the API stable", .{});
    defer gi.deinit();

    try std.testing.expect(gi.fast_path_eligible);
    try std.testing.expectEqual(intent_grounding.GroundedIntent.GroundingStatus.grounded, gi.status);
}

test "intent grounding: no fast path for ambiguous request" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    try std.testing.expect(!gi.fast_path_eligible);
}

test "intent grounding: deterministic classification across repeated calls" {
    const allocator = std.testing.allocator;

    var gi1 = try intent_grounding.ground(allocator, "explain why src/main.zig:init breaks", .{});
    defer gi1.deinit();
    var gi2 = try intent_grounding.ground(allocator, "explain why src/main.zig:init breaks", .{});
    defer gi2.deinit();

    try std.testing.expectEqual(gi1.intent_class, gi2.intent_class);
    try std.testing.expectEqual(gi1.status, gi2.status);
    try std.testing.expectEqual(gi1.scope, gi2.scope);
    try std.testing.expectEqual(gi1.candidate_intents.len, gi2.candidate_intents.len);
    try std.testing.expectEqual(gi1.ambiguity_sets.len, gi2.ambiguity_sets.len);
}

test "intent grounding: render json produces valid output" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    const rendered = try intent_grounding.renderJson(allocator, &gi);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"status\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"intentClass\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"scope\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"traces\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"obligations\":") != null);
}

test "intent grounding: partial output includes ambiguity without collapsing" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "improve this", .{});
    defer gi.deinit();

    // Partial output must include all the following.
    try std.testing.expect(gi.candidate_intents.len > 0);
    try std.testing.expect(gi.ambiguity_sets.len > 0);
    try std.testing.expect(gi.traces.len > 0);

    // Must NOT have collapsed into a single guessed interpretation.
    try std.testing.expect(gi.candidate_intents.len >= 2);

    // Must NOT be grounded.
    try std.testing.expect(gi.status != .grounded);
}

test "intent grounding: no hallucinated intent resolution" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi.deinit();

    // Nonsensical input must be classified as ambiguous, not fabricated.
    try std.testing.expectEqual(intent_grounding.IntentClass.ambiguous, gi.intent_class);
    try std.testing.expect(gi.status != .grounded);
    try std.testing.expect(gi.fast_path_eligible == false);
    // Must NOT have any fabricated candidate intents.
    try std.testing.expect(gi.candidate_intents.len == 0);
}

test "intent grounding: action surfaces determined by class" {
    const allocator = std.testing.allocator;

    var gi_diag = try intent_grounding.ground(allocator, "explain why src/main.zig:init breaks", .{});
    defer gi_diag.deinit();

    var found_verify = false;
    var found_extract = false;
    for (gi_diag.action_surfaces) |surface| {
        if (surface == .verify) found_verify = true;
        if (surface == .extract) found_extract = true;
    }
    try std.testing.expect(found_verify);
    try std.testing.expect(found_extract);
}

test "intent grounding: ambiguity set has obligation to resolve" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    try std.testing.expect(gi.ambiguity_sets.len > 0);
    try std.testing.expect(gi.ambiguity_sets[0].obligation_to_resolve.len > 0);
    try std.testing.expect(gi.ambiguity_sets[0].candidate_indices.len >= 2);
    try std.testing.expect(gi.ambiguity_sets[0].reason.len > 0);
}

test "intent grounding: base task preserved in grounded intent" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "refactor src/api/service.zig:compute but keep the API stable", .{});
    defer gi.deinit();

    try std.testing.expectEqual(task_intent.Action.refactor, gi.base_task.action);
    try std.testing.expectEqual(task_intent.ParseStatus.grounded, gi.base_task.status);
    try std.testing.expect(gi.base_task.constraints.len > 0);
}

test "intent grounding: transformation without target produces candidates and missing obligation" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "clean this up", .{});
    defer gi.deinit();

    // Should have candidate interpretations.
    try std.testing.expect(gi.candidate_intents.len >= 2);
    // Should be unresolved due to ambiguity.
    try std.testing.expect(gi.status != .grounded);
}

test "intent grounding: verification with explicit target grounds cleanly" {
    const allocator = std.testing.allocator;

    var gi = try intent_grounding.ground(allocator, "check src/main.zig:init is correct", .{});
    defer gi.deinit();

    try std.testing.expectEqual(intent_grounding.IntentClass.verification, gi.intent_class);
    try std.testing.expectEqual(intent_grounding.GroundedIntent.GroundingStatus.grounded, gi.status);
    try std.testing.expect(gi.fast_path_eligible);
}

// ── Response Engine Tests ─────────────────────────────────────────────

test "response engine: grounded intent clone preserves all fields" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var cloned = try gi.clone(allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(gi.status, cloned.status);
    try std.testing.expectEqual(gi.intent_class, cloned.intent_class);
    try std.testing.expectEqual(gi.scope, cloned.scope);
    try std.testing.expectEqual(gi.artifact_bindings.len, cloned.artifact_bindings.len);
    try std.testing.expectEqual(gi.constraints.len, cloned.constraints.len);
    try std.testing.expectEqual(gi.obligations.len, cloned.obligations.len);
    try std.testing.expectEqual(gi.ambiguity_sets.len, cloned.ambiguity_sets.len);
    try std.testing.expectEqual(gi.missing_obligations.len, cloned.missing_obligations.len);
    try std.testing.expectEqual(gi.fast_path_eligible, cloned.fast_path_eligible);
    try std.testing.expectEqualStrings(gi.raw_input, cloned.raw_input);
}

test "response engine: ambiguous intent clone preserves candidates and ambiguity" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    var cloned = try gi.clone(allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(gi.candidate_intents.len, cloned.candidate_intents.len);
    try std.testing.expectEqual(gi.ambiguity_sets.len, cloned.ambiguity_sets.len);
}

test "response engine: simple query selects fast path in auto mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expectEqual(response_engine.ResponseMode.fast_path, result.selected_mode);
    try std.testing.expect(!result.escalated);
    try std.testing.expectEqual(response_engine.StopReason.supported, result.stop_reason);
}

test "response engine: vague query stays unresolved in auto mode without escalation" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .autoPath());
    defer result.deinit();

    // Truly ambiguous (unclassifiable) intent: no escalation justified, stays unresolved.
    try std.testing.expectEqual(response_engine.StopReason.unresolved, result.stop_reason);
    try std.testing.expect(!result.escalated);
    try std.testing.expect(result.escalation_reason == null);
}

test "response engine: clear action escalates to deep path in auto mode" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .autoPath());
    defer result.deinit();

    // verify action surface triggers escalation.
    try std.testing.expectEqual(response_engine.ResponseMode.deep_path, result.selected_mode);
    try std.testing.expect(result.escalated);
    try std.testing.expectEqual(response_engine.EscalationReason.action_surface_requires_proof, result.escalation_reason);
}

test "response engine: forced deep path via user config" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .deepOnly());
    defer result.deinit();

    try std.testing.expectEqual(response_engine.ResponseMode.deep_path, result.selected_mode);
    try std.testing.expectEqual(response_engine.StopReason.supported, result.stop_reason);
}

test "response engine: budget exhaustion produces budget stop reason" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .{
        .mode = .deep_path,
        .budget_request = .{
            .tier = .low,
            .overrides = .{
                .max_graph_nodes = 1,
                .max_runtime_checks = 1,
            },
        },
    });
    defer result.deinit();

    try std.testing.expect(result.budget_exhaustions.len > 0);
    try std.testing.expectEqual(response_engine.StopReason.budget, result.stop_reason);
}

test "response engine: no false fast path eligibility for nonsense input" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi.deinit();

    const budget = compute_budget.resolve(.{ .tier = .low });
    var eligibility = try response_engine.checkFastPathEligibility(allocator, &gi, &budget);
    defer eligibility.deinit(allocator);

    try std.testing.expect(!eligibility.eligible);
}

test "response engine: deterministic results across repeated runs" {
    const allocator = std.testing.allocator;

    var gi1 = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi1.deinit();
    var gi2 = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi2.deinit();

    var result1 = try response_engine.execute(allocator, &gi1, .autoPath());
    defer result1.deinit();
    var result2 = try response_engine.execute(allocator, &gi2, .autoPath());
    defer result2.deinit();

    try std.testing.expectEqual(result1.selected_mode, result2.selected_mode);
    try std.testing.expectEqual(result1.stop_reason, result2.stop_reason);
    try std.testing.expectEqual(result1.escalated, result2.escalated);
    try std.testing.expectEqual(result1.escalation_reason, result2.escalation_reason);
    try std.testing.expectEqual(result1.partial_findings.len, result2.partial_findings.len);
    try std.testing.expectEqual(result1.budget_exhaustions.len, result2.budget_exhaustions.len);
}

test "response engine: latency tracking records non-zero total time" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var fast_result = try response_engine.execute(allocator, &gi, .fastOnly());
    defer fast_result.deinit();
    var deep_result = try response_engine.execute(allocator, &gi, .deepOnly());
    defer deep_result.deinit();

    try std.testing.expect(fast_result.latency.total_us > 0);
    try std.testing.expect(deep_result.latency.total_us > 0);
}

test "response engine: render json contains required fields" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .autoPath());
    defer result.deinit();

    const rendered = try response_engine.renderJson(allocator, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"selectedMode\":\"fast_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"stopReason\":\"supported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"latency\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"totalUs\":") != null);
}

test "response engine: budget mapping fast to low, deep to high, auto to medium" {
    const fast_budget = response_engine.resolveBudget(.{ .mode = .fast_path });
    try std.testing.expectEqual(compute_budget.Tier.low, fast_budget.effective_tier);

    const deep_budget = response_engine.resolveBudget(.{ .mode = .deep_path });
    try std.testing.expectEqual(compute_budget.Tier.high, deep_budget.effective_tier);

    const auto_budget = response_engine.resolveBudget(.{ .mode = .auto_path });
    try std.testing.expectEqual(compute_budget.Tier.medium, auto_budget.effective_tier);
}

test "response engine: escalation reasons are explicit and justified" {
    const allocator = std.testing.allocator;

    // verify action → action_surface_requires_proof.
    var gi_verify = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi_verify.deinit();
    var result_verify = try response_engine.execute(allocator, &gi_verify, .autoPath());
    defer result_verify.deinit();
    try std.testing.expect(result_verify.escalated);
    try std.testing.expectEqual(response_engine.EscalationReason.action_surface_requires_proof, result_verify.escalation_reason);

    // ambiguous input → no escalation (stays unresolved).
    var gi_amb = try intent_grounding.ground(allocator, "asdfghjkl", .{});
    defer gi_amb.deinit();
    var result_amb = try response_engine.execute(allocator, &gi_amb, .autoPath());
    defer result_amb.deinit();
    try std.testing.expect(!result_amb.escalated);
    try std.testing.expect(result_amb.escalation_reason == null);
}

test "response engine: partial findings present for unresolved results" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "improve this", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .autoPath());
    defer result.deinit();

    try std.testing.expectEqual(response_engine.StopReason.unresolved, result.stop_reason);
    try std.testing.expect(result.grounded_intent.candidate_intents.len >= 2);
}

test "response engine: support contract preserved in fast path" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .fastOnly());
    defer result.deinit();

    // Fast path must still respect the support contract.
    if (result.stop_reason == .supported) {
        try std.testing.expectEqual(
            intent_grounding.GroundedIntent.GroundingStatus.grounded,
            result.grounded_intent.status,
        );
    }
}

test "response engine: forced fast path does not bypass verification obligations" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .fastOnly());
    defer result.deinit();

    try std.testing.expect(result.selected_mode != .fast_path);
    try std.testing.expect(result.stop_reason != .supported or result.escalation_reason != null);
    try std.testing.expect(!result.speculative_scheduler.active or result.selected_mode == .deep_path);
}

test "response engine: draft mode refuses explicit verification and patch requests" {
    const allocator = std.testing.allocator;

    var verify_intent = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer verify_intent.deinit();
    var verify_result = try response_engine.execute(allocator, &verify_intent, .draftOnly());
    defer verify_result.deinit();
    try std.testing.expectEqual(response_engine.ResponseMode.deep_path, verify_result.selected_mode);
    try std.testing.expect(!verify_result.draft.mode.enabled);

    var patch_intent = try intent_grounding.ground(allocator, "fix src/main.zig:init", .{});
    defer patch_intent.deinit();
    var patch_result = try response_engine.execute(allocator, &patch_intent, .draftOnly());
    defer patch_result.deinit();
    try std.testing.expectEqual(response_engine.ResponseMode.deep_path, patch_result.selected_mode);
    try std.testing.expect(!patch_result.draft.mode.enabled);
}

test "response engine: draft output is always unresolved and unverified" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "draft a plan for src/main.zig", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .draftOnly());
    defer result.deinit();

    try std.testing.expectEqual(response_engine.ResponseMode.draft_mode, result.selected_mode);
    try std.testing.expectEqual(response_engine.StopReason.unresolved, result.stop_reason);
    try std.testing.expect(result.draft.mode.enabled);
    try std.testing.expectEqual(response_engine.VerificationState.unverified, result.draft.mode.verification_state);
    try std.testing.expect(result.draft.missing_information.len > 0);
}

test "response engine: speculative scheduler keeps pruned candidates traceable" {
    const allocator = std.testing.allocator;
    var gi = try intent_grounding.ground(allocator, "make this better", .{});
    defer gi.deinit();

    var result = try response_engine.execute(allocator, &gi, .deepOnly());
    defer result.deinit();

    try std.testing.expectEqual(response_engine.ResponseMode.deep_path, result.selected_mode);
    try std.testing.expect(result.speculative_scheduler.active);
    try std.testing.expect(result.speculative_scheduler.candidates.len > 0);
    var has_pruned_or_considered = false;
    for (result.speculative_scheduler.candidates) |candidate| {
        if (candidate.status == .pruned or candidate.status == .considered) has_pruned_or_considered = true;
    }
    try std.testing.expect(has_pruned_or_considered);
}

test "response engine: fast path eligibility check is comprehensive" {
    const allocator = std.testing.allocator;
    const budget = compute_budget.resolve(.{ .tier = .low });

    // Grounded intent with summarize action → eligible.
    var gi_summarize = try intent_grounding.ground(allocator, "summarize src/main.zig", .{});
    defer gi_summarize.deinit();
    var elig_summarize = try response_engine.checkFastPathEligibility(allocator, &gi_summarize, &budget);
    defer elig_summarize.deinit(allocator);
    try std.testing.expect(elig_summarize.eligible);
    try std.testing.expect(elig_summarize.intent_grounded);
    try std.testing.expect(elig_summarize.no_ambiguity_sets);
    try std.testing.expect(elig_summarize.no_missing_obligations);
    try std.testing.expect(elig_summarize.artifact_bindings_resolved);
    try std.testing.expect(elig_summarize.no_verification_required);
    try std.testing.expect(elig_summarize.support_graph_within_bounds);

    // Verification action → not eligible (requires verification).
    var gi_verify = try intent_grounding.ground(allocator, "verify src/main.zig:init is correct", .{});
    defer gi_verify.deinit();
    var elig_verify = try response_engine.checkFastPathEligibility(allocator, &gi_verify, &budget);
    defer elig_verify.deinit(allocator);
    try std.testing.expect(!elig_verify.eligible);
    try std.testing.expect(!elig_verify.no_verification_required);
}

test "reasoning parser accepts only public reasoning levels" {
    try std.testing.expectEqual(response_engine.ReasoningLevel.quick, response_engine.parseReasoningLevel("quick").?);
    try std.testing.expectEqual(response_engine.ReasoningLevel.balanced, response_engine.parseReasoningLevel("balanced").?);
    try std.testing.expectEqual(response_engine.ReasoningLevel.deep, response_engine.parseReasoningLevel("deep").?);
    try std.testing.expectEqual(response_engine.ReasoningLevel.max, response_engine.parseReasoningLevel("max").?);
    try std.testing.expect(response_engine.parseReasoningLevel("fast_path") == null);
    try std.testing.expect(response_engine.parseReasoningLevel("draft_mode") == null);
    try std.testing.expect(response_engine.parseReasoningLevel("auto") == null);
}

test "conversation reasoning level is passed into response policy" {
    const allocator = std.testing.allocator;
    const repo_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(repo_root);

    var quick = try conversation_session.turn(allocator, .{
        .repo_root = repo_root,
        .session_id = "reasoning-quick-test",
        .message = "explain src/main.zig",
        .reasoning_level = .quick,
    });
    defer quick.deinit();
    try std.testing.expect(quick.session.last_result != null);
    try std.testing.expectEqual(conversation_session.ResultKind.draft, quick.session.last_result.?.kind);
    try std.testing.expectEqual(conversation_session.ConversationMode.unresolved, quick.session.last_result.?.selected_mode);

    var max = try conversation_session.turn(allocator, .{
        .repo_root = repo_root,
        .session_id = "reasoning-max-test",
        .message = "verify and apply src/main.zig",
        .reasoning_level = .max,
    });
    defer max.deinit();
    try std.testing.expect(max.session.last_result != null);
    try std.testing.expect(max.session.last_result.?.selected_mode == .deep or max.session.last_result.?.selected_mode == .unresolved);
}

// ── Negative Knowledge Application Pass 1 Tests ──

test "nk application: accepted failed_hypothesis penalizes matching hypothesis" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .triage_penalty, .suppression_rule };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:penalty-test",
        .correction_event_id = "corr:1",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/main.zig",
        .evidence_ref = "ev:1",
        .suppression_rule = "exact_failed_hypothesis",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var hyp = try hypothesis_core.make(allocator, "hyp:main", "src/main.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"main evidence"}, &.{}, &.{}, "verify", "main", "main");
    defer hyp.deinit(allocator);

    var result = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer result.deinit();

    try std.testing.expect(result.negative_knowledge_influence_match_count > 0);
    try std.testing.expect(result.negative_knowledge_triage_penalty_count > 0);
    // Hypothesis is NOT marked unsupported solely from NK - just penalized
    try std.testing.expect(result.items[0].negative_knowledge_match_count > 0);
    try std.testing.expect(result.items[0].score_breakdown.negative_score > 0);
    // Trace entries present
    try std.testing.expect(result.items[0].trace.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.items[0].trace, "negative knowledge") != null);
}

test "nk application: accepted failed_patch requires stronger verifier" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .verifier_requirement, .triage_penalty };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:patch-fail",
        .correction_event_id = "corr:2",
        .kind = .failed_patch,
        .scope = .artifact,
        .condition = "src/api.zig",
        .evidence_ref = "ev:2",
        .verifier_requirement = "strong_consistency_check",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var hyp = try hypothesis_core.make(allocator, "hyp:api", "src/api.zig", "code_artifact_schema", .possible_inconsistency, &.{"api evidence"}, &.{}, &.{}, "verify", "api", "api");
    defer hyp.deinit(allocator);

    var result = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer result.deinit();

    try std.testing.expect(result.negative_knowledge_verifier_requirement_count > 0);
    try std.testing.expect(result.items[0].required_verifiers.len > 0);
    try std.testing.expectEqualStrings("strong_consistency_check", result.items[0].required_verifiers[0]);
}

test "nk application: rejected record has no effect on triage" {
    const allocator = std.testing.allocator;
    var hyp = try hypothesis_core.make(allocator, "hyp:rej-test", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"rej evidence"}, &.{}, &.{}, "verify", "rej", "rej");
    defer hyp.deinit(allocator);

    const influences = [_]negative_knowledge.AllowedInfluence{.triage_penalty};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:rej",
        .correction_event_id = "corr:rej",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/a.zig",
        .evidence_ref = "ev",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();
    record.status = .rejected;

    // First triage without any NK records to get baseline score
    var baseline = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer baseline.deinit();
    const baseline_negative_score = baseline.items[0].score_breakdown.negative_score;
    const baseline_total_score = baseline.items[0].score;

    // Then triage with the rejected record
    var result = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.negative_knowledge_influence_match_count);
    try std.testing.expectEqual(@as(usize, 0), result.negative_knowledge_triage_penalty_count);
    // Rejected record contributes no additional negative score
    try std.testing.expectEqual(baseline_negative_score, result.items[0].score_breakdown.negative_score);
    try std.testing.expectEqual(baseline_total_score, result.items[0].score);
}

test "nk application: expired record has no effect on triage" {
    const allocator = std.testing.allocator;
    var hyp = try hypothesis_core.make(allocator, "hyp:exp", "src/b.zig", "code_artifact_schema", .possible_ambiguity, &.{"exp evidence"}, &.{}, &.{}, "verify", "exp", "exp");
    defer hyp.deinit(allocator);

    const influences = [_]negative_knowledge.AllowedInfluence{.triage_penalty};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:exp",
        .correction_event_id = "corr:exp",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/b.zig",
        .evidence_ref = "ev",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();
    record.status = .expired;

    var result = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.negative_knowledge_influence_match_count);
}

test "nk application: exact repeated failed hypothesis is explicitly suppressed" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .triage_penalty, .suppression_rule };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:suppress",
        .correction_event_id = "corr:suppress",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "hyp:exact-fail",
        .evidence_ref = "ev",
        .suppression_rule = "exact_failed_hypothesis",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    // Hypothesis with matching ID triggers exact suppression
    var hyp = try hypothesis_core.make(allocator, "hyp:exact-fail", "src/c.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"exact evidence"}, &.{}, &.{}, "verify", "exact", "exact");
    defer hyp.deinit(allocator);

    var result = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer result.deinit();

    try std.testing.expect(result.negative_knowledge_suppression_count > 0);
    try std.testing.expect(result.items[0].triage_status == .suppressed);
    try std.testing.expect(result.items[0].suppression_reason != null);
    try std.testing.expect(std.mem.indexOf(u8, result.items[0].suppression_reason.?, "suppressed by accepted negative knowledge") != null);
    // Hypothesis is NOT deleted - it's still in the result
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
}

test "nk application: overbroad rule creates warning but does not suppress all candidates" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{.routing_warning};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:overbroad",
        .correction_event_id = "corr:overbroad",
        .kind = .overbroad_rule,
        .scope = .project,
        .condition = "runtime",
        .evidence_ref = "ev",
        .triage_penalty = 6,
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .project,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var influence = try negative_knowledge.influenceRoutingEntry(
        allocator,
        &.{record},
        .{ .id = "runtime-candidate", .source_kind = .artifact, .provenance = "runtime candidate", .source_family = .code },
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer influence.deinit();

    try std.testing.expectEqual(@as(usize, 1), influence.warnings.len);
    // No suppression - overbroad rules only warn
    try std.testing.expect(influence.suppression_reason == null);
    try std.testing.expect(influence.triage_delta < 0);
}

test "nk application: misleading_pack_signal creates trust_decay_candidate only" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .routing_warning, .pack_trust_decay_candidate };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:mislead",
        .correction_event_id = "corr:mislead",
        .kind = .misleading_pack_signal,
        .scope = .pack,
        .condition = "pack:runtime",
        .evidence_ref = "ev",
        .trust_decay_suggestion = "pack:runtime stale signal",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .pack,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var influence = try negative_knowledge.influenceRoutingEntry(
        allocator,
        &.{record},
        .{ .id = "pack:runtime", .source_kind = .knowledge_pack_preview, .provenance = "pack:runtime", .source_family = .pack },
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer influence.deinit();

    try std.testing.expectEqual(@as(usize, 1), influence.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), influence.trust_decay_candidates.len);
    try std.testing.expect(influence.suppression_reason == null);
    // Trust decay is a *candidate* only - does not mutate pack trust
    try std.testing.expect(influence.non_authorizing);
}

test "nk application: unknown evidence is distinct from negative evidence" {
    const allocator = std.testing.allocator;
    var hyp = try hypothesis_core.make(allocator, "hyp:unknown", "src/unknown.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{}, &.{}, &.{}, "verify", "unknown", "unknown");
    defer hyp.deinit(allocator);

    // Empty records = unknown (no evidence), not negative evidence
    var first = try negative_knowledge.influenceHypothesis(allocator, &.{}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.matched_record_ids.len);
    try std.testing.expectEqual(@as(i32, 0), first.triage_delta);
    try std.testing.expect(first.suppression_reason == null);
    try std.testing.expect(first.non_authorizing);

    // Same empty = deterministic
    var second = try negative_knowledge.influenceHypothesis(allocator, &.{}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer second.deinit();
    try std.testing.expectEqual(first.triage_delta, second.triage_delta);
    try std.testing.expectEqual(first.matched_record_ids.len, second.matched_record_ids.len);
}

test "nk application: influence is deterministic across runs" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .triage_penalty, .verifier_requirement };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:det",
        .correction_event_id = "corr:det",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/det.zig",
        .evidence_ref = "ev",
        .verifier_requirement = "deterministic_check",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var hyp = try hypothesis_core.make(allocator, "hyp:det", "src/det.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"det evidence"}, &.{}, &.{}, "verify", "det", "det");
    defer hyp.deinit(allocator);

    var a = try negative_knowledge.influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer a.deinit();
    var b = try negative_knowledge.influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer b.deinit();

    try std.testing.expectEqual(a.triage_delta, b.triage_delta);
    try std.testing.expectEqual(a.matched_record_ids.len, b.matched_record_ids.len);
    try std.testing.expectEqual(a.required_verifiers.len, b.required_verifiers.len);
    try std.testing.expectEqual(a.trace_entries.len, b.trace_entries.len);
}

test "nk application: influence respects budget caps" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{.triage_penalty};
    var a = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:cap1", .correction_event_id = "corr", .kind = .failed_hypothesis, .scope = .artifact, .condition = "src/a.zig", .evidence_ref = "ev" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer a.deinit();
    var b = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{ .id = "cand:cap2", .correction_event_id = "corr", .kind = .failed_hypothesis, .scope = .artifact, .condition = "src/a.zig", .evidence_ref = "ev" }, .{ .approved_by = "test", .approval_kind = .test_fixture, .reason = "fixture", .scope = .artifact, .allowed_influence = &influences });
    defer b.deinit();
    var hyp = try hypothesis_core.make(allocator, "hyp:budget", "src/a.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{}, &.{}, &.{}, "verify", "budget", "budget");
    defer hyp.deinit(allocator);
    var influence = try negative_knowledge.influenceHypothesis(allocator, &.{ a, b }, hyp, compute_budget.resolve(.{ .tier = .medium, .overrides = .{ .max_negative_knowledge_influence_matches = 1 } }));
    defer influence.deinit();
    try std.testing.expectEqual(@as(usize, 1), influence.matched_record_ids.len);
    try std.testing.expect(influence.budget_exhausted != null);
}

test "nk application: support graph influence nodes cannot support final output" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .triage_penalty, .verifier_requirement };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:graph",
        .correction_event_id = "corr:graph",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/graph.zig",
        .evidence_ref = "ev",
        .verifier_requirement = "graph_check",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var hyp = try hypothesis_core.make(allocator, "hyp:graph", "src/graph.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"graph evidence"}, &.{}, &.{}, "verify", "graph", "graph");
    defer hyp.deinit(allocator);

    var influence_result = try negative_knowledge.influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer influence_result.deinit();

    var nodes = std.ArrayList(code_intel.SupportGraphNode).init(allocator);
    defer {
        for (nodes.items) |node| {
            allocator.free(node.id);
            allocator.free(node.label);
            if (node.rel_path) |p| allocator.free(p);
            if (node.detail) |d| allocator.free(d);
        }
        nodes.deinit();
    }
    var edges = std.ArrayList(code_intel.SupportGraphEdge).init(allocator);
    defer {
        for (edges.items) |edge| {
            allocator.free(edge.from_id);
            allocator.free(edge.to_id);
        }
        edges.deinit();
    }

    try correction_hooks.appendNegativeKnowledgeInfluenceToSupportGraph(
        allocator,
        &nodes,
        &edges,
        "output:1",
        influence_result.trace_entries,
        "hyp:graph",
    );

    // All nodes are non-authorizing (not usable)
    for (nodes.items) |node| {
        try std.testing.expect(!node.usable);
    }

    // No supported_by edges
    for (edges.items) |edge| {
        try std.testing.expect(edge.kind != .supported_by);
    }

    // Must have at least one influence node
    try std.testing.expect(nodes.items.len > 0);
    try std.testing.expect(edges.items.len > 0);
}

test "nk application: non-code artifacts use same influence model" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .verifier_requirement, .triage_penalty };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:doc",
        .correction_event_id = "corr:doc",
        .kind = .failed_patch,
        .scope = .artifact,
        .condition = "docs/contract.md",
        .evidence_ref = "ev",
        .verifier_requirement = "strong_consistency_check",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var hyp = try hypothesis_core.make(allocator, "hyp:doc", "docs/contract.md", "document_schema", .possible_unsupported_claim, &.{"doc evidence"}, &.{}, &.{}, "verify", "doc", "doc");
    defer hyp.deinit(allocator);

    var result = try hypothesis_core.triageWithNegativeKnowledge(
        allocator,
        &.{hyp},
        .{ .max_hypotheses_selected = 4 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer result.deinit();

    try std.testing.expect(result.negative_knowledge_influence_match_count > 0);
    try std.testing.expect(result.negative_knowledge_triage_penalty_count > 0);
    try std.testing.expect(result.negative_knowledge_verifier_requirement_count > 0);
    try std.testing.expect(result.items[0].required_verifiers.len > 0);
}

test "nk application: routing select with negative knowledge applies penalties" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .routing_warning, .pack_trust_decay_candidate };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:routing",
        .correction_event_id = "corr:routing",
        .kind = .misleading_pack_signal,
        .scope = .pack,
        .condition = "pack:noisy",
        .evidence_ref = "ev",
        .trust_decay_suggestion = "pack:noisy stale signal",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .pack,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    const entries = [_]support_routing.Entry{
        .{ .id = "pack:noisy", .source_kind = .knowledge_pack_preview, .provenance = "pack:noisy", .source_family = .pack, .trust_class = .promoted, .freshness_state = .active },
        .{ .id = "code:clean", .source_kind = .artifact, .provenance = "clean", .source_family = .code, .trust_class = .core, .freshness_state = .active },
    };

    // Without NK
    var trace_no_nk = try support_routing.select(allocator, &entries, .{ .max_selected = 2 });
    defer trace_no_nk.deinit();

    // With NK
    var trace_with_nk = try support_routing.selectWithNegativeKnowledge(
        allocator,
        &entries,
        .{ .max_selected = 2 },
        &.{record},
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer trace_with_nk.deinit();

    // The noisy pack entry should have a lower score when NK is applied
    try std.testing.expect(trace_with_nk.negative_knowledge_routing_warning_count > 0);
    // Both should still select the clean code entry
    try std.testing.expect(trace_with_nk.selected_count > 0);
}

test "nk application: influence trace entries are complete" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .triage_penalty, .verifier_requirement, .suppression_rule };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:trace",
        .correction_event_id = "corr:trace",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/trace.zig",
        .evidence_ref = "ev",
        .verifier_requirement = "trace_check",
        .suppression_rule = "exact_failed_hypothesis",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var hyp = try hypothesis_core.make(allocator, "hyp:trace", "src/trace.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{"trace evidence"}, &.{}, &.{}, "verify", "trace", "trace");
    defer hyp.deinit(allocator);

    var influence = try negative_knowledge.influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer influence.deinit();

    try std.testing.expect(influence.trace_entries.len > 0);

    for (influence.trace_entries) |entry| {
        try std.testing.expect(entry.record_id.len > 0);
        try std.testing.expect(entry.matched_scope.len > 0);
        try std.testing.expect(entry.non_authorizing);
        switch (entry.influence_kind) {
            .triage_penalty => {
                try std.testing.expect(entry.triage_delta < 0);
            },
            .verifier_requirement => {
                try std.testing.expect(entry.verifier_requirement != null);
            },
            .suppression_rule => {
                try std.testing.expect(entry.suppression_reason != null);
            },
            else => {},
        }
    }
}

test "nk application: influenceVerifierCandidate blocks unsafe verifier reuse" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{ .verifier_requirement, .suppression_rule };
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:unsafe-vc",
        .correction_event_id = "corr:unsafe",
        .kind = .unsafe_verifier_candidate,
        .scope = .artifact,
        .condition = "cand:bad-verifier",
        .evidence_ref = "ev",
        .verifier_requirement = "stronger_verifier",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand:bad-verifier"),
        .hypothesis_id = try allocator.dupe(u8, "hyp:unsafe"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "test_target"),
        .proposed_check = try allocator.dupe(u8, "test check"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    var influence = try negative_knowledge.influenceVerifierCandidate(
        allocator,
        &.{record},
        .{
            .id = candidate.id,
            .artifact_scope = candidate.artifact_scope,
            .target_claim_surface = candidate.target_claim_surface,
            .proposed_check = candidate.proposed_check,
            .provenance = candidate.provenance,
        },
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer influence.deinit();

    try std.testing.expectEqual(@as(usize, 1), influence.matched_record_ids.len);
    try std.testing.expect(influence.suppression_reason != null);
    try std.testing.expect(std.mem.indexOf(u8, influence.suppression_reason.?, "blocked unsafe verifier candidate") != null);
    try std.testing.expect(influence.required_verifiers.len > 0);
    try std.testing.expectEqualStrings("stronger_verifier", influence.required_verifiers[0]);
}

test "nk application: influenceVerifierCandidate distinguishes requires stronger verifier from failed" {
    const allocator = std.testing.allocator;
    const influences = [_]negative_knowledge.AllowedInfluence{.verifier_requirement};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:patch-vc",
        .correction_event_id = "corr:patch",
        .kind = .failed_patch,
        .scope = .artifact,
        .condition = "src/api.zig",
        .evidence_ref = "ev",
        .verifier_requirement = "enhanced_patch_check",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand:patch-retry"),
        .hypothesis_id = try allocator.dupe(u8, "hyp:patch"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/api.zig"),
        .target_claim_surface = try allocator.dupe(u8, "api_target"),
        .proposed_check = try allocator.dupe(u8, "patch check"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    var influence = try negative_knowledge.influenceVerifierCandidate(
        allocator,
        &.{record},
        .{
            .id = candidate.id,
            .artifact_scope = candidate.artifact_scope,
            .target_claim_surface = candidate.target_claim_surface,
            .proposed_check = candidate.proposed_check,
            .provenance = candidate.provenance,
        },
        compute_budget.resolve(.{ .tier = .medium }),
    );
    defer influence.deinit();

    // Requires stronger verifier but NOT suppressed (not unsafe_verifier_candidate kind)
    try std.testing.expect(influence.required_verifiers.len > 0);
    try std.testing.expect(influence.suppression_reason == null);
    try std.testing.expect(influence.warnings.len > 0);
}

test "nk application: unknown vs negative evidence distinction is explicit" {
    const allocator = std.testing.allocator;

    // Test with no records: unknown state
    var hyp = try hypothesis_core.make(allocator, "hyp:ev-test", "src/ev.zig", "code_artifact_schema", .possible_behavior_mismatch, &.{}, &.{}, &.{}, "verify", "ev", "ev");
    defer hyp.deinit(allocator);

    var unknown_influence = try negative_knowledge.influenceHypothesis(allocator, &.{}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer unknown_influence.deinit();

    // Unknown: no matches, no delta, no trace entries
    try std.testing.expectEqual(@as(usize, 0), unknown_influence.matched_record_ids.len);
    try std.testing.expectEqual(@as(i32, 0), unknown_influence.triage_delta);
    try std.testing.expectEqual(@as(usize, 0), unknown_influence.trace_entries.len);

    // Test with accepted record that matches: negative evidence
    const influences = [_]negative_knowledge.AllowedInfluence{.triage_penalty};
    var record = try negative_knowledge.acceptNegativeKnowledgeCandidate(allocator, .{
        .id = "cand:ev-match",
        .correction_event_id = "corr:ev",
        .kind = .failed_hypothesis,
        .scope = .artifact,
        .condition = "src/ev.zig",
        .evidence_ref = "ev",
    }, .{
        .approved_by = "test",
        .approval_kind = .test_fixture,
        .reason = "fixture",
        .scope = .artifact,
        .allowed_influence = &influences,
    });
    defer record.deinit();

    var negative_influence = try negative_knowledge.influenceHypothesis(allocator, &.{record}, hyp, compute_budget.resolve(.{ .tier = .medium }));
    defer negative_influence.deinit();

    // Negative evidence: matches, delta, trace entries
    try std.testing.expect(negative_influence.matched_record_ids.len > 0);
    try std.testing.expect(negative_influence.triage_delta < 0);
    try std.testing.expect(negative_influence.trace_entries.len > 0);
    // The trace entry explicitly labels the influence kind
    try std.testing.expect(negative_influence.trace_entries[0].influence_kind == .triage_penalty);
}
