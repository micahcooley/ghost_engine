const std = @import("std");

pub const HyperTension = struct {
    segments: std.AutoHashMap(u64, u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HyperTension {
        return .{
            .segments = std.AutoHashMap(u64, u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HyperTension) void {
        self.segments.deinit();
    }

    pub fn addTension(self: *HyperTension, val: i128) !void {
        const uval: u128 = @bitCast(val);
        const low = @as(u64, @truncate(uval));
        const high = @as(u64, @truncate(uval >> 64));
        try self.setBit(low);
        try self.setBit(high);
    }

    fn setBit(self: *HyperTension, bit: u64) !void {
        const seg_idx = bit / 64;
        const bit_idx = @as(u6, @intCast(bit % 64));
        const g = try self.segments.getOrPut(seg_idx);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* |= (@as(u64, 1) << bit_idx);
    }
};
