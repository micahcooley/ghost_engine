const std = @import("std");
const config = @import("config.zig");

pub const ScanSnapshot = struct {
    hash: u64 = 0,
    energy: u32 = 0,
};

pub const ControlPlane = struct {
    allocator: std.mem.Allocator,
    saturation_bonus: u32 = config.SATURATION_BONUS,
    boredom_penalty_high: u32 = config.BOREDOM_PENALTY_HIGH,
    boredom_penalty_low: u32 = config.BOREDOM_PENALTY_LOW,
    enable_vulkan: bool = false,
    force_cpu_only: bool = false,
    last_scan: ScanSnapshot = .{},
    locked_slots: std.AutoHashMap(u32, void),
    locked_hashes: std.AutoHashMap(u64, void),
    bindings: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) ControlPlane {
        return .{
            .allocator = allocator,
            .locked_slots = std.AutoHashMap(u32, void).init(allocator),
            .locked_hashes = std.AutoHashMap(u64, void).init(allocator),
            .bindings = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *ControlPlane) void {
        self.locked_slots.deinit();
        self.locked_hashes.deinit();

        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn applyMoodName(self: *ControlPlane, mood_name: []const u8) void {
        if (std.ascii.eqlIgnoreCase(mood_name, "aggressive")) {
            self.saturation_bonus = 96;
            self.boredom_penalty_high = 8;
            self.boredom_penalty_low = 4;
            return;
        }
        if (std.ascii.eqlIgnoreCase(mood_name, "focused")) {
            self.saturation_bonus = 80;
            self.boredom_penalty_high = 16;
            self.boredom_penalty_low = 8;
            return;
        }
        if (std.ascii.eqlIgnoreCase(mood_name, "calm")) {
            self.saturation_bonus = 40;
            self.boredom_penalty_high = 40;
            self.boredom_penalty_low = 20;
            return;
        }

        self.saturation_bonus = config.SATURATION_BONUS;
        self.boredom_penalty_high = config.BOREDOM_PENALTY_HIGH;
        self.boredom_penalty_low = config.BOREDOM_PENALTY_LOW;
    }

    pub fn lockSlot(self: *ControlPlane, slot: u32) !void {
        try self.locked_slots.put(slot, {});
    }

    pub fn lockHash(self: *ControlPlane, hash: u64) !void {
        try self.locked_hashes.put(hash, {});
    }

    pub fn bindRune(self: *ControlPlane, label: []const u8, rune: u32) !void {
        const owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned);

        const result = try self.bindings.getOrPut(owned);
        if (result.found_existing) {
            self.allocator.free(owned);
        } else {
            result.key_ptr.* = owned;
        }
        result.value_ptr.* = rune;
    }
};

var active_control: ?*ControlPlane = null;

pub fn setActive(control: ?*ControlPlane) void {
    active_control = control;
}

pub fn getActive() ?*ControlPlane {
    return active_control;
}

pub fn getSaturationBonus() u32 {
    return if (active_control) |control| control.saturation_bonus else config.SATURATION_BONUS;
}

pub fn getBoredomPenaltyHigh() u32 {
    return if (active_control) |control| control.boredom_penalty_high else config.BOREDOM_PENALTY_HIGH;
}

pub fn getBoredomPenaltyLow() u32 {
    return if (active_control) |control| control.boredom_penalty_low else config.BOREDOM_PENALTY_LOW;
}

pub fn isHashLocked(hash: u64) bool {
    return if (active_control) |control| control.locked_hashes.contains(hash) else false;
}

pub fn isSlotLocked(slot: u32) bool {
    return if (active_control) |control| control.locked_slots.contains(slot) else false;
}

pub fn getActiveControl() ?*ControlPlane {
    return active_control;
}
