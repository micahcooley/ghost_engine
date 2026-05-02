const std = @import("std");
const shards = @import("shards.zig");

pub const SCHEMA_VERSION = "reviewed_correction_record.v1";
pub const REVIEWED_CORRECTIONS_REL_DIR = "corrections";
pub const REVIEWED_CORRECTIONS_FILE_NAME = "reviewed_corrections.jsonl";

pub const Decision = enum {
    accepted,
    rejected,

    pub fn parse(text: []const u8) ?Decision {
        if (std.mem.eql(u8, text, "accepted")) return .accepted;
        if (std.mem.eql(u8, text, "rejected")) return .rejected;
        return null;
    }
};

pub const Request = struct {
    project_shard: []const u8,
    decision: Decision,
    reviewer_note: []const u8,
    rejected_reason: ?[]const u8,
    source_candidate_id: []const u8,
    correction_candidate_json: []const u8,
    accepted_learning_outputs_json: []const u8,
};

pub const ReviewResult = struct {
    allocator: std.mem.Allocator,
    record_json: []u8,
    storage_path: []u8,

    pub fn deinit(self: *ReviewResult) void {
        self.allocator.free(self.record_json);
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }
};

pub fn reviewedCorrectionsPath(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return std.fs.path.join(allocator, &.{ paths.root_abs_path, REVIEWED_CORRECTIONS_REL_DIR, REVIEWED_CORRECTIONS_FILE_NAME });
}

pub fn reviewAndAppend(allocator: std.mem.Allocator, request: Request) !ReviewResult {
    const path = try reviewedCorrectionsPath(allocator, request.project_shard);
    defer allocator.free(path);
    return reviewAndAppendAtPath(allocator, request, path);
}

pub fn reviewAndAppendAtPath(allocator: std.mem.Allocator, request: Request, abs_path: []const u8) !ReviewResult {
    const parent = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    var file = try std.fs.createFileAbsolute(abs_path, .{
        .read = true,
        .truncate = false,
    });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    const record_json = try renderRecordJson(allocator, request, append_offset);
    errdefer allocator.free(record_json);
    try file.writeAll(record_json);
    try file.writeAll("\n");

    return .{
        .allocator = allocator,
        .record_json = record_json,
        .storage_path = try allocator.dupe(u8, abs_path),
    };
}

pub fn renderRecordJson(allocator: std.mem.Allocator, request: Request, append_offset: u64) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    const body_hash = std.hash.Fnv1a_64.hash(request.correction_candidate_json) ^ std.hash.Fnv1a_64.hash(request.reviewer_note);
    const id = try std.fmt.allocPrint(allocator, "reviewed-correction:{s}:{x:0>16}:{d}", .{ request.project_shard, body_hash, append_offset });
    defer allocator.free(id);

    try w.writeAll("{");
    try writeStringField(w, "id", id, true);
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, false);
    try writeStringField(w, "createdAt", "deterministic:append_order", false);
    try writeStringField(w, "reviewedAt", "deterministic:append_order", false);
    try writeStringField(w, "projectShard", request.project_shard, false);
    try writeStringField(w, "sourceCorrectionCandidateId", request.source_candidate_id, false);
    try w.writeAll(",\"correctionCandidate\":");
    try w.writeAll(request.correction_candidate_json);
    try writeStringField(w, "reviewDecision", @tagName(request.decision), false);
    try writeStringField(w, "reviewerNote", request.reviewer_note, false);
    try w.writeAll(",\"acceptedLearningOutputs\":");
    if (request.decision == .accepted) {
        try w.writeAll(request.accepted_learning_outputs_json);
    } else {
        try w.writeAll("[]");
    }
    try w.writeAll(",\"rejectedReason\":");
    if (request.decision == .rejected) {
        try writeJsonString(w, request.rejected_reason orelse "");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"futureBehaviorCandidate\":");
    if (request.decision == .accepted) {
        try w.writeAll("{");
        try writeStringField(w, "status", "candidate", true);
        try writeStringField(w, "kind", "reviewed_correction_influence_candidate", false);
        try writeStringField(w, "summary", "accepted reviewed correction may warn on repeated bad answer patterns or require stronger evidence in a later explicit lifecycle", false);
        try w.writeAll(",\"candidateOnly\":true,\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false");
        try w.writeAll("}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"nonAuthorizing\":true,\"treatedAsProof\":false,\"globalPromotion\":false");
    try w.writeAll(",\"commandsExecuted\":false,\"verifiersExecuted\":false,\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false");
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false,\"compaction\":false,\"stableOrdering\":\"file_append_order\"}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeStringField(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":");
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "reviewed correction append preserves prior records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reviewed.jsonl" });
    defer allocator.free(path);

    const req = Request{
        .project_shard = "phase7",
        .decision = .accepted,
        .reviewer_note = "reviewed",
        .rejected_reason = null,
        .source_candidate_id = "correction:candidate:1",
        .correction_candidate_json = "{\"id\":\"correction:candidate:1\"}",
        .accepted_learning_outputs_json = "[{\"kind\":\"verifier_check_candidate\"}]",
    };
    var first = try reviewAndAppendAtPath(allocator, req, path);
    defer first.deinit();
    var second = try reviewAndAppendAtPath(allocator, req, path);
    defer second.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.record_json, "\"appendOffsetBytes\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.record_json, "\"appendOffsetBytes\":0") == null);

    const data = try tmp.dir.readFileAlloc(allocator, "reviewed.jsonl", 16 * 1024);
    defer allocator.free(data);
    try std.testing.expect(std.mem.count(u8, data, "\n") == 2);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"nonAuthorizing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"treatedAsProof\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"globalPromotion\":false") != null);
}

test "rejected reviewed correction records rejected reason and no future influence" {
    const allocator = std.testing.allocator;
    const json = try renderRecordJson(allocator, .{
        .project_shard = "phase7",
        .decision = .rejected,
        .reviewer_note = "not valid",
        .rejected_reason = "overfit",
        .source_candidate_id = "correction:candidate:2",
        .correction_candidate_json = "{\"id\":\"correction:candidate:2\"}",
        .accepted_learning_outputs_json = "[]",
    }, 0);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reviewDecision\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rejectedReason\":\"overfit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"futureBehaviorCandidate\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"negativeKnowledgeMutation\":false") != null);
}
