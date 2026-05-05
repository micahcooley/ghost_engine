const std = @import("std");
const project_autopsy = @import("project_autopsy.zig");

pub const SCHEMA_VERSION = "learning_loop_plan.v1";

pub const PlanOptions = struct {
    plan_id: ?[]const u8 = null,
};

pub const LearningLoopNextStep = struct {
    id: []const u8,
    kind: []const u8,
    reason: []const u8,
    related_autopsy_ids: []const []const u8 = &.{},
    evidence_paths: []const []const u8 = &.{},
    requires_approval: bool = true,
    executes_by_default: bool = false,
    applies_by_default: bool = false,
    non_authorizing: bool = true,
};

pub const VerifierCandidateRef = struct {
    id: []const u8,
    source_command_candidate_id: []const u8,
    argv: []const []const u8,
    cwd_hint: []const u8,
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    requires_approval: bool = true,
    executes_by_default: bool = false,
    non_authorizing: bool = true,
};

pub const LoopPlaceholderCandidate = struct {
    id: []const u8,
    kind: []const u8,
    reason: []const u8,
    source_next_step_id: []const u8,
    related_autopsy_ids: []const []const u8 = &.{},
    evidence_paths: []const []const u8 = &.{},
    requires_review: bool = true,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    mutates_state: bool = false,
    applies_by_default: bool = false,
};

pub const PlanUnknown = struct {
    id: []const u8,
    kind: []const u8 = "learning_loop_unknown",
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    is_negative_evidence: bool = false,
    non_authorizing: bool = true,
};

pub const LearningLoopPlan = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    plan_id: []const u8,
    source: []const u8 = "project_autopsy",
    autopsy_schema_version: []const u8,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    read_only: bool = true,
    mutates_state: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    patches_applied: bool = false,
    packs_mutated: bool = false,
    corrections_applied: bool = false,
    negative_knowledge_promoted: bool = false,
    corpus_mutated: bool = false,
    trust_state_mutated: bool = false,
    snapshots_mutated: bool = false,
    scratch_state_mutated: bool = false,
    support_granted: bool = false,
    proof_discharged: bool = false,
    next_steps: []LearningLoopNextStep = &.{},
    verifier_candidate_refs: []VerifierCandidateRef = &.{},
    failure_ingestion_candidates: []LoopPlaceholderCandidate = &.{},
    correction_candidate_placeholders: []LoopPlaceholderCandidate = &.{},
    negative_knowledge_candidate_placeholders: []LoopPlaceholderCandidate = &.{},
    procedure_pack_candidate_placeholders: []LoopPlaceholderCandidate = &.{},
    unknowns: []PlanUnknown = &.{},
    state: []const u8 = "draft",

    pub fn writeJson(self: LearningLoopPlan, writer: anytype) !void {
        try std.json.stringify(self, .{ .whitespace = .indent_2 }, writer);
    }
};

pub fn planFromAutopsy(allocator: std.mem.Allocator, autopsy: project_autopsy.AutopsyResult, options: PlanOptions) !LearningLoopPlan {
    var next_steps = std.ArrayList(LearningLoopNextStep).init(allocator);
    var verifier_refs = std.ArrayList(VerifierCandidateRef).init(allocator);
    var failure_candidates = std.ArrayList(LoopPlaceholderCandidate).init(allocator);
    var correction_candidates = std.ArrayList(LoopPlaceholderCandidate).init(allocator);
    var negative_knowledge_candidates = std.ArrayList(LoopPlaceholderCandidate).init(allocator);
    var procedure_pack_candidates = std.ArrayList(LoopPlaceholderCandidate).init(allocator);
    var unknowns = std.ArrayList(PlanUnknown).init(allocator);

    for (autopsy.project_profile.safe_command_candidates) |candidate| {
        const step_id = try std.fmt.allocPrint(allocator, "learning.step.verifier.{s}", .{candidate.id});
        const related_ids = try dupeStringSlice(allocator, &.{candidate.id});
        const evidence_paths = try dupeStringSlice(allocator, candidate.evidence_paths);
        try next_steps.append(.{
            .id = step_id,
            .kind = try allocator.dupe(u8, "approval_required_verifier_candidate"),
            .reason = try std.fmt.allocPrint(allocator, "Safe command candidate {s} can become an approved verifier candidate only after explicit operator approval; it was not executed.", .{candidate.id}),
            .related_autopsy_ids = related_ids,
            .evidence_paths = evidence_paths,
        });
        try verifier_refs.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.verifier_ref.{s}", .{candidate.id}),
            .source_command_candidate_id = try allocator.dupe(u8, candidate.id),
            .argv = try dupeStringSlice(allocator, candidate.argv),
            .cwd_hint = try allocator.dupe(u8, candidate.cwd),
            .reason = try allocator.dupe(u8, candidate.why_candidate_exists),
            .evidence_paths = try dupeStringSlice(allocator, candidate.evidence_paths),
        });
        try failure_candidates.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.failure_ingestion.{s}", .{candidate.id}),
            .kind = try allocator.dupe(u8, "failure_ingestion_candidate"),
            .reason = try allocator.dupe(u8, "If an explicitly approved verifier run fails later, ingest that failure as candidate signal only; this plan does not run or ingest it."),
            .source_next_step_id = try allocator.dupe(u8, step_id),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{candidate.id}),
            .evidence_paths = try dupeStringSlice(allocator, candidate.evidence_paths),
        });
    }

    for (autopsy.project_gap_report.missing_verifier_adapters) |gap| {
        const step_id = try std.fmt.allocPrint(allocator, "learning.step.missing_evidence.{s}", .{gap.id});
        try next_steps.append(.{
            .id = step_id,
            .kind = try allocator.dupe(u8, "missing_evidence_step"),
            .reason = try std.fmt.allocPrint(allocator, "Verifier gap {s} remains missing evidence; absence is not a negative claim.", .{gap.id}),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{gap.id}),
            .evidence_paths = try dupeStringSlice(allocator, gap.evidence_paths),
        });
        try unknowns.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.unknown.{s}", .{gap.id}),
            .reason = try allocator.dupe(u8, gap.reason),
            .evidence_paths = try dupeStringSlice(allocator, gap.evidence_paths),
        });
    }

    for (autopsy.project_profile.risk_surfaces) |risk| {
        const step_id = try std.fmt.allocPrint(allocator, "learning.step.triage.{s}", .{risk.id});
        try next_steps.append(.{
            .id = step_id,
            .kind = try allocator.dupe(u8, "triage_candidate"),
            .reason = try std.fmt.allocPrint(allocator, "Risk surface {s} needs human triage before any verifier, correction, negative knowledge, or patch path can use it.", .{risk.id}),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{risk.id}),
            .evidence_paths = try dupeStringSlice(allocator, risk.evidence_paths),
        });
        try correction_candidates.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.correction_placeholder.{s}", .{risk.id}),
            .kind = try allocator.dupe(u8, "correction_candidate_placeholder"),
            .reason = try allocator.dupe(u8, "A later reviewed failure may justify a correction candidate; this placeholder is not an accepted correction."),
            .source_next_step_id = try allocator.dupe(u8, step_id),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{risk.id}),
            .evidence_paths = try dupeStringSlice(allocator, risk.evidence_paths),
        });
        try negative_knowledge_candidates.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.negative_knowledge_placeholder.{s}", .{risk.id}),
            .kind = try allocator.dupe(u8, "negative_knowledge_candidate_placeholder"),
            .reason = try allocator.dupe(u8, "A later reviewed repeated failure may justify negative-knowledge review; this placeholder is not accepted negative knowledge."),
            .source_next_step_id = try allocator.dupe(u8, step_id),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{risk.id}),
            .evidence_paths = try dupeStringSlice(allocator, risk.evidence_paths),
        });
    }

    for (autopsy.project_profile.recommended_guidance_candidates) |guidance| {
        const step_id = try std.fmt.allocPrint(allocator, "learning.step.guidance_review.{s}", .{guidance.id});
        try next_steps.append(.{
            .id = step_id,
            .kind = try allocator.dupe(u8, "procedure_guidance_review_candidate"),
            .reason = try std.fmt.allocPrint(allocator, "Guidance candidate {s} requires review and cannot mutate or apply a procedure pack by default.", .{guidance.id}),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{guidance.id}),
            .evidence_paths = try dupeStringSlice(allocator, guidance.evidence_paths),
        });
        try procedure_pack_candidates.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.procedure_pack_placeholder.{s}", .{guidance.id}),
            .kind = try allocator.dupe(u8, "procedure_pack_candidate_placeholder"),
            .reason = try allocator.dupe(u8, "Procedure guidance may become a separately reviewed pack candidate later; this plan does not apply or mutate packs."),
            .source_next_step_id = try allocator.dupe(u8, step_id),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{guidance.id}),
            .evidence_paths = try dupeStringSlice(allocator, guidance.evidence_paths),
        });
    }

    for (autopsy.project_profile.unknowns) |unknown| {
        const step_id = try std.fmt.allocPrint(allocator, "learning.step.evidence_collection.{s}", .{unknown.name});
        try next_steps.append(.{
            .id = step_id,
            .kind = try allocator.dupe(u8, "evidence_collection_candidate"),
            .reason = try std.fmt.allocPrint(allocator, "Unknown autopsy signal {s} requires evidence collection; unknown is not false.", .{unknown.name}),
            .related_autopsy_ids = try dupeStringSlice(allocator, &.{unknown.name}),
            .evidence_paths = try dupeStringSlice(allocator, unknown.evidence_paths),
        });
        try unknowns.append(.{
            .id = try std.fmt.allocPrint(allocator, "learning.unknown.{s}", .{unknown.name}),
            .reason = try allocator.dupe(u8, unknown.reason),
            .evidence_paths = try dupeStringSlice(allocator, unknown.evidence_paths),
        });
    }

    if (next_steps.items.len == 0) {
        try next_steps.append(.{
            .id = try allocator.dupe(u8, "learning.step.evidence_collection.no_autopsy_candidates"),
            .kind = try allocator.dupe(u8, "evidence_collection_candidate"),
            .reason = try allocator.dupe(u8, "Project autopsy produced no concrete candidate surfaces; collect more evidence instead of treating absence as negative evidence."),
            .requires_approval = true,
        });
        try unknowns.append(.{
            .id = try allocator.dupe(u8, "learning.unknown.no_autopsy_candidates"),
            .reason = try allocator.dupe(u8, "No safe command, verifier gap, risk surface, guidance candidate, or unknown was available from project autopsy."),
        });
    }

    return .{
        .plan_id = try allocator.dupe(u8, options.plan_id orelse "learning_loop_plan.project_autopsy.v1"),
        .autopsy_schema_version = try allocator.dupe(u8, autopsy.autopsy_schema_version),
        .next_steps = try next_steps.toOwnedSlice(),
        .verifier_candidate_refs = try verifier_refs.toOwnedSlice(),
        .failure_ingestion_candidates = try failure_candidates.toOwnedSlice(),
        .correction_candidate_placeholders = try correction_candidates.toOwnedSlice(),
        .negative_knowledge_candidate_placeholders = try negative_knowledge_candidates.toOwnedSlice(),
        .procedure_pack_candidate_placeholders = try procedure_pack_candidates.toOwnedSlice(),
        .unknowns = try unknowns.toOwnedSlice(),
    };
}

fn dupeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| out[i] = try allocator.dupe(u8, item);
    return out;
}

fn minimalAutopsy() project_autopsy.AutopsyResult {
    return .{
        .operator_summary = .{ .project_shape_summary = "test" },
        .project_profile = .{ .workspace_root = "/tmp/test" },
        .project_gap_report = .{},
    };
}

test "learning loop plan derives approval-required verifier candidate refs from safe commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var autopsy = minimalAutopsy();
    var commands = [_]project_autopsy.SafeCommandCandidate{
        .{
            .id = "zig_build_test",
            .argv = &.{ "zig", "build", "test" },
            .cwd = "/workspace",
            .purpose = "test",
            .reason = "test step detected",
            .detected_from = "build.zig",
            .evidence_paths = &.{"build.zig"},
            .risk_level = "medium",
            .mutation_risk_disclosure = "candidate only",
            .why_candidate_exists = "detected from build.zig",
        },
    };
    autopsy.project_profile.safe_command_candidates = commands[0..];

    const plan = try planFromAutopsy(allocator, autopsy, .{});
    try std.testing.expectEqual(@as(usize, 1), plan.verifier_candidate_refs.len);
    try std.testing.expectEqualStrings("approval_required_verifier_candidate", plan.next_steps[0].kind);
    try std.testing.expect(plan.next_steps[0].requires_approval);
    try std.testing.expect(!plan.next_steps[0].executes_by_default);
    try std.testing.expect(!plan.verifier_candidate_refs[0].executes_by_default);
    try std.testing.expectEqualStrings("zig_build_test", plan.verifier_candidate_refs[0].source_command_candidate_id);
}

test "learning loop plan derives missing-evidence next step from verifier gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var autopsy = minimalAutopsy();
    var gaps = [_]project_autopsy.VerifierGapCandidate{
        .{
            .id = "gap.test_adapter_missing",
            .missing_verifier = "code.test",
            .reason = "no verifier adapter registered",
            .evidence_paths = &.{"build.zig"},
        },
    };
    autopsy.project_gap_report.missing_verifier_adapters = gaps[0..];

    const plan = try planFromAutopsy(allocator, autopsy, .{});
    try std.testing.expectEqualStrings("missing_evidence_step", plan.next_steps[0].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.unknowns.len);
    try std.testing.expect(!plan.unknowns[0].is_negative_evidence);
}

test "learning loop plan derives triage candidate from risk surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var autopsy = minimalAutopsy();
    var risks = [_]project_autopsy.RiskSurface{
        .{
            .id = "risk.untrusted_script",
            .kind = "script_risk",
            .path = "package.json",
            .risk_level = "high",
            .risk_kind = "script_risk",
            .reason = "script needs review",
            .evidence_paths = &.{"package.json"},
            .suggested_caution = "review before running",
        },
    };
    autopsy.project_profile.risk_surfaces = risks[0..];

    const plan = try planFromAutopsy(allocator, autopsy, .{});
    try std.testing.expectEqualStrings("triage_candidate", plan.next_steps[0].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.correction_candidate_placeholders.len);
    try std.testing.expectEqual(@as(usize, 1), plan.negative_knowledge_candidate_placeholders.len);
    try std.testing.expect(!plan.correction_candidate_placeholders[0].mutates_state);
}

test "learning loop plan derives review-required guidance step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var autopsy = minimalAutopsy();
    var guidance_candidates = [_]project_autopsy.RecommendedGuidanceCandidate{
        .{
            .id = "guidance.test_discovery",
            .kind = "pack_guidance_candidate",
            .guidance_id = "test_discovery_guidance",
            .reason = "tests need discovery guidance",
            .evidence_paths = &.{"build.zig"},
            .suggested_next_action = "review guidance",
        },
    };
    autopsy.project_profile.recommended_guidance_candidates = guidance_candidates[0..];

    const plan = try planFromAutopsy(allocator, autopsy, .{});
    try std.testing.expectEqualStrings("procedure_guidance_review_candidate", plan.next_steps[0].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.procedure_pack_candidate_placeholders.len);
    try std.testing.expect(!plan.procedure_pack_candidate_placeholders[0].applies_by_default);
}

test "learning loop plan keeps empty autopsy as unknown evidence-collection candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const plan = try planFromAutopsy(allocator, minimalAutopsy(), .{});
    try std.testing.expectEqual(@as(usize, 1), plan.next_steps.len);
    try std.testing.expectEqualStrings("evidence_collection_candidate", plan.next_steps[0].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.unknowns.len);
    try std.testing.expect(!plan.unknowns[0].is_negative_evidence);
}

test "learning loop plan safety flags are non-execution and non-mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const plan = try planFromAutopsy(allocator, minimalAutopsy(), .{});
    try std.testing.expect(plan.candidate_only);
    try std.testing.expect(plan.non_authorizing);
    try std.testing.expect(plan.read_only);
    try std.testing.expect(!plan.mutates_state);
    try std.testing.expect(!plan.commands_executed);
    try std.testing.expect(!plan.verifiers_executed);
    try std.testing.expect(!plan.patches_applied);
    try std.testing.expect(!plan.packs_mutated);
    try std.testing.expect(!plan.corrections_applied);
    try std.testing.expect(!plan.negative_knowledge_promoted);
    try std.testing.expect(!plan.corpus_mutated);
    try std.testing.expect(!plan.trust_state_mutated);
    try std.testing.expect(!plan.snapshots_mutated);
    try std.testing.expect(!plan.scratch_state_mutated);
    try std.testing.expect(!plan.support_granted);
    try std.testing.expect(!plan.proof_discharged);
}

test "LearningLoopPlan struct invariants: plan is read-only and candidate-only by default" {
    const plan = LearningLoopPlan{
        .plan_id = "test",
        .autopsy_schema_version = "v1",
    };
    try std.testing.expect(plan.candidate_only);
    try std.testing.expect(plan.non_authorizing);
    try std.testing.expect(plan.read_only);
}

test "LearningLoopPlan struct invariants: no execution or mutation by default" {
    const plan = LearningLoopPlan{
        .plan_id = "test",
        .autopsy_schema_version = "v1",
    };
    try std.testing.expect(!plan.mutates_state);
    try std.testing.expect(!plan.commands_executed);
    try std.testing.expect(!plan.verifiers_executed);
    try std.testing.expect(!plan.patches_applied);
    try std.testing.expect(!plan.packs_mutated);
    try std.testing.expect(!plan.corrections_applied);
    try std.testing.expect(!plan.negative_knowledge_promoted);
    try std.testing.expect(!plan.corpus_mutated);
    try std.testing.expect(!plan.trust_state_mutated);
    try std.testing.expect(!plan.snapshots_mutated);
    try std.testing.expect(!plan.scratch_state_mutated);
    try std.testing.expect(!plan.support_granted);
    try std.testing.expect(!plan.proof_discharged);
}

test "VerifierCandidateRef struct invariants: approval-required and do not execute by default" {
    const ref = VerifierCandidateRef{
        .id = "test_id",
        .source_command_candidate_id = "test_cmd",
        .argv = &.{},
        .cwd_hint = "",
        .reason = "",
    };
    try std.testing.expect(ref.requires_approval);
    try std.testing.expect(!ref.executes_by_default);
    try std.testing.expect(ref.non_authorizing);
}

test "LoopPlaceholderCandidate struct invariants: explicit placeholder and non-mutating by default" {
    const placeholder = LoopPlaceholderCandidate{
        .id = "test_id",
        .kind = "test_kind",
        .reason = "",
        .source_next_step_id = "",
    };
    try std.testing.expect(placeholder.requires_review);
    try std.testing.expect(placeholder.candidate_only);
    try std.testing.expect(placeholder.non_authorizing);
    try std.testing.expect(!placeholder.mutates_state);
    try std.testing.expect(!placeholder.applies_by_default);
}
