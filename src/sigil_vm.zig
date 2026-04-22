const std = @import("std");
const config = @import("config.zig");
const sigil_core = @import("sigil_core.zig");
const sigil_runtime = @import("sigil_runtime.zig");
const ghost_state = @import("ghost_state.zig");
const scratchpad = @import("scratchpad.zig");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");

pub const MeaningSurface = union(enum) {
    permanent: *vsa.MeaningMatrix,
    scratchpad: *scratchpad.OverlayMeaningMatrix,

    pub fn collapseToBinary(self: *const MeaningSurface, hash: u64) vsa.HyperVector {
        return switch (self.*) {
            .permanent => |meaning| meaning.collapseToBinary(hash),
            .scratchpad => |meaning| meaning.collapseToBinary(hash),
        };
    }

    pub fn applyGravity(
        self: *MeaningSurface,
        word_hash: u64,
        data: vsa.HyperVector,
        hash_locked: bool,
        slot_lock_mask: u32,
    ) vsa.GravityResult {
        return switch (self.*) {
            .permanent => |meaning| meaning.applyGravity(word_hash, data, hash_locked, slot_lock_mask),
            .scratchpad => |meaning| meaning.applyGravity(word_hash, data, hash_locked, slot_lock_mask),
        };
    }

    pub fn hardLockUniversalSigil(self: *MeaningSurface, hash: u64, rune: u32) void {
        switch (self.*) {
            .permanent => |meaning| meaning.hardLockUniversalSigil(hash, rune),
            .scratchpad => |meaning| meaning.hardLockUniversalSigil(hash, rune),
        }
    }

    pub fn slotUsageHint(self: *const MeaningSurface) ?usize {
        return switch (self.*) {
            .permanent => |meaning| if (meaning.tags) |tags| countUsedTags(tags) else null,
            .scratchpad => |meaning| meaning.slotUsageHint(),
        };
    }

    pub fn slotCount(self: *const MeaningSurface) ?u32 {
        return switch (self.*) {
            .permanent => |meaning| if (meaning.tags) |tags| @as(u32, @intCast(tags.len)) else null,
            .scratchpad => |meaning| if (meaning.scratch.tags) |tags| @as(u32, @intCast(tags.len)) else null,
        };
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    control: *sigil_runtime.ControlPlane,
    meaning: ?*MeaningSurface = null,
    soul: ?*ghost_state.GhostSoul = null,
    lattice: ?*ghost_state.UnifiedLattice = null,
};

const EtchLockState = struct {
    hash_locked: bool,
    slot_lock_mask: u32,
};

pub fn executeFile(ctx: *Context, path: []const u8) !void {
    const handle = try sys.openForRead(ctx.allocator, path);
    defer sys.closeFile(handle);

    const size = try sys.getFileSize(handle);
    const source = try ctx.allocator.alloc(u8, size);
    defer ctx.allocator.free(source);
    _ = try sys.readAll(handle, source);
    try executeSource(ctx, source);
}

pub fn executeSource(ctx: *Context, source: []const u8) !void {
    var program = try sigil_core.compileScript(ctx.allocator, source);
    defer program.deinit();
    try executeProgram(ctx, &program);
}

pub fn executeProgram(ctx: *Context, program: *const sigil_core.Program) !void {
    var ip: usize = 0;
    while (ip < program.instructions.len) {
        const inst = program.instructions[ip];
        switch (inst.opcode) {
            .halt => return,
            .mood => try execMood(ctx, program, inst),
            .loom => execLoom(ctx, inst),
            .lock => try execLock(ctx, program, inst),
            .scan => execScan(ctx, program, inst),
            .bind => try execBind(ctx, program, inst),
            .etch => execEtch(ctx, program, inst),
            .void_op => execVoid(ctx, program, inst),
            .jmp_if_false => {
                if (inst.a == 0) {
                    ip = @intCast(@max(inst.b, 0));
                    continue;
                }
            },
        }
        ip += 1;
    }
}

fn execMood(ctx: *Context, program: *const sigil_core.Program, inst: sigil_core.Instruction) !void {
    switch (inst.mode) {
        .string => {
            const mood_name = program.strings[inst.string_index];
            ctx.control.applyMoodName(mood_name);
            const snapshot = ctx.control.snapshot();
            sys.print("[SIGIL VM] MOOD {s} => saturation={d} boredom=({d},{d})\n", .{
                mood_name,
                snapshot.saturation_bonus,
                snapshot.boredom_penalty_high,
                snapshot.boredom_penalty_low,
            });
        },
        .integer => {
            const tuned = @as(u32, @intCast(@max(inst.a, 0)));
            ctx.control.setSaturationBonus(tuned);
            sys.print("[SIGIL VM] MOOD saturation bonus set to {d}\n", .{tuned});
        },
        else => {},
    }
}

fn execLoom(ctx: *Context, inst: sigil_core.Instruction) void {
    const command = @as(sigil_core.LoomCommand, @enumFromInt(@as(u8, @intCast(@max(inst.a, 0)))));
    switch (command) {
        .vulkan_init => {
            ctx.control.setComputeMode(true, false);
            sys.printOut("[SIGIL VM] LOOM VULKAN_INIT\n");
        },
        .cpu_only => {
            ctx.control.setComputeMode(false, true);
            sys.printOut("[SIGIL VM] LOOM CPU_ONLY\n");
        },
        .proof => {
            ctx.control.setReasoningMode(.proof);
            sys.printOut("[SIGIL VM] LOOM PROOF\n");
        },
        .exploratory => {
            ctx.control.setReasoningMode(.exploratory);
            sys.printOut("[SIGIL VM] LOOM EXPLORATORY\n");
        },
        .tier_1 => {
            ctx.control.setLoomTier(1, 64 * 1024 * 1024);
            sys.printOut("[SIGIL VM] LOOM TIER_1 => cache cap 64MiB\n");
        },
        .tier_2 => {
            ctx.control.setLoomTier(2, 128 * 1024 * 1024);
            sys.printOut("[SIGIL VM] LOOM TIER_2 => cache cap 128MiB\n");
        },
        .tier_3 => {
            ctx.control.setLoomTier(3, 256 * 1024 * 1024);
            sys.printOut("[SIGIL VM] LOOM TIER_3 => cache cap 256MiB\n");
        },
        .tier_4 => {
            ctx.control.setLoomTier(4, 512 * 1024 * 1024);
            sys.printOut("[SIGIL VM] LOOM TIER_4 => cache cap 512MiB\n");
        },
        .none => {
            sys.printOut("[SIGIL VM] LOOM command ignored\n");
        },
    }
}

fn execLock(ctx: *Context, program: *const sigil_core.Program, inst: sigil_core.Instruction) !void {
    switch (inst.mode) {
        .integer => {
            const slot = @as(u32, @intCast(@max(inst.a, 0)));
            try ctx.control.lockSlot(slot);
            sys.print("[SIGIL VM] LOCK slot {d}\n", .{slot});
        },
        .string => {
            const symbol = program.strings[inst.string_index];
            const hash = semanticHash(symbol);
            try ctx.control.lockHash(hash);
            sys.print("[SIGIL VM] LOCK hash 0x{x} ({s})\n", .{ hash, symbol });
        },
        else => {},
    }
}

fn execScan(ctx: *Context, program: *const sigil_core.Program, inst: sigil_core.Instruction) void {
    const target = program.strings[inst.string_index];
    if (std.ascii.eqlIgnoreCase(target, "system_memory")) {
        sys.print("[SIGIL VM] SCAN system_memory => lattice={d} semantic={d} tags={d}\n", .{
            config.UNIFIED_SIZE_BYTES,
            config.SEMANTIC_SIZE_BYTES,
            config.TAG_SIZE_BYTES,
        });
        ctx.control.setLastScan(.{ .hash = 0, .energy = @intCast(config.TOTAL_STATE_BYTES / 1024 / 1024) });
        return;
    }

    if (ctx.meaning) |meaning| {
        const hash = semanticHash(target);
        const vec = meaning.collapseToBinary(hash);
        const energy: u32 = if (ctx.soul) |soul|
            vsa.calculateResonance(vec, soul.concept)
        else
            vsa.calculateResonance(vec, @splat(@as(u64, 0)));
        ctx.control.setLastScan(.{ .hash = hash, .energy = energy });
        sys.print("[SIGIL VM] SCAN {s} => hash=0x{x} energy={d}\n", .{ target, hash, energy });
    }
}

fn execBind(ctx: *Context, program: *const sigil_core.Program, inst: sigil_core.Instruction) !void {
    const rune_value = @as(u32, @intCast(@max(inst.a, 0)));
    const label = program.strings[inst.string_index];
    try ctx.control.bindRune(label, rune_value);

    if (ctx.meaning) |meaning| {
        const hash = semanticHash(label);
        meaning.hardLockUniversalSigil(hash, rune_value);
        try ctx.control.lockHash(hash);
        sys.print("[SIGIL VM] BIND U+{X:0>6} TO {s}\n", .{ rune_value, label });
    }
}

fn execEtch(ctx: *Context, program: *const sigil_core.Program, inst: sigil_core.Instruction) void {
    const payload = program.strings[inst.string_index];
    if (ctx.meaning) |meaning| {
        const hash = semanticHash(payload);
        var remaining: usize = @intCast(@min(@max(inst.a, 1), 32));
        const vec = generateWordVec(payload);
        const slot_usage_hint = meaning.slotUsageHint();
        const lock_state = if (meaning.slotCount()) |slot_count|
            computeEtchLockState(ctx.control, hash, slot_count)
        else
            EtchLockState{
                .hash_locked = ctx.control.isHashLocked(hash),
                .slot_lock_mask = 0,
            };
        var total_drift: u64 = 0;
        var inserted_new_slot = false;
        while (remaining > 0) : (remaining -= 1) {
            const result = meaning.applyGravity(hash, vec, lock_state.hash_locked, lock_state.slot_lock_mask);
            total_drift += result.drift;
            inserted_new_slot = inserted_new_slot or result.inserted_new_slot;
        }
        const expectation = meaning.collapseToBinary(hash);
        const energy: u16 = if (ctx.soul) |soul|
            vsa.calculateResonance(expectation, soul.concept)
        else
            vsa.calculateResonance(expectation, vec);
        ctx.control.recordEtch(hash, energy, total_drift, inserted_new_slot, slot_usage_hint);
        sys.print("[SIGIL VM] ETCH {s} weight={d}\n", .{ payload, inst.a });
    }
}

fn computeEtchLockState(control: *sigil_runtime.ControlPlane, word_hash: u64, num_slots: u32) EtchLockState {
    var state = EtchLockState{
        .hash_locked = control.isHashLocked(word_hash),
        .slot_lock_mask = 0,
    };
    if (state.hash_locked or num_slots == 0) return state;

    const addr = vsa.computeSudhAddress(@as(u32, @truncate(word_hash)), word_hash, num_slots);
    var p: u32 = 0;
    while (p < vsa.SUDH_CPU_PROBES) : (p += 1) {
        const slot = addr.probe(p, num_slots);
        if (slot >= num_slots) break;
        if (control.isSlotLocked(slot)) {
            state.slot_lock_mask |= @as(u32, 1) << @as(u5, @intCast(p));
        }
    }
    return state;
}

fn execVoid(ctx: *Context, program: *const sigil_core.Program, inst: sigil_core.Instruction) void {
    const payload = program.strings[inst.string_index];
    const hash = semanticHash(payload);
    ctx.control.lockHash(hash) catch {};
    if (ctx.meaning) |meaning| {
        meaning.hardLockUniversalSigil(hash, 0);
    }
    sys.print("[SIGIL VM] VOID {s}\n", .{payload});
}

fn semanticHash(text: []const u8) u64 {
    return ghost_state.wyhash(ghost_state.GENESIS_SEED, std.hash.Wyhash.hash(0, text));
}

fn generateWordVec(word: []const u8) vsa.HyperVector {
    var result: vsa.HyperVector = @splat(0);
    for (word) |c| result ^= vsa.generate(c);
    return result;
}

fn countUsedTags(tags: []const u64) usize {
    var used: usize = 0;
    for (tags) |tag| {
        if (tag != 0) used += 1;
    }
    return used;
}
