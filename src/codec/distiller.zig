const std = @import("std");
const gutf = @import("gutf.zig");

pub const CausalRule = enum {
    validation_guard,
    bounds_guard,
    null_fallback,
    api_contract,
    dependency_resolution,
    generic_software_fix,

    pub fn label(self: CausalRule) []const u8 {
        return switch (self) {
            .validation_guard => "validation guard changes failure outcome",
            .bounds_guard => "bounds guard changes failure outcome",
            .null_fallback => "null fallback changes failure outcome",
            .api_contract => "API contract change alters test behavior",
            .dependency_resolution => "dependency resolution rule changes solver outcome",
            .generic_software_fix => "verified patch changes test outcome",
        };
    }
};

pub const VerifiedPatch = struct {
    instance_id: []const u8,
    repo: []const u8,
    base_commit: []const u8,
    patch: []const u8,
    fail_to_pass_count: usize,
    pass_to_pass_count: usize,
    semantic_class: gutf.IntentClass = .software_engineering,
};

pub const DistilledRune = struct {
    instance_id: []const u8,
    repo: []const u8,
    base_commit: []const u8,
    semantic_class: gutf.IntentClass,
    causal_rule: CausalRule,
    patch_hash: u64,
    rune: gutf.RuneBytes,
};

pub fn distillVerifiedPatch(input: VerifiedPatch) !DistilledRune {
    if (input.patch.len == 0) return error.EmptyPatch;
    if (input.fail_to_pass_count == 0) return error.MissingFailToPassProof;
    if (input.pass_to_pass_count == 0) return error.MissingPassToPassProof;

    var seed = std.hash.Wyhash.hash(0x4755_5446, input.instance_id);
    seed ^= std.hash.Wyhash.hash(seed, input.repo);
    seed ^= std.hash.Wyhash.hash(seed, input.base_commit);
    const patch_hash = std.hash.Wyhash.hash(seed, input.patch);
    const rune = gutf.deterministicRuneBytes(patch_hash, @intFromEnum(input.semantic_class));

    return .{
        .instance_id = input.instance_id,
        .repo = input.repo,
        .base_commit = input.base_commit,
        .semantic_class = input.semantic_class,
        .causal_rule = classifyCausalRule(input.patch),
        .patch_hash = patch_hash,
        .rune = rune,
    };
}

pub fn classifyCausalRule(patch: []const u8) CausalRule {
    if (containsAnyIgnoreCase(patch, &.{ "bounds", "outofbounds", "out of bounds", "overflow", "underflow", "len", "length" })) {
        return .bounds_guard;
    }
    if (containsAnyIgnoreCase(patch, &.{ "validate", "validation", "valid", "invalid", "identifier", "keyword" })) {
        return .validation_guard;
    }
    if (containsAnyIgnoreCase(patch, &.{ "null", "none", "undefined", "fallback", "missing" })) {
        return .null_fallback;
    }
    if (containsAnyIgnoreCase(patch, &.{ "dependency", "dependencies", "resolver", "collection", "version" })) {
        return .dependency_resolution;
    }
    if (containsAnyIgnoreCase(patch, &.{ "route", "handler", "controller", "request", "response", "api" })) {
        return .api_contract;
    }
    return .generic_software_fix;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

pub fn writeGkpackRecord(writer: anytype, record: DistilledRune) !void {
    try writer.writeAll("{\"schema\":\"ghost.gutf.rune.v1\",\"instanceId\":");
    try std.json.stringify(record.instance_id, .{}, writer);
    try writer.writeAll(",\"repo\":");
    try std.json.stringify(record.repo, .{}, writer);
    try writer.writeAll(",\"baseCommit\":");
    try std.json.stringify(record.base_commit, .{}, writer);
    try writer.writeAll(",\"semanticClass\":");
    try std.json.stringify(@tagName(record.semantic_class), .{}, writer);
    try writer.writeAll(",\"causalRule\":");
    try std.json.stringify(@tagName(record.causal_rule), .{}, writer);
    try writer.writeAll(",\"causalRuleLabel\":");
    try std.json.stringify(record.causal_rule.label(), .{}, writer);
    try writer.print(",\"patchHash\":{d},\"runeHex\":\"", .{record.patch_hash});
    for (record.rune) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.writeAll("\",\"epistemicTag\":\"verified\",\"nonAuthorizing\":false}\n");
}

test "verified patch distills into a 1024-bit software-engineering rune" {
    const patch =
        \\diff --git a/src/check.zig b/src/check.zig
        \\+if (idx >= items.len) return error.OutOfBounds;
    ;
    const rune = try distillVerifiedPatch(.{
        .instance_id = "instance:bounds",
        .repo = "example/repo",
        .base_commit = "abc",
        .patch = patch,
        .fail_to_pass_count = 1,
        .pass_to_pass_count = 1,
    });
    try std.testing.expectEqual(CausalRule.bounds_guard, rune.causal_rule);
    try std.testing.expectEqual(gutf.ByteClass.hyper_bitstream, gutf.classifyByte(rune.rune[0]));
    try std.testing.expectEqual(@as(usize, gutf.RUNE_BYTES), rune.rune.len);
}

test "distiller refuses unproven patches" {
    try std.testing.expectError(error.MissingFailToPassProof, distillVerifiedPatch(.{
        .instance_id = "i",
        .repo = "r",
        .base_commit = "b",
        .patch = "diff",
        .fail_to_pass_count = 0,
        .pass_to_pass_count = 1,
    }));
}
