const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const engine_logic = core.engine;

const builtin = @import("builtin");
const WINAPI = if (builtin.os.tag == .windows) std.builtin.CallingConvention.winapi else .C;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn(u32) callconv(WINAPI) i32, add: i32) callconv(WINAPI) i32;

var global_vk_engine: ?*vsa_vulkan.VulkanEngine = null;

fn ctrlHandler(ctrl_type: u32) callconv(WINAPI) i32 {
    if (ctrl_type == 0) {
        sys.printOut("\n[SIGNAL] Interrupt detected. Releasing Silicon...\n");
        if (global_vk_engine) |vk| vk.deinit();
        sys.exit(0);
    }
    return 1;
}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    }

    sys.printOut("\nGhost V22: Symmetric Bitwise Intelligence Engine (Windows x64)\n");
    const allocator = std.heap.page_allocator;

    sys.printOut("[MONOLITH] Mapping Cortex...\n");
    const mapped_lattice = try sys.createMappedFile(allocator, "state/unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    if (mapped_lattice.data.len < ghost_state.UNIFIED_SIZE_BYTES) return error.LatticeMapFailed;

    const lattice: *ghost_state.UnifiedLattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped_lattice.data.ptr)));

    sys.printOut("[MEANING] Mapping Hippocampus...\n");
    const mapped_meaning = try sys.createMappedFile(allocator, "state/semantic_monolith.bin", 1024*1024*1024);
    const mapped_tags = try sys.createMappedFile(allocator, "state/semantic_tags.bin", 1048576 * 8);

    var meaning_matrix = vsa.MeaningMatrix{ 
        .data = @as([*]u16, @ptrCast(@alignCast(mapped_meaning.data.ptr)))[0..(1024*1024*512)], 
        .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..1048576] 
    };

    sys.printOut("[VULKAN] Initializing Sovereign Compute...\n");
    var active_compute: ?*const core.compute_api.ComputeApi = null;
    if (vsa_vulkan.GHOST_COMPUTE_PLUGIN.init(allocator)) |compute| {
        active_compute = compute;
        sys.printOut("[COMPUTE] ");
        sys.printOut(compute.name);
        sys.printOut(" active.\n");
    } else |_| sys.printOut("[VULKAN] Failed.\n");


    var soul = ghost_state.GhostSoul.init(allocator); 
    soul.meaning_matrix = &meaning_matrix;

    while (true) {
        sys.printOut("User > "); 
        var input_buf: [1024]u8 = undefined;
        const raw_line = sys.readStdin(&input_buf) catch break; 
        if (raw_line.len == 0) break;
        const prompt = std.mem.trim(u8, raw_line, " \r\n"); 
        if (prompt.len == 0) continue;

        for (prompt) |byte| _ = try soul.absorb(vsa.generate(byte), byte, null);

        sys.printOut("Ghost > "); 
        const generation_start_concept = soul.concept;
        var engine = engine_logic.SingularityEngine{ 
            .lattice = lattice, 
            .meaning = &meaning_matrix, 
            .soul = &soul, 
            .canvas = ghost_state.MesoLattice.initText(), 
            .is_live = sys.isTrainerActive(allocator), 
            .inventory = [_]u8{0} ** 128, 
            .inv_cursor = 0, 
            .compute = active_compute 
        };



        while (true) {
            const chosen = engine.resolveTopology() orelse break; 
            sys.printOut(&[_]u8{chosen});
            engine.inventory[engine.inv_cursor] = chosen; 
            engine.inv_cursor = (engine.inv_cursor + 1) % 128;
            _ = try soul.absorb(vsa.generate(chosen), chosen, null);
            if (soul.last_boundary == .paragraph or vsa.hammingDistance(soul.concept, generation_start_concept) > 450) break;
        }
        sys.printOut("\n\n");
    }
}
