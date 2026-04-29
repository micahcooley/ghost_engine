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

    pub fn init(allocator: std.mem.Allocator) ResultBuilder {
        return .{
            .allocator = allocator,
            .signals = std.ArrayList(context_autopsy.ContextSignal).init(allocator),
            .unknowns = std.ArrayList(context_autopsy.ContextUnknown).init(allocator),
            .risks = std.ArrayList(context_autopsy.ContextRiskSurface).init(allocator),
            .candidates = std.ArrayList(context_autopsy.ContextCandidateAction).init(allocator),
            .checks = std.ArrayList(context_autopsy.ContextCheckCandidate).init(allocator),
        };
    }

    pub fn deinit(self: *ResultBuilder) void {
        self.signals.deinit();
        self.unknowns.deinit();
        self.risks.deinit();
        self.candidates.deinit();
        self.checks.deinit();
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

    pub fn build(self: *ResultBuilder, case: ContextCase) !ContextAutopsyResult {
        return ContextAutopsyResult{
            .context_case = case,
            .detected_signals = try self.signals.toOwnedSlice(),
            .suggested_unknowns = try self.unknowns.toOwnedSlice(),
            .risk_surfaces = try self.risks.toOwnedSlice(),
            .candidate_actions = try self.candidates.toOwnedSlice(),
            .check_candidates = try self.checks.toOwnedSlice(),
        };
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
    const result = try engine.evaluate(&case);
    defer {
        std.testing.allocator.free(result.detected_signals);
        std.testing.allocator.free(result.suggested_unknowns);
        std.testing.allocator.free(result.risk_surfaces);
        std.testing.allocator.free(result.candidate_actions);
        std.testing.allocator.free(result.check_candidates);
    }

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
    const result = try engine.evaluate(&case);
    defer {
        std.testing.allocator.free(result.detected_signals);
        std.testing.allocator.free(result.suggested_unknowns);
        std.testing.allocator.free(result.risk_surfaces);
        std.testing.allocator.free(result.candidate_actions);
        std.testing.allocator.free(result.check_candidates);
    }

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
    const result = try engine.evaluate(&case);
    defer {
        std.testing.allocator.free(result.detected_signals);
        std.testing.allocator.free(result.suggested_unknowns);
        std.testing.allocator.free(result.risk_surfaces);
        std.testing.allocator.free(result.candidate_actions);
        std.testing.allocator.free(result.check_candidates);
    }

    try std.testing.expectEqual(@as(usize, 1), result.detected_signals.len);
    try std.testing.expectEqualStrings("mock_signal", result.detected_signals[0].name);
    try std.testing.expectEqual(true, result.non_authorizing);
}
