const std = @import("std");
const ghost = @import("ghost_core");

const axioms = ghost.axioms;
const static_eval = ghost.static_eval;

test "The Dangling Pointer Trap flags escaping C++ reference without compiler execution" {
    var matrix = try axioms.defaultMatrix(std.testing.allocator, .cpp);
    defer matrix.deinit();

    var result = try static_eval.evaluateSnippet(std.testing.allocator,
        \\int& leak() {
        \\    int local = 42;
        \\    return local;
        \\}
    , .cpp, matrix);
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    const violation = result.violations[0];
    try std.testing.expectEqual(static_eval.ViolationKind.dangling_reference, violation.kind);
    try std.testing.expectEqual(@as(u32, 3), violation.line);
    try std.testing.expectEqual(@as(u8, 0), violation.authority_level);
    try std.testing.expect(violation.contradiction);
    try std.testing.expect(std.mem.indexOf(u8, violation.reason, "lifetime ends at function exit") != null);
}

test "The Zig Comptime Paradox resolves disguised comptime type mismatch" {
    var matrix = try axioms.defaultMatrix(std.testing.allocator, .zig);
    defer matrix.deinit();

    var result = try static_eval.evaluateSnippet(std.testing.allocator,
        \\test "comptime paradox" {
        \\    comptime {
        \\        const T = if (true) u8 else []const u8;
        \\        const value: T = "not a byte";
        \\        _ = value;
        \\    }
        \\}
    , .zig, matrix);
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    const violation = result.violations[0];
    try std.testing.expectEqual(static_eval.ViolationKind.comptime_type_mismatch, violation.kind);
    try std.testing.expectEqual(@as(u32, 4), violation.line);
    try std.testing.expectEqual(@as(u8, 0), violation.authority_level);
    try std.testing.expect(violation.contradiction);
    try std.testing.expect(std.mem.indexOf(u8, violation.reason, "resolved static type") != null);
}

test "The Standard Library Hallucination rejects std::vector::push_front" {
    var matrix = try axioms.defaultMatrix(std.testing.allocator, .cpp);
    defer matrix.deinit();

    var result = try static_eval.evaluateSnippet(std.testing.allocator,
        \\#include <vector>
        \\void f() {
        \\    std::vector<int> values;
        \\    values.push_front(7);
        \\}
    , .cpp, matrix);
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    const violation = result.violations[0];
    try std.testing.expectEqual(static_eval.ViolationKind.missing_std_member, violation.kind);
    try std.testing.expectEqual(@as(u32, 4), violation.line);
    try std.testing.expectEqual(@as(u8, 0), violation.authority_level);
    try std.testing.expect(violation.contradiction);
    try std.testing.expect(std.mem.indexOf(u8, violation.reason, "does not declare push_front") != null);
}
