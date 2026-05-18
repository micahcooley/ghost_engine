const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");

pub const LoreEngine = struct {
    grammar_lattice: [flame.ScarCount]u64,
    historical_shadow: [flame.ChamberCount]i128,
    kernel: u64 = 0xDEB1A89A4C614E3F,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) LoreEngine {
        var engine = LoreEngine{
            .grammar_lattice = [_]u64{0} ** flame.ScarCount,
            .historical_shadow = [_]i128{0} ** flame.ChamberCount,
            .allocator = allocator,
        };
        var s = seed ^ engine.kernel;
        for (&engine.grammar_lattice) |*word| {
            s = void_eng.splitMix64(s);
            word.* = s;
        }
        return engine;
    }

    pub fn learn(self: *LoreEngine, text: []const u8) void {
        var h: u64 = self.kernel;
        for (text, 0..) |b, i| {
            h = void_eng.splitMix64(h ^ b ^ i);
            const lattice_idx = h % flame.ScarCount;
            self.grammar_lattice[lattice_idx] ^= h;
            const shadow_idx = h % flame.ChamberCount;
            self.historical_shadow[shadow_idx] = (self.historical_shadow[shadow_idx] +% @as(i128, b)) ^ @as(i128, @intCast(h));
        }
    }
};
