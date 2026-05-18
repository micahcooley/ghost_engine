const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");
const aether = @import("aether.zig");

pub const OmniModalField = struct {
    voxels: std.AutoHashMap(u64, i128),
    allocator: std.mem.Allocator,
    kernel: u64 = 0x809556DD9C3D119A,

    pub fn init(allocator: std.mem.Allocator) OmniModalField {
        return .{
            .voxels = std.AutoHashMap(u64, i128).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OmniModalField) void {
        self.voxels.deinit();
    }

    pub fn ingest(self: *OmniModalField, data: []const u8) !void {
        var h: u64 = self.kernel;
        for (data, 0..) |b, i| {
            h = void_eng.splitMix64(h ^ b ^ i);
            const voxel_coord = void_eng.splitMix64(h);
            const g = try self.voxels.getOrPut(voxel_coord);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* = (g.value_ptr.* +% @as(i128, b)) ^ @as(i128, @intCast(h));
        }
    }
};
