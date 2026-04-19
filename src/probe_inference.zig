const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const mc = core.inference;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io;

    const silo_root = try sys.getSiloRoot(allocator);
    sys.print("Silo Root: {s}\n", .{silo_root});

    const vk_engine = try vsa_vulkan.initRuntime(allocator, init.io);
    defer vsa_vulkan.deinitRuntime();

    // Upload CPU-trained data to GPU buffers
    const mapped_meaning = try sys.createMappedFile(allocator, "state/semantic_monolith.bin", @sizeOf(u32) * 512 * 1024 * 1024);
    const gpu_matrix = vk_engine.getMatrixData();
    const src_ptr: [*]const u32 = @ptrCast(@alignCast(mapped_meaning.data.ptr));
    const src_len = mapped_meaning.data.len / 4;
    const copy_len = @min(gpu_matrix.len, src_len);
    @memcpy(gpu_matrix[0..copy_len], src_ptr[0..copy_len]);

    var meaning_matrix = vsa.MeaningMatrix{
        .data = gpu_matrix,
        .tags = null
    };

    var soul = try allocator.create(ghost_state.GhostSoul);
    soul.* = try ghost_state.GhostSoul.init(allocator);
    defer allocator.destroy(soul);
    defer soul.deinit();

    soul.meaning_matrix = &meaning_matrix;

    const prompt = "The Ghost Engine is ";
    sys.print("Prompting: {s}\n", .{prompt});
    for (prompt) |rune| _ = try soul.absorb(vsa.generate(rune), rune, null);

    const beam = mc.BeamSearchPool.init(allocator, vk_engine, &meaning_matrix);

    sys.print("Response: ", .{});
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        // Fast-path: get top-5 from GPU resonance
        const energies = try vk_engine.dispatchResonance(soul.lexical_rotor, soul.semantic_rotor);
        if (energies.len == 0) break;

        var top_chars: [5]u32 = [_]u32{0} ** 5;
        var top_energies: [5]u32 = [_]u32{0} ** 5;
        for (energies, 0..) |raw_e, idx| {
            const cb: u32 = @intCast(idx);
            if (cb < 32 or cb > 126) continue;
            insertTop5(&top_chars, &top_energies, cb, raw_e);
        }

        // Debug: show top-3 candidates
        if (i < 5) {
            sys.print("\n  [MC-{d}] top3: '{c}'({d}) '{c}'({d}) '{c}'({d})", .{
                i, @as(u8, @intCast(top_chars[0])), top_energies[0],
                @as(u8, @intCast(top_chars[1])), top_energies[1],
                @as(u8, @intCast(top_chars[2])), top_energies[2],
            });
        }

        // Beam search picks the winner
        const winner_idx = beam.resolve(soul, &top_chars, &top_energies) catch 0;
        const chosen = top_chars[winner_idx];
        sys.print("\n  -> chosen: '{c}' (lane {d})\n", .{@as(u8, @intCast(chosen)), winner_idx});
        _ = try soul.absorb(vsa.generate(@intCast(chosen)), @intCast(chosen), null);
        if (chosen == '.' or chosen == '\n') break;
    }
    sys.print("\n", .{});
}

fn insertTop5(chars: *[5]u32, energies: *[5]u32, candidate: u32, energy: u32) void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (energy > energies[i]) {
            var j: usize = 4;
            while (j > i) : (j -= 1) {
                chars[j] = chars[j - 1];
                energies[j] = energies[j - 1];
            }
            chars[i] = candidate;
            energies[i] = energy;
            return;
        }
    }
}
