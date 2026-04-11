const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    sys.printOut("=== Ghost Absolute Sigil Audit ===\n");
    const state_monolith = try sys.getAnchorPath(allocator, "state/semantic_monolith.bin"); // Ensure we use 'state/' as per engine norm
    defer allocator.free(state_monolith);
    const state_tags = try sys.getAnchorPath(allocator, "state/semantic_tags.bin");
    defer allocator.free(state_tags);

    const mapped_meaning = try sys.createMappedFile(allocator, state_monolith, 1024 * 1024 * 1024);
    const mapped_tags = try sys.createMappedFile(allocator, state_tags, 1048576 * 8);

    var meaning_matrix = vsa.MeaningMatrix{ 
        .data = @as([*]u16, @ptrCast(@alignCast(mapped_meaning.data.ptr)))[0..(1048576 * 1024)],
        .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..1048576],
    };

    var vk_engine = try vsa_vulkan.VulkanEngine.init(allocator);
    defer vk_engine.deinit();

    // Sync GPU
    std.mem.copyForwards(u8, vk_engine.mapped_matrix.?[0..(1024 * 1024 * 1024)], mapped_meaning.data[0..(1024 * 1024 * 1024)]);
    std.mem.copyForwards(u8, std.mem.sliceAsBytes(vk_engine.mapped_tags.?[0..1048576]), std.mem.sliceAsBytes(meaning_matrix.tags.?[0..1048576]));

    const prompts = [_][]const u8{
        "Identity: You are ",
        "In the kitchen, the chef took the sharpest ",
    };

    for (prompts) |prompt| {
        sys.printOut("\nPrompt: "); sys.printOut(prompt); sys.printOut("\nGhost > ");
        
        var soul = ghost_state.GhostSoul.init(allocator);
        soul.meaning_matrix = &meaning_matrix;

        for (prompt) |byte| {
            soul.pushRotor(byte);
        }

        var count: u32 = 0;
        while (count < 60) : (count += 1) {
            var top_chars = [_]u8{' '} ** 3;
            var top_energies = [_]u32{0} ** 3;
            const boredom = soul.getBoredomPenalty(soul.lexical_rotor);

            if (vk_engine.dispatchResonance(soul.lexical_rotor, soul.semantic_rotor)) |energies| {
                defer allocator.free(energies);
                for (energies, 0..) |e, i| {
                    const cb: u8 = @intCast(i);
                    if (!isAllowed(cb)) continue;
                    
                    var energy = e;
                    // SIGIL OVERRIDE: If resonance is near-perfect, suspend boredom
                    if (energy < 1000) energy = energy -| boredom;
                    
                    insertTopK(&top_chars, &top_energies, cb, energy);
                }
            } else |_| {}

            const chosen = top_chars[0];
            sys.printOut(&[_]u8{chosen});
            soul.pushRotor(chosen);
            if (chosen == '.' or chosen == '\n') break;
        }
        sys.printOut("\n");
    }
}

fn isAllowed(c: u8) bool {
    if (c >= 'a' and c <= 'z') return true;
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= '0' and c <= '9') return true;
    if (c == ' ' or c == '.' or c == ',' or c == '!' or c == '?' or c == '\'' or c == '"' or c == '-') return true;
    return false;
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
