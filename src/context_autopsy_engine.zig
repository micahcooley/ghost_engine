const std = @import("std");
const context_autopsy = @import("context_autopsy.zig");
const ContextCase = context_autopsy.ContextCase;
const ContextAutopsyResult = context_autopsy.ContextAutopsyResult;

pub const ContextSignalSource = struct {
    ptr: *anyopaque,
    contributeFn: *const fn (ptr: *anyopaque, case: *const ContextCase, builder: *ResultBuilder) anyerror!void,

    pub fn contribute(self: ContextSignalSource, case: *const ContextCase, builder: *ResultBuilder) anyerror!void {
        return self.contributeFn(self.ptr, case, builder);
    }
};

pub const ResultBuilder = struct {
    allocator: std.mem.Allocator,
    signals: std.ArrayList(context_autopsy.ContextSignal),
    unknowns: std.ArrayList(context_autopsy.ContextUnknown),
    risks: std.ArrayList(context_autopsy.ContextRiskSurface),
    candidates: std.ArrayList(context_autopsy.ContextCandidateAction),
    checks: std.ArrayList(context_autopsy.ContextCheckCandidate),
    constraints: std.ArrayList(context_autopsy.ContextConstraint),
    evidence_expectations: std.ArrayList(context_autopsy.EvidenceExpectation),
    pack_influences: std.ArrayList(context_autopsy.PackInfluence),

    pub fn init(allocator: std.mem.Allocator) ResultBuilder {
        return .{
            .allocator = allocator,
            .signals = std.ArrayList(context_autopsy.ContextSignal).init(allocator),
            .unknowns = std.ArrayList(context_autopsy.ContextUnknown).init(allocator),
            .risks = std.ArrayList(context_autopsy.ContextRiskSurface).init(allocator),
            .candidates = std.ArrayList(context_autopsy.ContextCandidateAction).init(allocator),
            .checks = std.ArrayList(context_autopsy.ContextCheckCandidate).init(allocator),
            .constraints = std.ArrayList(context_autopsy.ContextConstraint).init(allocator),
            .evidence_expectations = std.ArrayList(context_autopsy.EvidenceExpectation).init(allocator),
            .pack_influences = std.ArrayList(context_autopsy.PackInfluence).init(allocator),
        };
    }

    pub fn deinit(self: *ResultBuilder) void {
        self.signals.deinit();
        self.unknowns.deinit();
        self.risks.deinit();
        self.candidates.deinit();
        self.checks.deinit();
        self.constraints.deinit();
        self.evidence_expectations.deinit();
        self.pack_influences.deinit();
    }

    pub fn addUnknown(self: *ResultBuilder, unknown: context_autopsy.ContextUnknown) !void {
        try self.unknowns.append(unknown);
    }

    pub fn addSignal(self: *ResultBuilder, signal: context_autopsy.ContextSignal) !void {
        try self.signals.append(signal);
    }

    pub fn addRisk(self: *ResultBuilder, risk: context_autopsy.ContextRiskSurface) !void {
        try self.risks.append(risk);
    }

    pub fn addCandidate(self: *ResultBuilder, candidate: context_autopsy.ContextCandidateAction) !void {
        try self.candidates.append(candidate);
    }

    pub fn addCheck(self: *ResultBuilder, check: context_autopsy.ContextCheckCandidate) !void {
        try self.checks.append(check);
    }

    pub fn addConstraint(self: *ResultBuilder, constraint: context_autopsy.ContextConstraint) !void {
        try self.constraints.append(constraint);
    }

    pub fn addEvidenceExpectation(self: *ResultBuilder, expectation: context_autopsy.EvidenceExpectation) !void {
        try self.evidence_expectations.append(expectation);
    }

    pub fn addPackInfluence(self: *ResultBuilder, influence: context_autopsy.PackInfluence) !void {
        try self.pack_influences.append(influence);
    }

    pub fn build(self: *ResultBuilder, case: ContextCase) !ContextAutopsyResult {
        return ContextAutopsyResult{
            .context_case = case,
            .detected_signals = try self.signals.toOwnedSlice(),
            .suggested_unknowns = try self.unknowns.toOwnedSlice(),
            .risk_surfaces = try self.risks.toOwnedSlice(),
            .candidate_actions = try self.candidates.toOwnedSlice(),
            .check_candidates = try self.checks.toOwnedSlice(),
            .constraints = try self.constraints.toOwnedSlice(),
            .evidence_expectations = try self.evidence_expectations.toOwnedSlice(),
            .pack_influences = try self.pack_influences.toOwnedSlice(),
        };
    }
};

pub const PackGuidanceSource = struct {
    guidance: []const context_autopsy.PackAutopsyGuidance,

    pub fn init(guidance: []const context_autopsy.PackAutopsyGuidance) PackGuidanceSource {
        return .{ .guidance = guidance };
    }

    pub fn source(self: *PackGuidanceSource) ContextSignalSource {
        return .{
            .ptr = self,
            .contributeFn = contribute,
        };
    }

    fn contribute(ptr: *anyopaque, _: *const ContextCase, builder: *ResultBuilder) anyerror!void {
        const self: *PackGuidanceSource = @ptrCast(@alignCast(ptr));
        if (self.guidance.len == 0) {
            try builder.addUnknown(.{
                .name = "empty_pack_autopsy_guidance",
                .source_pack = "pack_guidance_source",
                .importance = "medium",
                .reason = "Pack guidance source was present, but no pack guidance entries were provided. Missing guidance remains unknown, not false.",
            });
            return;
        }

        for (self.guidance) |guidance| {
            try builder.addPackInfluence(.{
                .pack_name = guidance.influence.pack_name,
                .pack_version = guidance.influence.pack_version,
                .source_kind = guidance.influence.source_kind,
                .reason = guidance.influence.reason,
                .weight = guidance.influence.weight,
                .non_authorizing = true,
                .is_proof_authority = false,
            });

            for (guidance.signals) |signal| try builder.addSignal(signal);
            for (guidance.suggested_unknowns) |unknown| try builder.addUnknown(.{
                .name = unknown.name,
                .source_pack = unknown.source_pack,
                .importance = unknown.importance,
                .reason = unknown.reason,
                .is_missing_evidence = true,
                .is_negative_evidence = false,
            });
            for (guidance.constraints) |constraint| try builder.addConstraint(constraint);
            for (guidance.risk_surfaces) |risk| try builder.addRisk(.{
                .risk_kind = risk.risk_kind,
                .source_pack = risk.source_pack,
                .reason = risk.reason,
                .suggested_caution = risk.suggested_caution,
                .non_authorizing = true,
            });
            for (guidance.candidate_actions) |candidate| try builder.addCandidate(.{
                .id = candidate.id,
                .source_pack = candidate.source_pack,
                .action_type = candidate.action_type,
                .payload = candidate.payload,
                .reason = candidate.reason,
                .risk_level = candidate.risk_level,
                .requires_user_confirmation = candidate.requires_user_confirmation,
                .non_authorizing = true,
            });
            for (guidance.check_candidates) |check| try builder.addCheck(.{
                .id = check.id,
                .source_pack = check.source_pack,
                .check_type = check.check_type,
                .purpose = check.purpose,
                .risk_level = check.risk_level,
                .confidence = check.confidence,
                .evidence_strength = check.evidence_strength,
                .requires_user_confirmation = check.requires_user_confirmation,
                .non_authorizing = true,
                .executes_by_default = false,
                .why_candidate_exists = check.why_candidate_exists,
            });
            for (guidance.evidence_expectations) |expectation| try builder.addEvidenceExpectation(expectation);
        }
    }
};

pub const ContextAutopsyEngine = struct {
    allocator: std.mem.Allocator,
    signal_sources: []const ContextSignalSource,

    pub fn init(allocator: std.mem.Allocator, sources: []const ContextSignalSource) ContextAutopsyEngine {
        return .{
            .allocator = allocator,
            .signal_sources = sources,
        };
    }

    pub fn evaluate(self: *ContextAutopsyEngine, case: *const ContextCase) !ContextAutopsyResult {
        var builder = ResultBuilder.init(self.allocator);
        errdefer builder.deinit();

        if (self.signal_sources.len == 0) {
            try builder.addUnknown(.{
                .name = "no_signal_sources",
                .source_pack = "core_engine",
                .importance = "high",
                .reason = "No signal sources were provided to the Context Autopsy Engine. Cannot determine context signals.",
            });
        } else {
            for (self.signal_sources) |source| {
                try source.contribute(case, &builder);
            }
        }

        return try builder.build(case.*);
    }
};

test "empty generic ContextCase produces draft/non-authorizing ContextAutopsyResult" {
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &.{});
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };
    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("draft", result.state);
    try std.testing.expectEqual(true, result.non_authorizing);
}

test "no signal source case records explicit unknown/gap instead of false claim" {
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &.{});
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };
    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.suggested_unknowns.len);
    try std.testing.expectEqualStrings("no_signal_sources", result.suggested_unknowns[0].name);
    try std.testing.expectEqual(true, result.suggested_unknowns[0].is_missing_evidence);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
}

const MockSource = struct {
    pub fn contribute(_: *anyopaque, _: *const ContextCase, builder: *ResultBuilder) anyerror!void {
        try builder.addSignal(.{
            .name = "mock_signal",
            .source_pack = "mock_pack",
            .kind = "test",
            .confidence = "low",
            .reason = "Mock source contribution",
        });
    }

    pub fn source() ContextSignalSource {
        return .{
            .ptr = undefined,
            .contributeFn = contribute,
        };
    }
};

test "a mock signal source can contribute a signal without granting authority" {
    const sources = [_]ContextSignalSource{MockSource.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };
    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.detected_signals.len);
    try std.testing.expectEqualStrings("mock_signal", result.detected_signals[0].name);
    try std.testing.expectEqual(true, result.non_authorizing);
}

test "pack guidance source contributes generic context autopsy surfaces without authority" {
    const guidance = [_]context_autopsy.PackAutopsyGuidance{.{
        .influence = .{
            .pack_name = "test_context_pack",
            .pack_version = "v1",
            .weight = "medium",
            .reason = "test guidance",
        },
        .signals = &.{.{
            .name = "pack_signal",
            .source_pack = "test_context_pack",
            .kind = "generic_marker",
            .confidence = "medium",
            .reason = "Pack guidance matched intake shape.",
        }},
        .suggested_unknowns = &.{.{
            .name = "missing_pack_context",
            .source_pack = "test_context_pack",
            .importance = "high",
            .reason = "Pack guidance expects context not yet present.",
        }},
        .constraints = &.{.{
            .name = "do_not_execute",
            .source_pack = "test_context_pack",
            .reason = "Guidance can suggest checks but cannot execute them.",
        }},
        .risk_surfaces = &.{.{
            .risk_kind = "unsafe_action_surface",
            .source_pack = "test_context_pack",
            .reason = "The suggested action affects external state.",
            .suggested_caution = "Require explicit confirmation.",
        }},
        .candidate_actions = &.{.{
            .id = "candidate_action",
            .source_pack = "test_context_pack",
            .action_type = "generic_action",
            .payload = .null,
            .reason = "Pack guidance can propose a next action.",
            .risk_level = "medium",
        }},
        .check_candidates = &.{.{
            .id = "candidate_check",
            .source_pack = "test_context_pack",
            .check_type = "soft_real_world_check",
            .purpose = "Collect evidence before deciding.",
            .risk_level = "low",
            .confidence = "medium",
            .evidence_strength = "heuristic",
            .why_candidate_exists = "Pack guidance expects evidence before action.",
        }},
        .evidence_expectations = &.{.{
            .expected_signal = "observed_context",
            .source_pack = "test_context_pack",
            .reason = "A later check should produce observable evidence.",
        }},
    }};
    var pack_source = PackGuidanceSource.init(&guidance);
    const sources = [_]ContextSignalSource{pack_source.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.detected_signals.len);
    try std.testing.expectEqualStrings("pack_signal", result.detected_signals[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.suggested_unknowns.len);
    try std.testing.expectEqualStrings("missing_pack_context", result.suggested_unknowns[0].name);
    try std.testing.expectEqual(true, result.suggested_unknowns[0].is_missing_evidence);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
    try std.testing.expectEqual(@as(usize, 1), result.risk_surfaces.len);
    try std.testing.expectEqualStrings("unsafe_action_surface", result.risk_surfaces[0].risk_kind);
    try std.testing.expectEqual(true, result.risk_surfaces[0].non_authorizing);
    try std.testing.expectEqual(@as(usize, 1), result.candidate_actions.len);
    try std.testing.expectEqual(true, result.candidate_actions[0].non_authorizing);
    try std.testing.expectEqual(@as(usize, 1), result.check_candidates.len);
    try std.testing.expectEqual(false, result.check_candidates[0].executes_by_default);
    try std.testing.expectEqual(true, result.check_candidates[0].non_authorizing);
    try std.testing.expectEqual(@as(usize, 1), result.constraints.len);
    try std.testing.expectEqual(@as(usize, 1), result.evidence_expectations.len);
    try std.testing.expectEqual(@as(usize, 1), result.pack_influences.len);
    try std.testing.expectEqualStrings("test_context_pack", result.pack_influences[0].pack_name);
    try std.testing.expectEqual(false, result.pack_influences[0].is_proof_authority);
    try std.testing.expectEqual(true, result.pack_influences[0].non_authorizing);
    try std.testing.expectEqual(true, result.non_authorizing);
}

test "empty pack guidance source records an explicit unknown instead of false absence" {
    var pack_source = PackGuidanceSource.init(&.{});
    const sources = [_]ContextSignalSource{pack_source.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.detected_signals.len);
    try std.testing.expectEqual(@as(usize, 1), result.suggested_unknowns.len);
    try std.testing.expectEqualStrings("empty_pack_autopsy_guidance", result.suggested_unknowns[0].name);
    try std.testing.expectEqual(true, result.suggested_unknowns[0].is_missing_evidence);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
}

test "pack guidance source does not execute commands verifiers or mutate pack state" {
    const guidance = [_]context_autopsy.PackAutopsyGuidance{.{
        .influence = .{
            .pack_name = "readonly_pack",
            .pack_version = "v1",
            .weight = "low",
        },
        .candidate_actions = &.{.{
            .id = "command_like_action",
            .source_pack = "readonly_pack",
            .action_type = "command",
            .payload = .{ .string = "definitely-not-executed" },
            .reason = "Action remains a candidate only.",
            .risk_level = "high",
        }},
        .check_candidates = &.{.{
            .id = "verifier_like_check",
            .source_pack = "readonly_pack",
            .check_type = "hard_verifier",
            .purpose = "Verifier remains a candidate only.",
            .risk_level = "high",
            .confidence = "low",
            .evidence_strength = "absolute",
            .why_candidate_exists = "Guidance can name checks without running them.",
        }},
    }};
    var pack_source = PackGuidanceSource.init(&guidance);
    const sources = [_]ContextSignalSource{pack_source.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), guidance.len);
    try std.testing.expectEqualStrings("readonly_pack", guidance[0].influence.pack_name);
    try std.testing.expectEqual(@as(usize, 1), guidance[0].candidate_actions.len);
    try std.testing.expectEqual(@as(usize, 1), guidance[0].check_candidates.len);
    try std.testing.expectEqual(@as(usize, 1), result.candidate_actions.len);
    try std.testing.expectEqual(true, result.candidate_actions[0].non_authorizing);
    try std.testing.expectEqual(@as(usize, 1), result.check_candidates.len);
    try std.testing.expectEqual(false, result.check_candidates[0].executes_by_default);
}
