const std = @import("std");
const config = @import("config.zig");
const sigil_core = @import("sigil_core.zig");
const sigil_runtime = @import("sigil_runtime.zig");
const ghost_state = @import("ghost_state.zig");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    control: *sigil_runtime.ControlPlane,
    meaning: ?*vsa.MeaningMatrix = null,
    soul: ?*ghost_state.GhostSoul = null,
    lattice: ?*ghost_state.UnifiedLattice = null,
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
            sys.print("[SIGIL VM] MOOD {s} => saturation={d} boredom=({d},{d})\n", .{
                mood_name,
                ctx.control.saturation_bonus,
                ctx.control.boredom_penalty_high,
                ctx.control.boredom_penalty_low,
            });
        },
        .integer => {
            const tuned = @as(u32, @intCast(@max(inst.a, 0)));
            ctx.control.saturation_bonus = tuned;
            sys.print("[SIGIL VM] MOOD saturation bonus set to {d}\n", .{tuned});
        },
        else => {},
    }
}

fn execLoom(ctx: *Context, inst: sigil_core.Instruction) void {
    const command = @as(sigil_core.LoomCommand, @enumFromInt(@as(u8, @intCast(@max(inst.a, 0)))));
    switch (command) {
        .vulkan_init => {
            ctx.control.enable_vulkan = true;
            ctx.control.force_cpu_only = false;
            sys.printOut("[SIGIL VM] LOOM VULKAN_INIT\n");
        },
        .cpu_only => {
            ctx.control.enable_vulkan = false;
            ctx.control.force_cpu_only = true;
            sys.printOut("[SIGIL VM] LOOM CPU_ONLY\n");
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
        ctx.control.last_scan = .{ .hash = 0, .energy = @intCast(config.TOTAL_STATE_BYTES / 1024 / 1024) };
        return;
    }

    if (ctx.meaning) |meaning| {
        const hash = semanticHash(target);
        const vec = meaning.collapseToBinary(hash);
        const energy: u32 = if (ctx.soul) |soul|
            vsa.calculateResonance(vec, soul.concept)
        else
            vsa.calculateResonance(vec, @splat(@as(u64, 0)));
        ctx.control.last_scan = .{ .hash = hash, .energy = energy };
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
        while (remaining > 0) : (remaining -= 1) {
            _ = meaning.applyGravity(hash, vec);
        }
        sys.print("[SIGIL VM] ETCH {s} weight={d}\n", .{ payload, inst.a });
    }
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
