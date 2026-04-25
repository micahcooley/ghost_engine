const std = @import("std");
const abstractions = @import("abstractions.zig");
const shards = @import("shards.zig");

pub const SUCCESS_THRESHOLD: u32 = 2;
pub const INDEPENDENT_CASE_THRESHOLD: u32 = 2;
pub const MAX_FAILURE_RATE_PER_MILLE: u32 = 250;

pub const CandidateType = enum {
    intent_interpretation,
    action_surface,
    routing_pattern,
    verifier_pattern,
    abstraction_reuse,
};

pub const ReuseScope = enum {
    shard_local,
    pack_priority_hint,
};

pub const TrustRecommendation = enum {
    local_only,
    exportable_hint,
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    candidate_type: CandidateType,
    concept_id: []u8,
    source_feedback_events: [][]u8,
    success_count: u32,
    failure_count: u32,
    ambiguity_count: u32,
    independent_case_count: u32,
    contradiction_count: u32,
    provenance: [][]u8,
    trust_recommendation: TrustRecommendation,
    reuse_scope: ReuseScope,
    eligible: bool,
    explanation: []u8,
    source_record: abstractions.Record,

    pub fn deinit(self: *Candidate) void {
        self.allocator.free(self.id);
        self.allocator.free(self.concept_id);
        for (self.source_feedback_events) |item| self.allocator.free(item);
        self.allocator.free(self.source_feedback_events);
        for (self.provenance) |item| self.allocator.free(item);
        self.allocator.free(self.provenance);
        self.allocator.free(self.explanation);
        self.source_record.deinit();
        self.* = undefined;
    }
};

pub fn candidateTypeName(value: CandidateType) []const u8 {
    return @tagName(value);
}

pub fn trustRecommendationName(value: TrustRecommendation) []const u8 {
    return @tagName(value);
}

pub fn reuseScopeName(value: ReuseScope) []const u8 {
    return @tagName(value);
}

pub fn listCandidates(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]Candidate {
    const records = try abstractions.loadLiveRecordSnapshot(allocator, paths);
    defer abstractions.deinitRecordSlice(records);

    var out = std.ArrayList(Candidate).init(allocator);
    errdefer {
        for (out.items) |*candidate| candidate.deinit();
        out.deinit();
    }

    for (records) |*record| {
        const kind = candidateTypeForFamily(record.family) orelse continue;
        if (!hasReinforcementSignal(record)) continue;
        try out.append(try candidateFromRecord(allocator, record, kind));
    }
    return try out.toOwnedSlice();
}

pub fn deinitCandidates(candidates: []Candidate) void {
    if (candidates.len == 0) return;
    const allocator = candidates[0].allocator;
    for (candidates) |*candidate| candidate.deinit();
    allocator.free(candidates);
}

pub fn findCandidate(allocator: std.mem.Allocator, paths: *const shards.Paths, id: []const u8) !?Candidate {
    const candidates = try listCandidates(allocator, paths);
    var found: ?usize = null;
    for (candidates, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate.id, id)) found = idx;
    }
    if (found) |match_idx| {
        const slice_allocator = if (candidates.len > 0) candidates[0].allocator else allocator;
        const moved = candidates[match_idx];
        for (candidates, 0..) |*candidate, idx| {
            if (idx != match_idx) candidate.deinit();
        }
        slice_allocator.free(candidates);
        return moved;
    }
    deinitCandidates(candidates);
    return null;
}

pub fn toPackRecord(allocator: std.mem.Allocator, candidate: *const Candidate) !abstractions.Record {
    var record = try candidate.source_record.clone(allocator);
    errdefer record.deinit();
    record.trust_class = .exploratory;
    record.valid_to_commit = false;
    record.promotion_ready = false;
    record.support_score = 0;
    record.reuse_score = @min(record.reuse_score, 120);
    record.quality_score = @min(record.quality_score, 650);
    record.confidence_score = @min(record.confidence_score, 650);
    record.last_review_revision = record.last_revision;
    const extra = try std.fmt.allocPrint(
        allocator,
        "distilled_candidate={s};type={s};scope={s};non_authorizing=true;source_events={d}",
        .{ candidate.id, candidateTypeName(candidate.candidate_type), reuseScopeName(candidate.reuse_scope), candidate.source_feedback_events.len },
    );
    defer allocator.free(extra);
    try appendProvenance(allocator, &record, extra);
    return record;
}

fn candidateFromRecord(allocator: std.mem.Allocator, record: *const abstractions.Record, kind: CandidateType) !Candidate {
    const events = try collectSourceEvents(allocator, record.provenance);
    errdefer {
        for (events) |item| allocator.free(item);
        allocator.free(events);
    }
    const provenance = try cloneStringSlice(allocator, record.provenance);
    errdefer {
        for (provenance) |item| allocator.free(item);
        allocator.free(provenance);
    }
    const eligible = isEligible(record, events.len);
    const explanation = try explainEligibility(allocator, record, events.len, eligible);
    errdefer allocator.free(explanation);
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, record.concept_id),
        .candidate_type = kind,
        .concept_id = try allocator.dupe(u8, record.concept_id),
        .source_feedback_events = events,
        .success_count = record.success_count,
        .failure_count = record.failure_count,
        .ambiguity_count = record.ambiguity_count,
        .independent_case_count = record.independent_case_count,
        .contradiction_count = record.contradiction_count,
        .provenance = provenance,
        .trust_recommendation = if (eligible) .exportable_hint else .local_only,
        .reuse_scope = if (eligible) .pack_priority_hint else .shard_local,
        .eligible = eligible,
        .explanation = explanation,
        .source_record = try record.clone(allocator),
    };
}

fn candidateTypeForFamily(family: abstractions.Family) ?CandidateType {
    return switch (family) {
        .intent_interpretation => .intent_interpretation,
        .action_surface => .action_surface,
        .verifier_pattern => .verifier_pattern,
        .route_suppressor => .routing_pattern,
        .grounding_schema, .claim_template, .parser_sketch, .distilled => .abstraction_reuse,
    };
}

fn hasReinforcementSignal(record: *const abstractions.Record) bool {
    return record.success_count + record.failure_count + record.ambiguity_count + record.contradiction_count > 0;
}

fn isEligible(record: *const abstractions.Record, event_count: usize) bool {
    const total = record.success_count + record.failure_count + record.ambiguity_count + record.contradiction_count;
    if (record.success_count < SUCCESS_THRESHOLD) return false;
    if (record.independent_case_count < INDEPENDENT_CASE_THRESHOLD) return false;
    if (record.contradiction_count != 0) return false;
    if (record.ambiguity_count != 0) return false;
    if (total == 0) return false;
    if (record.failure_count * 1000 >= total * MAX_FAILURE_RATE_PER_MILLE) return false;
    if (event_count < INDEPENDENT_CASE_THRESHOLD) return false;
    if (record.provenance.len == 0 or record.lineage_id.len == 0) return false;
    return true;
}

fn explainEligibility(allocator: std.mem.Allocator, record: *const abstractions.Record, event_count: usize, eligible: bool) ![]u8 {
    if (eligible) {
        return std.fmt.allocPrint(
            allocator,
            "eligible: successes={d}, independent_cases={d}, contradictions=0, failure_rate_below_threshold=true, provenance_complete=true",
            .{ record.success_count, record.independent_case_count },
        );
    }
    var reasons = std.ArrayList(u8).init(allocator);
    errdefer reasons.deinit();
    const writer = reasons.writer();
    try writer.writeAll("ineligible:");
    if (record.success_count < SUCCESS_THRESHOLD) try writer.print(" success_threshold {d}/{d};", .{ record.success_count, SUCCESS_THRESHOLD });
    if (record.independent_case_count < INDEPENDENT_CASE_THRESHOLD) try writer.print(" independent_case_threshold {d}/{d};", .{ record.independent_case_count, INDEPENDENT_CASE_THRESHOLD });
    if (record.contradiction_count != 0) try writer.print(" contradiction_count {d};", .{record.contradiction_count});
    if (record.ambiguity_count != 0) try writer.print(" unresolved_or_ambiguous_count {d};", .{record.ambiguity_count});
    const total = record.success_count + record.failure_count + record.ambiguity_count + record.contradiction_count;
    if (total == 0 or record.failure_count * 1000 >= total * MAX_FAILURE_RATE_PER_MILLE) try writer.print(" failure_rate {d}/{d};", .{ record.failure_count, total });
    if (event_count < INDEPENDENT_CASE_THRESHOLD) try writer.print(" source_feedback_events {d}/{d};", .{ event_count, INDEPENDENT_CASE_THRESHOLD });
    if (record.provenance.len == 0 or record.lineage_id.len == 0) try writer.writeAll(" provenance_incomplete;");
    return try reasons.toOwnedSlice();
}

fn collectSourceEvents(allocator: std.mem.Allocator, provenance: []const []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (provenance) |entry| {
        const start = std.mem.indexOf(u8, entry, "case=") orelse continue;
        const rest = entry[start + "case=".len ..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        if (end == 0) continue;
        try appendUniqueOwned(allocator, &out, rest[0..end]);
    }
    return try out.toOwnedSlice();
}

fn appendUniqueOwned(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), value: []const u8) !void {
    for (out.items) |item| {
        if (std.mem.eql(u8, item, value)) return;
    }
    try out.append(try allocator.dupe(u8, value));
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |item| allocator.free(item);
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn appendProvenance(allocator: std.mem.Allocator, record: *abstractions.Record, value: []const u8) !void {
    const next = try allocator.alloc([]u8, record.provenance.len + 1);
    errdefer allocator.free(next);
    for (record.provenance, 0..) |item, idx| next[idx] = item;
    next[record.provenance.len] = try allocator.dupe(u8, value);
    if (record.provenance.len > 0) allocator.free(record.provenance);
    record.provenance = next;
}

const feedback = @import("feedback.zig");

test "stable repeated verifier success becomes eligible distillation candidate" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "distill-eligible-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    try recordVerifierSuccesses(allocator, &paths, "candidate:local_guard", 2);
    const candidates = try listCandidates(allocator, &paths);
    defer deinitCandidates(candidates);
    const candidate = findById(candidates, "action_surface:candidate_local_guard") orelse return error.TestExpectedCandidate;
    try std.testing.expect(candidate.eligible);
    try std.testing.expectEqual(@as(u32, 2), candidate.success_count);
    try std.testing.expectEqual(@as(u32, 2), candidate.independent_case_count);
}

test "single verifier success remains ineligible distillation candidate" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "distill-single-ineligible-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    try recordVerifierSuccesses(allocator, &paths, "candidate:local_guard", 1);
    const candidates = try listCandidates(allocator, &paths);
    defer deinitCandidates(candidates);
    const candidate = findById(candidates, "action_surface:candidate_local_guard") orelse return error.TestExpectedCandidate;
    try std.testing.expect(!candidate.eligible);
}

test "contradiction blocks distillation eligibility" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "distill-contradiction-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    try recordVerifierSuccesses(allocator, &paths, "candidate:local_guard", 2);
    const event = abstractions.ReinforcementEvent{
        .family = .action_surface,
        .key = "candidate:local_guard",
        .case_id = "verifier:contradicted:case-c",
        .category = .control_flow,
        .outcome = .contradicted,
        .source_specs = &.{"deep_path:c"},
        .patterns = &.{"feedback:contradicted"},
        .detail = "test",
    };
    _ = try abstractions.applyReinforcementEvents(allocator, &paths, &.{event}, .{ .max_events = 1, .max_new_records = 1 });
    const candidates = try listCandidates(allocator, &paths);
    defer deinitCandidates(candidates);
    const candidate = findById(candidates, "action_surface:candidate_local_guard") orelse return error.TestExpectedCandidate;
    try std.testing.expect(!candidate.eligible);
    try std.testing.expectEqual(@as(u32, 1), candidate.contradiction_count);
}

test "unresolved reinforcement never becomes eligible" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "distill-unresolved-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    const events = [_]abstractions.ReinforcementEvent{
        .{ .family = .verifier_pattern, .key = "unresolved", .case_id = "case-a", .category = .invariant, .outcome = .ambiguous, .source_specs = &.{"deep_path:a"}, .patterns = &.{"outcome:unresolved"}, .detail = "test" },
        .{ .family = .verifier_pattern, .key = "unresolved", .case_id = "case-b", .category = .invariant, .outcome = .ambiguous, .source_specs = &.{"deep_path:b"}, .patterns = &.{"outcome:unresolved"}, .detail = "test" },
    };
    _ = try abstractions.applyReinforcementEvents(allocator, &paths, &events, .{ .max_events = events.len, .max_new_records = events.len });
    const candidates = try listCandidates(allocator, &paths);
    defer deinitCandidates(candidates);
    const candidate = findById(candidates, "verifier_pattern:unresolved") orelse return error.TestExpectedCandidate;
    try std.testing.expect(!candidate.eligible);
}

fn recordVerifierSuccesses(allocator: std.mem.Allocator, paths: *const shards.Paths, candidate: []const u8, count: usize) !void {
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        var id_buf: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "verifier:success:case-{d}", .{idx});
        var artifact_buf: [64]u8 = undefined;
        const artifact = try std.fmt.bufPrint(&artifact_buf, "deep_path:{d}", .{idx});
        _ = try feedback.recordAndApply(allocator, paths, .{
            .id = id,
            .source = .verifier,
            .type = .success,
            .related_artifact = artifact,
            .related_intent = "refactor",
            .related_candidate = candidate,
            .outcome = "supported",
            .timestamp = "deterministic:test",
            .provenance = "test",
        });
    }
}

fn findById(candidates: []const Candidate, id: []const u8) ?*const Candidate {
    for (candidates) |*candidate| {
        if (std.mem.eql(u8, candidate.id, id)) return candidate;
    }
    return null;
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
