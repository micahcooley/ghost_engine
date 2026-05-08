const std = @import("std");
const shards = @import("../shards.zig");

pub const SCHEMA_VERSION = "negative_knowledge_ledger.v1";
pub const LEDGER_REL_DIR = "negative_knowledge";
pub const LEDGER_FILE_NAME = "negative_knowledge_ledger.jsonl";
pub const MAX_LEDGER_READ_BYTES: usize = 4 * 1024 * 1024;

pub const FailureRecord = struct {
    failed_ast_hash: []const u8,
    axiom_violation: []const u8,
    timestamp: i64 = 0,
    project_shard: ?[]const u8 = null,
    source: []const u8 = "ghost_engine",
    failure_surface: ?[]const u8 = null,
    candidate_id: ?[]const u8 = null,
};

pub const LookupResult = struct {
    allocator: std.mem.Allocator,
    ledger_path: []u8,
    failed_ast_hash: []u8,
    matched: bool = false,
    axiom_violation: ?[]u8 = null,
    timestamp: ?i64 = null,
    records_read: usize = 0,
    malformed_lines: usize = 0,
    truncated: bool = false,
    missing_file: bool = false,

    pub fn deinit(self: *LookupResult) void {
        self.allocator.free(self.ledger_path);
        self.allocator.free(self.failed_ast_hash);
        if (self.axiom_violation) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub fn ledgerPathForProjectShard(allocator: std.mem.Allocator, project_shard: []const u8) ![]u8 {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    return ledgerPathForShardRoot(allocator, paths.root_abs_path);
}

pub fn ledgerPathForShardRoot(allocator: std.mem.Allocator, shard_root_abs_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ shard_root_abs_path, LEDGER_REL_DIR, LEDGER_FILE_NAME });
}

pub fn hashBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const prefix = "sha256:";
    var out = try allocator.alloc(u8, prefix.len + digest.len * 2);
    @memcpy(out[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, idx| {
        out[prefix.len + idx * 2] = hex[byte >> 4];
        out[prefix.len + idx * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

pub fn appendFailureIfNewAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    record: FailureRecord,
) !bool {
    var existing = try lookupFailureAtPath(allocator, abs_path, record.failed_ast_hash);
    defer existing.deinit();
    if (existing.matched) return false;
    try appendFailureAtPath(allocator, abs_path, record);
    return true;
}

pub fn appendFailureAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    record: FailureRecord,
) !void {
    const parent = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);

    var file = try std.fs.createFileAbsolute(abs_path, .{ .read = true, .truncate = false });
    defer file.close();
    const append_offset = try file.getEndPos();
    try file.seekTo(append_offset);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.writeByte('{');
    try writeStringField(w, "schemaVersion", SCHEMA_VERSION, true);
    try writeStringField(w, "failed_ast_hash", record.failed_ast_hash, false);
    try writeStringField(w, "failedAstHash", record.failed_ast_hash, false);
    try writeStringField(w, "axiom_violation", record.axiom_violation, false);
    try writeStringField(w, "axiomViolation", record.axiom_violation, false);
    try w.print(",\"timestamp\":{d}", .{if (record.timestamp == 0) std.time.timestamp() else record.timestamp});
    if (record.project_shard) |value| try writeStringField(w, "projectShard", value, false);
    try writeStringField(w, "source", record.source, false);
    if (record.failure_surface) |value| try writeStringField(w, "failureSurface", value, false);
    if (record.candidate_id) |value| try writeStringField(w, "candidateId", value, false);
    try w.writeAll(",\"appendOnly\":{\"storage\":\"jsonl\",\"appendOffsetBytes\":");
    try w.print("{d}", .{append_offset});
    try w.writeAll(",\"inPlaceRewrite\":false,\"deletion\":false}}");

    try file.writeAll(out.items);
    try file.writeAll("\n");
}

pub fn lookupFailureAtPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    failed_ast_hash: []const u8,
) !LookupResult {
    var result = LookupResult{
        .allocator = allocator,
        .ledger_path = try allocator.dupe(u8, abs_path),
        .failed_ast_hash = try allocator.dupe(u8, failed_ast_hash),
    };
    errdefer result.deinit();

    var file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            result.missing_file = true;
            return result;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const read_len: usize = @intCast(@min(stat.size, MAX_LEDGER_READ_BYTES));
    if (stat.size > MAX_LEDGER_READ_BYTES) result.truncated = true;
    const bytes = try file.readToEndAlloc(allocator, read_len);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        result.records_read += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            result.malformed_lines += 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            result.malformed_lines += 1;
            continue;
        }
        const obj = parsed.value.object;
        const hash = getStrAny(obj, &.{ "failed_ast_hash", "failedAstHash" }) orelse {
            result.malformed_lines += 1;
            continue;
        };
        if (!std.mem.eql(u8, hash, failed_ast_hash)) continue;

        result.matched = true;
        result.axiom_violation = try allocator.dupe(u8, getStrAny(obj, &.{ "axiom_violation", "axiomViolation" }) orelse "");
        result.timestamp = getIntAny(obj, &.{"timestamp"});
        return result;
    }

    return result;
}

fn getStrAny(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn getIntAny(obj: std.json.ObjectMap, names: []const []const u8) ?i64 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .integer) return value.integer;
    }
    return null;
}

fn writeStringField(w: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    try writeJsonString(w, value);
}

fn writeJsonString(w: anytype, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "negative knowledge ledger appends and matches cryptographic failure hash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try ledgerPathForShardRoot(allocator, root);
    defer allocator.free(path);

    const hash = try hashBytes(allocator, "std::vector<int>{}.push_front(1)");
    defer allocator.free(hash);

    const appended = try appendFailureIfNewAtPath(allocator, path, .{
        .failed_ast_hash = hash,
        .axiom_violation = "std::vector does not declare push_front",
        .timestamp = 123,
        .project_shard = "ledger-test",
        .source = "unit",
        .failure_surface = "zig_build",
        .candidate_id = "candidate-1",
    });
    try std.testing.expect(appended);

    var lookup = try lookupFailureAtPath(allocator, path, hash);
    defer lookup.deinit();
    try std.testing.expect(lookup.matched);
    try std.testing.expectEqualStrings("std::vector does not declare push_front", lookup.axiom_violation.?);
    try std.testing.expectEqual(@as(i64, 123), lookup.timestamp.?);

    const duplicate = try appendFailureIfNewAtPath(allocator, path, .{
        .failed_ast_hash = hash,
        .axiom_violation = "duplicate",
        .timestamp = 124,
    });
    try std.testing.expect(!duplicate);
}
