const std = @import("std");
const vsa_core = @import("vsa_core.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const ghost_state = @import("ghost_state.zig");
const sys = @import("sys.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    sys.printOut("=== Multiscale Resonance Audit ===\n");

    var vk_engine = try vsa_vulkan.VulkanEngine.init(allocator);
    defer vk_engine.deinit();

    if (sys.openForRead("semantic_monolith.bin") catch null) |hMM| {
        defer sys.closeFile(hMM);
        _ = try sys.readAll(hMM, vk_engine.mapped_matrix.?[0..(1024*1024*1024)]);
        sys.printOut("Matrix Loaded.\n");
    }
    if (sys.openForRead("semantic_tags.bin") catch null) |hTags| {
        defer sys.closeFile(hTags);
        _ = try sys.readAll(hTags, std.mem.sliceAsBytes(vk_engine.mapped_tags.?[0..1048576]));
        sys.printOut("Tags Loaded.\n");
    }
    
    const targets = [_][]const u8{ "the " };
    var buf: [256]u8 = undefined;

    for (targets) |target| {
        var lex_rotor: u64 = ghost_state.FNV_OFFSET_BASIS;
        var sem_rotor: u64 = ghost_state.FNV_OFFSET_BASIS;
        for (target) |ch| {
            lex_rotor = (lex_rotor ^ @as(u64, ch)) *% ghost_state.FNV_PRIME;
            sem_rotor = (sem_rotor ^ @as(u64, ch)) *% ghost_state.FNV_PRIME;
            if (ch == ' ') sem_rotor = ghost_state.FNV_OFFSET_BASIS;
        }

        const energies = try vk_engine.dispatchResonance(lex_rotor, sem_rotor);
        defer allocator.free(energies);

        sys.printOut(std.fmt.bufPrint(&buf, "\nMultiscale Predictions for '{s}':\n", .{target}) catch "");
        var top_chars = [_]u8{0} ** 5;
        var top_energies = [_]u32{0} ** 5;

        for (energies, 0..) |e, i| {
            const cb: u8 = @intCast(i);
            var cur_e = e;
            var cur_cb = cb;
            for (0..5) |j| {
                if (cur_e > top_energies[j]) {
                    const tmp_e = top_energies[j];
                    const tmp_cb = top_chars[j];
                    top_energies[j] = cur_e;
                    top_chars[j] = cur_cb;
                    cur_e = tmp_e;
                    cur_cb = tmp_cb;
                }
            }
        }

        for (0..5) |i| {
            const c_disp = if (top_chars[i] >= 32 and top_chars[i] <= 126) top_chars[i] else @as(u8, '?');
            sys.printOut(std.fmt.bufPrint(&buf, "{d}: '{c}' (0x{X}) - Energy {d}\n", .{i+1, c_disp, top_chars[i], top_energies[i]}) catch "");
        }
    }
}
