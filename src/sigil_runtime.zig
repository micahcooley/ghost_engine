const std = @import("std");
const config = @import("config.zig");

pub const ScanSnapshot = struct {
    hash: u64 = 0,
    energy: u32 = 0,
};

pub const EtchTelemetry = struct {
    total_etches: u64 = 0,
    total_drift: u64 = 0,
    last_hash: u64 = 0,
    last_energy: u16 = 0,
    ema_average: u32 = 850 << 8,
    ema_deviation: u32 = 25 << 8,
    slot_usage: usize = 0,
    slot_usage_initialized: bool = false,
};

const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

pub const ControlSnapshot = struct {
    saturation_bonus: u32,
    boredom_penalty_high: u32,
    boredom_penalty_low: u32,
    enable_vulkan: bool,
    force_cpu_only: bool,
    loom_tier: u8,
    lattice_cache_cap_bytes: u64,
    last_scan: ScanSnapshot,
    locked_slot_count: usize,
    locked_hash_count: usize,
    binding_count: usize,
    etch: EtchTelemetry,
};

pub const ControlPlane = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    saturation_bonus: u32 = config.SATURATION_BONUS,
    boredom_penalty_high: u32 = config.BOREDOM_PENALTY_HIGH,
    boredom_penalty_low: u32 = config.BOREDOM_PENALTY_LOW,
    enable_vulkan: bool = false,
    force_cpu_only: bool = false,
    loom_tier: u8 = 0,
    lattice_cache_cap_bytes: u64 = config.IDEAL_LATTICE_SIZE,
    last_scan: ScanSnapshot = .{},
    etch: EtchTelemetry = .{},
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
        self.mutex.lock();
        defer self.mutex.unlock();
        self.locked_slots.deinit();
        self.locked_hashes.deinit();

        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn applyMoodName(self: *ControlPlane, mood_name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
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

    pub fn setSaturationBonus(self: *ControlPlane, tuned: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.saturation_bonus = tuned;
    }

    pub fn setComputeMode(self: *ControlPlane, enable_vulkan: bool, force_cpu_only: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enable_vulkan = enable_vulkan;
        self.force_cpu_only = force_cpu_only;
    }

    pub fn setLoomTier(self: *ControlPlane, tier: u8, cache_cap_bytes: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.loom_tier = tier;
        self.lattice_cache_cap_bytes = cache_cap_bytes;
    }

    pub fn setLastScan(self: *ControlPlane, scan: ScanSnapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_scan = scan;
    }

    pub fn snapshot(self: *ControlPlane) ControlSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .saturation_bonus = self.saturation_bonus,
            .boredom_penalty_high = self.boredom_penalty_high,
            .boredom_penalty_low = self.boredom_penalty_low,
            .enable_vulkan = self.enable_vulkan,
            .force_cpu_only = self.force_cpu_only,
            .loom_tier = self.loom_tier,
            .lattice_cache_cap_bytes = self.lattice_cache_cap_bytes,
            .last_scan = self.last_scan,
            .locked_slot_count = self.locked_slots.count(),
            .locked_hash_count = self.locked_hashes.count(),
            .binding_count = self.bindings.count(),
            .etch = self.etch,
        };
    }

    pub fn recordEtch(
        self: *ControlPlane,
        hash: u64,
        energy: u16,
        drift: u64,
        inserted_new_slot: bool,
        slot_usage_hint: ?usize,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.etch.total_etches += 1;
        self.etch.total_drift += drift;
        self.etch.last_hash = hash;
        self.etch.last_energy = energy;
        self.last_scan = .{
            .hash = hash,
            .energy = energy,
        };

        if (!self.etch.slot_usage_initialized) {
            if (slot_usage_hint) |hint| {
                self.etch.slot_usage = hint;
                self.etch.slot_usage_initialized = true;
            }
        } else if (inserted_new_slot) {
            self.etch.slot_usage += 1;
        }

        updateEma(&self.etch, energy);
    }

    pub fn fillLockedSlotMask(self: *ControlPlane, mask: []u32, matrix_slots: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        @memset(std.mem.sliceAsBytes(mask), 0);
        var it = self.locked_slots.iterator();
        while (it.next()) |entry| {
            const slot = entry.key_ptr.*;
            if (slot >= matrix_slots) continue;
            const word_index: usize = slot / 32;
            const bit_index: u5 = @intCast(slot % 32);
            mask[word_index] |= (@as(u32, 1) << bit_index);
        }
    }

    pub fn getSaturationBonusValue(self: *ControlPlane) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.saturation_bonus;
    }

    pub fn getBoredomPenaltyHighValue(self: *ControlPlane) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.boredom_penalty_high;
    }

    pub fn getBoredomPenaltyLowValue(self: *ControlPlane) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.boredom_penalty_low;
    }

    pub fn lockSlot(self: *ControlPlane, slot: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.locked_slots.put(slot, {});
    }

    pub fn lockHash(self: *ControlPlane, hash: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.locked_hashes.put(hash, {});
    }

    pub fn isHashLocked(self: *ControlPlane, hash: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.locked_hashes.contains(hash);
    }

    pub fn isSlotLocked(self: *ControlPlane, slot: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.locked_slots.contains(slot);
    }

    pub fn bindRune(self: *ControlPlane, label: []const u8, rune: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
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

fn updateEma(telemetry: *EtchTelemetry, sample: u16) void {
    const s = @as(u32, sample) << 8;
    const diff = if (s > telemetry.ema_average) s - telemetry.ema_average else telemetry.ema_average - s;
    const alpha_shift: u5 = 4;
    const a = @as(u64, 1) << alpha_shift;
    telemetry.ema_average = @intCast((@as(u64, telemetry.ema_average) * (a - 1) + @as(u64, s)) >> alpha_shift);
    telemetry.ema_deviation = @intCast((@as(u64, telemetry.ema_deviation) * (a - 1) + @as(u64, diff)) >> alpha_shift);
}

var active_control: ?*ControlPlane = null;

pub fn setActive(control: ?*ControlPlane) void {
    active_control = control;
}

pub fn getActive() ?*ControlPlane {
    return active_control;
}

pub fn getSaturationBonus() u32 {
    return if (active_control) |control| control.getSaturationBonusValue() else config.SATURATION_BONUS;
}

pub fn getBoredomPenaltyHigh() u32 {
    return if (active_control) |control| control.getBoredomPenaltyHighValue() else config.BOREDOM_PENALTY_HIGH;
}

pub fn getBoredomPenaltyLow() u32 {
    return if (active_control) |control| control.getBoredomPenaltyLowValue() else config.BOREDOM_PENALTY_LOW;
}

pub fn isHashLocked(hash: u64) bool {
    return if (active_control) |control| control.isHashLocked(hash) else false;
}

pub fn isSlotLocked(slot: u32) bool {
    return if (active_control) |control| control.isSlotLocked(slot) else false;
}

pub fn getActiveControl() ?*ControlPlane {
    return active_control;
}
