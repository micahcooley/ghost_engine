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
const execution = @import("execution.zig");
const abstractions = @import("abstractions.zig");
const patch_candidates = @import("patch_candidates.zig");
const task_intent = @import("task_intent.zig");

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
        .rel_paths = &.{ "src/api/service.zig" },
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
        .rel_paths = &.{ "src/api/service.zig" },
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
        .rel_paths = &.{ "src/api/service.zig" },
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
            .rel_paths = &.{ "src/api/service.zig" },
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
        .rel_paths = &.{ "src/api/service.zig" },
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
    try std.testing.expect(first.items.len > 40);
    try std.testing.expectEqualSlices(u8, panic_dump.MAGIC, first.items[0..panic_dump.MAGIC.len]);
    try std.testing.expectEqual(@as(u16, panic_dump.FORMAT_VERSION), std.mem.readInt(u16, first.items[8..10], .little));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, first.items[24..28], .little));
    try std.testing.expectEqual(@as(u32, 777), std.mem.readInt(u32, first.items[28..32], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, first.items[32..34], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, first.items[36..38], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, first.items[40..42], .little));
}

fn writeFixtureFile(dir: std.fs.Dir, sub_path: []const u8, contents: []const u8) !void {
    const parent = std.fs.path.dirname(sub_path) orelse ".";
    try dir.makePath(parent);
    try dir.writeFile(.{
        .sub_path = sub_path,
        .data = contents,
    });
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
        \\if [ "${{1:-}}" = "build" ] && [ "${{2:-}}" = "test" ] && grep -R -q "scaffold #1" "$PWD/src"; then
        \\  echo "simulated test failure for candidate_1" >&2
        \\  exit 1
        \\fi
        \\if [ "${{1:-}}" = "build" ] && [ -z "${{2:-}}" ] && grep -R -q "scaffold #2" "$PWD/src"; then
        \\  if [ ! -f "{s}" ]; then
        \\    printf '1\n' > "{s}"
        \\    echo "simulated one-time build failure for candidate_2" >&2
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
        \\  count=$(grep -R -h "GHOST-PATCH-CANDIDATE" "$PWD/src" | wc -l | tr -d ' ')
        \\  if [ "$count" -gt 1 ]; then
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
        .argv = &.{ "./scripts/hang.sh" },
        .timeout_ms = 100,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(execution.FailureSignal.timed_out, result.failure_signal);
}

test "patch candidate generation is bounded and traceable" {
    const allocator = std.testing.allocator;
    var fixture = try makeCodeIntelFixture(allocator);
    defer fixture.tmp.cleanup();
    defer allocator.free(fixture.root_path);

    var result = try patch_candidates.run(allocator, .{
        .repo_root = fixture.root_path,
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
    try std.testing.expect(std.mem.indexOf(u8, result.candidates[0].hunks[0].diff, "GHOST-PATCH-CANDIDATE") != null);
    try std.testing.expect(result.candidates[0].trace.len >= 2);
    try std.testing.expectEqual(code_intel.Status.supported, result.support_graph.permission);
    try std.testing.expect(result.support_graph.minimum_met);
    var verified_count: usize = 0;
    var novel_count: usize = 0;
    for (result.candidates) |candidate| {
        try std.testing.expect(candidate.status_reason != null);
        if (candidate.validation_state == .verified_supported) {
            verified_count += 1;
            try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.build.state);
            try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, candidate.verification.test_step.state);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"execution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"failureSignal\":\"none\"") != null);
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
        if (candidate.validation_state == .verified_supported) winner_idx = idx;
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

test "patch candidate verification rejects failures and records retries" {
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
    try std.testing.expectEqual(patch_candidates.ValidationState.test_failed, result.candidates[0].validation_state);
    try std.testing.expectEqual(patch_candidates.CandidateStatus.rejected, result.candidates[0].status);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.failed, result.candidates[0].verification.test_step.state);
    try std.testing.expectEqual(patch_candidates.ValidationState.verified_supported, result.candidates[1].validation_state);
    try std.testing.expectEqual(patch_candidates.CandidateStatus.supported, result.candidates[1].status);
    try std.testing.expectEqual(@as(u32, 1), result.candidates[1].verification.retry_count);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, result.candidates[1].verification.build.state);
    try std.testing.expectEqual(patch_candidates.VerificationStepState.passed, result.candidates[1].verification.test_step.state);
    try std.testing.expectEqual(@as(u32, 2), result.handoff.proof.queued_candidate_count);
}

test "patch candidate verification records bounded refinement hypotheses for retries" {
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

    var saw_refinement = false;
    for (result.candidates) |candidate| {
        if (!candidate.entered_proof_mode) continue;
        if (candidate.verification.refinements.len == 0) continue;
        saw_refinement = true;
        try std.testing.expect(candidate.verification.refinements[0].retained_hunk_count >= 1);
    }

    try std.testing.expect(saw_refinement);
    const rendered = try patch_candidates.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"refinements\":[") != null);
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

    try std.testing.expectEqual(code_intel.Status.unresolved, result.status);
    try std.testing.expectEqual(mc.StopReason.low_confidence, result.stop_reason);
    try std.testing.expectEqualStrings(patch_candidates.MINIMALITY_MODEL_NAME, result.minimality_model.?);
    try std.testing.expectEqual(patch_candidates.RefactorPlanStatus.unresolved, result.refactor_plan_status);
    try std.testing.expect(result.selected_refactor_scope == null);
    try std.testing.expect(result.unresolved_detail != null);
    try std.testing.expectEqual(patch_candidates.ValidationState.build_failed, result.candidates[0].validation_state);
    try std.testing.expectEqual(patch_candidates.ValidationState.build_failed, result.candidates[1].validation_state);
    try std.testing.expectEqual(patch_candidates.CandidateStatus.rejected, result.candidates[0].status);
    try std.testing.expectEqual(patch_candidates.CandidateStatus.rejected, result.candidates[1].status);
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
    try std.testing.expect(novel_count > 0);
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
    try std.testing.expect(
        std.mem.indexOf(u8, result.unresolved_detail.?, "ground") != null or
            std.mem.indexOf(u8, result.unresolved_detail.?, "symbolic") != null,
    );
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
    try std.testing.expect(
        std.mem.indexOf(u8, result.unresolved_detail.?, "mapping") != null or
            std.mem.indexOf(u8, result.unresolved_detail.?, "grounding") != null or
            std.mem.indexOf(u8, result.unresolved_detail.?, "ambiguous") != null,
    );
    try std.testing.expect(result.grounding_traces.len >= 2);
    const rendered = try code_intel.renderJson(allocator, &result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ambiguous\":true") != null);
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
