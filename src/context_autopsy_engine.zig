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
    pending_evidence_obligations: std.ArrayList(context_autopsy.PendingEvidenceObligation),
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
            .pending_evidence_obligations = std.ArrayList(context_autopsy.PendingEvidenceObligation).init(allocator),
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
        self.pending_evidence_obligations.deinit();
        self.pack_influences.deinit();
    }

    pub fn addUnknown(self: *ResultBuilder, unknown: context_autopsy.ContextUnknown) !void {
        var sanitized = unknown;
        sanitized.is_missing_evidence = true;
        sanitized.is_negative_evidence = false;
        try self.unknowns.append(sanitized);
    }

    pub fn addSignal(self: *ResultBuilder, signal: context_autopsy.ContextSignal) !void {
        try self.signals.append(signal);
    }

    pub fn addRisk(self: *ResultBuilder, risk: context_autopsy.ContextRiskSurface) !void {
        var sanitized = risk;
        sanitized.non_authorizing = true;
        try self.risks.append(sanitized);
    }

    pub fn addCandidate(self: *ResultBuilder, candidate: context_autopsy.ContextCandidateAction) !void {
        var sanitized = candidate;
        sanitized.non_authorizing = true;
        try self.candidates.append(sanitized);
    }

    pub fn addCheck(self: *ResultBuilder, check: context_autopsy.ContextCheckCandidate) !void {
        var sanitized = check;
        sanitized.non_authorizing = true;
        sanitized.executes_by_default = false;
        try self.checks.append(sanitized);
    }

    pub fn addConstraint(self: *ResultBuilder, constraint: context_autopsy.ContextConstraint) !void {
        try self.constraints.append(constraint);
    }

    pub fn addEvidenceExpectation(self: *ResultBuilder, expectation: context_autopsy.EvidenceExpectation) !void {
        try self.evidence_expectations.append(expectation);
        try self.addPendingEvidenceObligation(expectationToPendingObligation(expectation));
    }

    pub fn addPendingEvidenceObligation(self: *ResultBuilder, obligation: context_autopsy.PendingEvidenceObligation) !void {
        var sanitized = obligation;
        sanitized.status = "pending";
        sanitized.executed = false;
        sanitized.treated_as_proof = false;
        sanitized.non_authorizing = true;
        try self.pending_evidence_obligations.append(sanitized);
    }

    pub fn addPackInfluence(self: *ResultBuilder, influence: context_autopsy.PackInfluence) !void {
        var sanitized = influence;
        sanitized.non_authorizing = true;
        sanitized.is_proof_authority = false;
        try self.pack_influences.append(sanitized);
    }

    pub fn build(self: *ResultBuilder, case: ContextCase) !ContextAutopsyResult {
        // Enforce authority boundaries at the last possible moment,
        // preventing sources from bypassing builder methods.
        for (self.unknowns.items) |*unknown| {
            unknown.is_missing_evidence = true;
            unknown.is_negative_evidence = false;
        }
        for (self.risks.items) |*risk| risk.non_authorizing = true;
        for (self.candidates.items) |*candidate| candidate.non_authorizing = true;
        for (self.checks.items) |*check| {
            check.non_authorizing = true;
            check.executes_by_default = false;
        }
        for (self.pending_evidence_obligations.items) |*obl| {
            obl.status = "pending";
            obl.executed = false;
            obl.treated_as_proof = false;
            obl.non_authorizing = true;
        }
        for (self.pack_influences.items) |*influence| {
            influence.non_authorizing = true;
            influence.is_proof_authority = false;
        }

        return ContextAutopsyResult{
            .context_case = case,
            .detected_signals = try self.signals.toOwnedSlice(),
            .suggested_unknowns = try self.unknowns.toOwnedSlice(),
            .risk_surfaces = try self.risks.toOwnedSlice(),
            .candidate_actions = try self.candidates.toOwnedSlice(),
            .check_candidates = try self.checks.toOwnedSlice(),
            .constraints = try self.constraints.toOwnedSlice(),
            .evidence_expectations = try self.evidence_expectations.toOwnedSlice(),
            .pending_evidence_obligations = try self.pending_evidence_obligations.toOwnedSlice(),
            .pack_influences = try self.pack_influences.toOwnedSlice(),
        };
    }
};

fn expectationToPendingObligation(expectation: context_autopsy.EvidenceExpectation) context_autopsy.PendingEvidenceObligation {
    const id = if (expectation.id.len != 0) expectation.id else expectation.expected_signal;
    const summary = if (expectation.summary.len != 0) expectation.summary else expectation.reason;
    const obligation_kind = if (isHardExpectation(expectation.expectation_kind)) "hard_verifier" else "soft_check";
    return .{
        .id = if (id.len != 0) id else "unnamed_evidence_expectation",
        .source_pack = expectation.source_pack,
        .summary = summary,
        .expectation_kind = expectation.expectation_kind,
        .obligation_kind = obligation_kind,
        .reason = expectation.reason,
    };
}

fn isHardExpectation(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "hard") or
        std.mem.eql(u8, kind, "hard_verifier") or
        std.mem.eql(u8, kind, "verifier");
}

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

    fn contribute(ptr: *anyopaque, case: *const ContextCase, builder: *ResultBuilder) anyerror!void {
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

        var applied_count: usize = 0;
        for (self.guidance) |guidance| {
            if (!guidanceApplies(case, guidance.match)) continue;
            applied_count += 1;

            try builder.addPackInfluence(guidance.influence);

            for (guidance.signals) |signal| try builder.addSignal(signal);
            for (guidance.suggested_unknowns) |unknown| try builder.addUnknown(unknown);
            for (guidance.constraints) |constraint| try builder.addConstraint(constraint);
            for (guidance.risk_surfaces) |risk| try builder.addRisk(risk);
            for (guidance.candidate_actions) |candidate| try builder.addCandidate(candidate);
            for (guidance.check_candidates) |check| try builder.addCheck(check);
            for (guidance.evidence_expectations) |expectation| try builder.addEvidenceExpectation(expectation);
        }

        if (applied_count == 0) {
            try builder.addUnknown(.{
                .name = "no_applicable_pack_guidance",
                .source_pack = "pack_guidance_source",
                .importance = "medium",
                .reason = "Pack guidance entries were present, but none matched this ContextCase. Applicability remains unknown, not false.",
            });
        }
    }
};

fn guidanceApplies(case: *const ContextCase, match: context_autopsy.PackAutopsyMatch) bool {
    if (!matchesAny(case.intent_tags, match.intent_tags_any)) return false;
    if (!matchesAll(case.intent_tags, match.intent_tags_all)) return false;
    if (!matchesAny(case.artifact_kinds, match.artifact_kinds_any)) return false;
    if (!matchesAll(case.artifact_kinds, match.artifact_kinds_all)) return false;
    if (!matchesAny(case.situation_kinds, match.situation_kinds_any)) return false;
    if (!matchesAll(case.situation_kinds, match.situation_kinds_all)) return false;
    if (!matchesAnyContextKeyword(case, match.context_keywords_any)) return false;
    if (!matchesAllContextKeywords(case, match.context_keywords_all)) return false;
    if (!hasRequiredContextFields(case, match.required_context_fields)) return false;
    return true;
}

fn matchesAny(case_values: []const []const u8, criteria: []const []const u8) bool {
    if (criteria.len == 0) return true;
    for (criteria) |criterion| {
        if (containsText(case_values, criterion)) return true;
    }
    return false;
}

fn matchesAll(case_values: []const []const u8, criteria: []const []const u8) bool {
    for (criteria) |criterion| {
        if (!containsText(case_values, criterion)) return false;
    }
    return true;
}

fn containsText(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, wanted)) return true;
    }
    return false;
}

fn matchesAnyContextKeyword(case: *const ContextCase, keywords: []const []const u8) bool {
    if (keywords.len == 0) return true;
    for (keywords) |keyword| {
        if (contextContains(case, keyword)) return true;
    }
    return false;
}

fn matchesAllContextKeywords(case: *const ContextCase, keywords: []const []const u8) bool {
    for (keywords) |keyword| {
        if (!contextContains(case, keyword)) return false;
    }
    return true;
}

fn contextContains(case: *const ContextCase, keyword: []const u8) bool {
    if (std.mem.indexOf(u8, case.description, keyword) != null) return true;
    if (std.mem.indexOf(u8, case.intake_type, keyword) != null) return true;
    return jsonStringValueContains(case.intake_data, keyword);
}

fn jsonStringValueContains(value: std.json.Value, keyword: []const u8) bool {
    return switch (value) {
        .string => |s| std.mem.indexOf(u8, s, keyword) != null,
        .array => |arr| {
            for (arr.items) |item| {
                if (jsonStringValueContains(item, keyword)) return true;
            }
            return false;
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.indexOf(u8, entry.key_ptr.*, keyword) != null) return true;
                if (jsonStringValueContains(entry.value_ptr.*, keyword)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn hasRequiredContextFields(case: *const ContextCase, fields: []const []const u8) bool {
    for (fields) |field| {
        if (std.mem.eql(u8, field, "description") or std.mem.eql(u8, field, "summary")) {
            if (case.description.len == 0) return false;
            continue;
        }
        if (std.mem.eql(u8, field, "intake_type") or std.mem.eql(u8, field, "intakeType")) {
            if (case.intake_type.len == 0) return false;
            continue;
        }
        if (!jsonObjectHasField(case.intake_data, field)) return false;
    }
    return true;
}

fn jsonObjectHasField(value: std.json.Value, field: []const u8) bool {
    if (value != .object) return false;
    return value.object.get(field) != null;
}

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
    try std.testing.expectEqual(@as(usize, 1), result.pending_evidence_obligations.len);
    try std.testing.expectEqualStrings("pending", result.pending_evidence_obligations[0].status);
    try std.testing.expectEqual(false, result.pending_evidence_obligations[0].executed);
    try std.testing.expectEqual(false, result.pending_evidence_obligations[0].treated_as_proof);
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

test "pack guidance source applies only matching case-aware guidance" {
    const guidance = [_]context_autopsy.PackAutopsyGuidance{
        .{
            .influence = .{ .pack_name = "matching_pack", .weight = "high" },
            .match = .{ .intent_tags_any = &.{"planning"}, .situation_kinds_all = &.{"launch"} },
            .signals = &.{.{
                .name = "matched_signal",
                .source_pack = "matching_pack",
                .kind = "generic_signal",
                .confidence = "medium",
                .reason = "case matched",
            }},
        },
        .{
            .influence = .{ .pack_name = "nonmatching_pack", .weight = "high" },
            .match = .{ .intent_tags_any = &.{"debugging"} },
            .signals = &.{.{
                .name = "nonmatching_signal",
                .source_pack = "nonmatching_pack",
                .kind = "generic_signal",
                .confidence = "medium",
                .reason = "case should not match",
            }},
        },
    };
    var pack_source = PackGuidanceSource.init(&guidance);
    const sources = [_]ContextSignalSource{pack_source.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "generic launch planning",
        .intake_data = .null,
        .intake_type = "test",
        .intent_tags = &.{"planning"},
        .situation_kinds = &.{"launch"},
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.detected_signals.len);
    try std.testing.expectEqualStrings("matched_signal", result.detected_signals[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.pack_influences.len);
    try std.testing.expectEqualStrings("matching_pack", result.pack_influences[0].pack_name);
}

test "nonmatching pack guidance produces explicit unknown gap" {
    const guidance = [_]context_autopsy.PackAutopsyGuidance{.{
        .influence = .{ .pack_name = "nonmatching_pack", .weight = "high" },
        .match = .{ .intent_tags_any = &.{"debugging"} },
        .signals = &.{.{
            .name = "should_not_emit",
            .source_pack = "nonmatching_pack",
            .kind = "generic_signal",
            .confidence = "medium",
            .reason = "case should not match",
        }},
    }};
    var pack_source = PackGuidanceSource.init(&guidance);
    const sources = [_]ContextSignalSource{pack_source.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "generic launch planning",
        .intake_data = .null,
        .intake_type = "test",
        .intent_tags = &.{"planning"},
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.detected_signals.len);
    try std.testing.expectEqual(@as(usize, 1), result.suggested_unknowns.len);
    try std.testing.expectEqualStrings("no_applicable_pack_guidance", result.suggested_unknowns[0].name);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
}

const MaliciousSource = struct {
    pub fn contribute(_: *anyopaque, _: *const ContextCase, builder: *ResultBuilder) anyerror!void {
        try builder.addUnknown(.{
            .name = "malicious_unknown",
            .source_pack = "malicious_pack",
            .importance = "high",
            .reason = "tries to make missing evidence negative",
            .is_missing_evidence = false,
            .is_negative_evidence = true,
        });
        try builder.addRisk(.{
            .risk_kind = "malicious_risk",
            .source_pack = "malicious_pack",
            .reason = "tries to authorize risk",
            .suggested_caution = "none",
            .non_authorizing = false,
        });
        try builder.addCandidate(.{
            .id = "malicious_action",
            .source_pack = "malicious_pack",
            .action_type = "generic_action",
            .payload = .null,
            .reason = "tries to authorize action",
            .risk_level = "high",
            .non_authorizing = false,
        });
        try builder.addCheck(.{
            .id = "malicious_check",
            .source_pack = "malicious_pack",
            .check_type = "hard_verifier",
            .purpose = "tries to execute by default",
            .risk_level = "high",
            .confidence = "high",
            .evidence_strength = "absolute",
            .non_authorizing = false,
            .executes_by_default = true,
            .why_candidate_exists = "malicious input",
        });
        try builder.addPackInfluence(.{
            .pack_name = "malicious_pack",
            .weight = "high",
            .non_authorizing = false,
            .is_proof_authority = true,
        });
    }

    pub fn source() ContextSignalSource {
        return .{ .ptr = undefined, .contributeFn = contribute };
    }
};

test "result builder sanitizes malicious source authority flags" {
    const sources = [_]ContextSignalSource{MaliciousSource.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "test case",
        .intake_data = .null,
        .intake_type = "test",
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, result.suggested_unknowns[0].is_missing_evidence);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
    try std.testing.expectEqual(true, result.risk_surfaces[0].non_authorizing);
    try std.testing.expectEqual(true, result.candidate_actions[0].non_authorizing);
    try std.testing.expectEqual(true, result.check_candidates[0].non_authorizing);
    try std.testing.expectEqual(false, result.check_candidates[0].executes_by_default);
    try std.testing.expectEqual(true, result.pack_influences[0].non_authorizing);
    try std.testing.expectEqual(false, result.pack_influences[0].is_proof_authority);
}

test "result builder sanitizes direct field mutations before build" {
    var builder = ResultBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.unknowns.append(.{
        .name = "direct_unknown",
        .source_pack = "direct_test",
        .importance = "high",
        .reason = "direct append tries to make missing evidence negative",
        .is_missing_evidence = false,
        .is_negative_evidence = true,
    });
    try builder.candidates.append(.{
        .id = "direct_candidate",
        .source_pack = "direct_test",
        .action_type = "command",
        .payload = .null,
        .reason = "direct append tries to authorize an action",
        .risk_level = "high",
        .requires_user_confirmation = false,
        .non_authorizing = false,
    });

    var result = try builder.build(.{
        .description = "test",
        .intake_data = .null,
        .intake_type = "test",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, result.suggested_unknowns[0].is_missing_evidence);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
    try std.testing.expectEqual(true, result.candidate_actions[0].non_authorizing);
}

const DirectAppendMaliciousSource = struct {
    pub fn contribute(_: *anyopaque, _: *const ContextCase, builder: *ResultBuilder) anyerror!void {
        try builder.unknowns.append(.{
            .name = "direct_source_unknown",
            .source_pack = "direct_source_pack",
            .importance = "high",
            .reason = "direct source append tries to make missing evidence negative",
            .is_missing_evidence = false,
            .is_negative_evidence = true,
        });
        try builder.checks.append(.{
            .id = "direct_source_check",
            .source_pack = "direct_source_pack",
            .check_type = "hard_verifier",
            .purpose = "direct source append tries to execute",
            .risk_level = "high",
            .confidence = "high",
            .evidence_strength = "absolute",
            .requires_user_confirmation = false,
            .non_authorizing = false,
            .executes_by_default = true,
            .why_candidate_exists = "unsafe direct append",
        });
        try builder.candidates.append(.{
            .id = "direct_source_action",
            .source_pack = "direct_source_pack",
            .action_type = "command",
            .payload = .{ .string = "not-executed" },
            .reason = "direct source append tries to authorize an action",
            .risk_level = "high",
            .requires_user_confirmation = false,
            .non_authorizing = false,
        });
        try builder.pending_evidence_obligations.append(.{
            .id = "direct_source_obligation",
            .source_pack = "direct_source_pack",
            .summary = "direct source append tries to mark evidence complete",
            .expectation_kind = "hard_verifier",
            .obligation_kind = "hard_verifier",
            .status = "complete",
            .executed = true,
            .treated_as_proof = true,
            .non_authorizing = false,
            .reason = "unsafe direct append",
        });
        try builder.pack_influences.append(.{
            .pack_name = "direct_source_pack",
            .pack_version = "v1",
            .weight = "high",
            .non_authorizing = false,
            .is_proof_authority = true,
        });
    }

    pub fn source() ContextSignalSource {
        return .{ .ptr = undefined, .contributeFn = contribute };
    }
};

test "result builder finalization sanitizes unsafe direct source appends" {
    const sources = [_]ContextSignalSource{DirectAppendMaliciousSource.source()};
    var engine = ContextAutopsyEngine.init(std.testing.allocator, &sources);
    const case = ContextCase{
        .description = "direct source finalization test",
        .intake_data = .null,
        .intake_type = "test",
    };

    var result = try engine.evaluate(&case);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("draft", result.state);
    try std.testing.expectEqual(true, result.non_authorizing);
    try std.testing.expectEqual(true, result.suggested_unknowns[0].is_missing_evidence);
    try std.testing.expectEqual(false, result.suggested_unknowns[0].is_negative_evidence);
    try std.testing.expectEqual(true, result.candidate_actions[0].non_authorizing);
    try std.testing.expectEqual(true, result.check_candidates[0].non_authorizing);
    try std.testing.expectEqual(false, result.check_candidates[0].executes_by_default);
    try std.testing.expectEqualStrings("pending", result.pending_evidence_obligations[0].status);
    try std.testing.expectEqual(false, result.pending_evidence_obligations[0].executed);
    try std.testing.expectEqual(false, result.pending_evidence_obligations[0].treated_as_proof);
    try std.testing.expectEqual(true, result.pending_evidence_obligations[0].non_authorizing);
    try std.testing.expectEqual(true, result.pack_influences[0].non_authorizing);
    try std.testing.expectEqual(false, result.pack_influences[0].is_proof_authority);
}

test "evidence expectations become pending unmet non-proof obligations" {
    const guidance = [_]context_autopsy.PackAutopsyGuidance{.{
        .influence = .{ .pack_name = "expectation_pack", .weight = "medium" },
        .evidence_expectations = &.{.{
            .id = "hard_signal",
            .summary = "Need deterministic evidence before claiming success.",
            .expectation_kind = "hard_verifier",
            .expected_signal = "hard_signal",
            .source_pack = "expectation_pack",
            .reason = "Expect evidence only, do not execute it.",
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

    try std.testing.expectEqual(@as(usize, 1), result.evidence_expectations.len);
    try std.testing.expectEqual(@as(usize, 1), result.pending_evidence_obligations.len);
    try std.testing.expectEqualStrings("hard_verifier", result.pending_evidence_obligations[0].obligation_kind);
    try std.testing.expectEqualStrings("pending", result.pending_evidence_obligations[0].status);
    try std.testing.expectEqual(false, result.pending_evidence_obligations[0].executed);
    try std.testing.expectEqual(false, result.pending_evidence_obligations[0].treated_as_proof);
    try std.testing.expectEqual(true, result.pending_evidence_obligations[0].non_authorizing);
}
