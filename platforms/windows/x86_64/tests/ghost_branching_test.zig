const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    sys.printOut("--- Ghost Branching Telepathy Test ---\n");

    const mapped_lattice = try sys.createMappedFile("unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    const lattice: *ghost_state.UnifiedLattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped_lattice.data.ptr)));

    const mapped_meaning = try sys.createMappedFile("semantic_monolith.bin", 1024 * 1024 * 1024);
    const mapped_tags = try sys.createMappedFile("semantic_tags.bin", 1048576 * 8);
    var meaning_matrix = vsa.MeaningMatrix{ 
        .data = mapped_meaning.data,
        .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..1048576],
    };

    var vk_engine_opt: ?vsa_vulkan.VulkanEngine = null;
    if (vsa_vulkan.VulkanEngine.init(allocator)) |init_engine| {
        vk_engine_opt = init_engine;
        sys.printOut("[VULKAN] Silicon Handshake Successful.\n");
        if (vk_engine_opt.?.mapped_matrix) |mm| {
            std.mem.copyForwards(u8, mm[0..(1024 * 1024 * 1024)], meaning_matrix.data[0..(1024 * 1024 * 1024)]);
        }
        if (vk_engine_opt.?.mapped_tags) |tags| {
            std.mem.copyForwards(u8, std.mem.sliceAsBytes(tags[0..1048576]), std.mem.sliceAsBytes(meaning_matrix.tags.?[0..1048576]));
        }
    } else |_| {
        sys.printOut("[VULKAN] Init Failed. Falling back to CPU.\n");
    }

    var soul = ghost_state.GhostSoul.init(allocator);
    soul.meaning_matrix = &meaning_matrix;

    const prompt = "The history of ";
    sys.printOut("Prompt: "); sys.printOut(prompt); sys.printOut("\nGhost > ");

    for (prompt) |byte| {
        const ch_vec = vsa.generate(byte);
        _ = try soul.absorb(ch_vec, byte, null);
    }

    var count: u32 = 0;
    while (count < 100) : (count += 1) {
        const cms_key = soul.rotorKey();
        var top_chars = [_]u8{' '} ** 3;
        var top_energies = [_]u32{0} ** 3;

        // Apply Repetition/Boredom Penalties
        const boredom = soul.getBoredomPenalty(soul.lexical_rotor);

        var gpu_done = false;
        if (vk_engine_opt) |*vk| {
            if (vk.dispatchResonance(soul.lexical_rotor)) |energies| {
                defer allocator.free(energies);
                for (energies, 0..) |e, i| {
                    var energy = e;
                    energy = energy -| boredom;
                    insertTopK(&top_chars, &top_energies, @intCast(i), energy);
                }
                gpu_done = true;
            } else |_| {}
        }

        if (!gpu_done) {
            var i: u16 = 0;
            while (i < 256) : (i += 1) {
                const cb: u8 = @intCast(i);
                var energy = @as(u32, lattice.read(cms_key, cb, ghost_state.DOMAIN_SYNTAX));
                const expectation = meaning_matrix.collapseToBinary(soul.lexical_rotor);
                energy += vsa.calculateResonance(expectation, vsa.generate(cb));
                energy = energy -| boredom;
                insertTopK(&top_chars, &top_energies, cb, energy);
            }
        }

        const chosen = top_chars[0];
        var dbuf: [256]u8 = undefined;
        sys.printOut(std.fmt.bufPrint(&dbuf, "\nStep {d}: Chosen '{c}' (E:{d}) | Top 2: '{c}' (E:{d}) | Top 3: '{c}' (E:{d})", .{
            count,
            if (top_chars[0] >= 32 and top_chars[0] <= 126) top_chars[0] else @as(u8, '?'), top_energies[0],
            if (top_chars[1] >= 32 and top_chars[1] <= 126) top_chars[1] else @as(u8, '?'), top_energies[1],
            if (top_chars[2] >= 32 and top_chars[2] <= 126) top_chars[2] else @as(u8, '?'), top_energies[2],
        }) catch "");
        
        const ch_vec = vsa.generate(chosen);
        _ = try soul.absorb(ch_vec, chosen, null);
    }
    sys.printOut("\n\n");
}

fn insertTopK(chars: *[3]u8, energies: *[3]u32, candidate: u8, energy: u32) void {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (energy > energies[i]) {
            var j: usize = 2;
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
