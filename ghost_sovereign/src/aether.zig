const std = @import("std");
const flame = @import("flame");
const void_eng = @import("void");

pub const AetherField = struct {
    points: std.AutoHashMap(u64, i128),
    allocator: std.mem.Allocator,
    kernel: u64 = 0xFEB5AEB9C5E1A181,

    pub fn init(allocator: std.mem.Allocator) AetherField {
        return .{
            .points = std.AutoHashMap(u64, i128).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AetherField) void {
        self.points.deinit();
    }

    pub fn ingest(self: *AetherField, text: []const u8) !void {
        var h: u64 = self.kernel;
        for (text, 0..) |b, i| {
            h = void_eng.splitMix64(h ^ b ^ i);
            const coord = void_eng.splitMix64(h);
            const g = try self.points.getOrPut(coord);
            if (!g.found_existing) g.value_ptr.* = 0;
            const tension_delta = @as(i128, b) * @as(i128, @intCast(coord % 1_000_000));
            g.value_ptr.* = (g.value_ptr.* +% tension_delta) ^ @as(i128, @intCast(h));
            const split_coord = void_eng.splitMix64(coord ^ 0xDF89C461E6594C4C);
            const s = try self.points.getOrPut(split_coord);
            if (!s.found_existing) s.value_ptr.* = g.value_ptr.*;
        }
    }
};
