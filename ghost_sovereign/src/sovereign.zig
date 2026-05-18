const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");
const aether = @import("aether.zig");
const lore = @import("lore.zig");
const hyper_bitset = @import("hyper_bitset.zig");
const echo = @import("echo.zig");

// --- GHOST SOVEREIGN: THE META-ARCHITECTURE (Mark: 0xA8BA1ED64D5E0DC3) ---

pub const SovereignEngine = struct {
    truth_field: aether.AetherField,
    shadow_field: aether.AetherField,
    lore: lore.LoreEngine,
    tension_log: hyper_bitset.HyperTension,
    echo_manager: echo.EchoManager,
    kernel: u64 = 0xA8BA1ED64D5E0DC3,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) SovereignEngine {
        return .{
            .truth_field = aether.AetherField.init(allocator),
            .shadow_field = aether.AetherField.init(allocator),
            .lore = lore.LoreEngine.init(allocator, seed),
            .tension_log = hyper_bitset.HyperTension.init(allocator),
            .echo_manager = echo.EchoManager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SovereignEngine) void {
        self.echo_manager.persist(&self.truth_field) catch {};
        self.truth_field.deinit();
        self.shadow_field.deinit();
        self.tension_log.deinit();
    }

    pub fn ingest(self: *SovereignEngine, text: []const u8) !void {
        var h: u64 = self.kernel;
        for (text) |b| {
            h = void_eng.splitMix64(h ^ b);
            const is_truth = (h % 100 > 95); // 5% Truth filter
            if (is_truth) {
                try self.truth_field.ingest(text);
            } else {
                try self.shadow_field.ingest(text);
            }
            try self.tension_log.addTension(@as(i128, b));
        }
        self.lore.learn(text);
    }
};
