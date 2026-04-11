const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const vsa_vulkan = core.vsa_vulkan;
const engine_logic = core.engine;

pub fn main() !void {
    sys.printOut("\nGhost V22: Symmetric Bitwise Intelligence Engine (Linux x86_64)\n");
    const allocator = std.heap.page_allocator;

    sys.printOut("[MONOLITH] Mapping Cortex...\n");
    // Task 2: Bulletproof Silicon - Comptime alignment check
    comptime {
        const lattice_align = @alignOf(ghost_state.UnifiedLattice);
        if (lattice_align > 65536) {
            @compileError("UnifiedLattice alignment exceeds expected OS page alignment (64KB)");
        }
    }
    const mapped_lattice = try sys.createMappedFile("state/unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    const lattice: *ghost_state.UnifiedLattice = @as(*ghost_state.UnifiedLattice, @ptrCast(@alignCast(mapped_lattice.data.ptr)));

    sys.printOut("[MEANING] Mapping Hippocampus...\n");
    const mapped_meaning = try sys.createMappedFile("state/semantic_monolith.bin", 1024*1024*1024);
    const mapped_tags = try sys.createMappedFile("state/semantic_tags.bin", 1048576 * 8);
    var meaning_matrix = vsa.MeaningMatrix{ 
        .data = @as([*]u16, @ptrCast(@alignCast(mapped_meaning.data.ptr)))[0..(1024*1024*512)], 
        .tags = @as([*]u64, @ptrCast(@alignCast(mapped_tags.data.ptr)))[0..1048576] 
    };

    sys.printOut("[VULKAN] Initializing...\n");
    var vk_engine_opt: ?vsa_vulkan.VulkanEngine = null;
    if (vsa_vulkan.VulkanEngine.init(allocator)) |init_engine| {
        vk_engine_opt = init_engine;
        // Copy data to GPU if matrix is mapped
        if (vk_engine_opt.?.mapped_matrix) |mm| {
            std.mem.copyForwards(u16, @as([*]u16, @ptrCast(@alignCast(mm)))[0..(1024*1024*512)], meaning_matrix.data);
        }
    } else |_| sys.printOut("[VULKAN] Failed to initialize GPU resonance. Falling back to CPU.\n");

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
            .is_live = sys.isTrainerActive(), 
            .inventory = [_]u8{0} ** 128, 
            .inv_cursor = 0, 
            .vk_engine = if (vk_engine_opt) |*ve| ve else null 
        };

        // Task 3: Safety Valve Generation
        var tokens_generated: u32 = 0;
        const MAX_TOKENS = 2048;

        while (tokens_generated < MAX_TOKENS) : (tokens_generated += 1) {
            const chosen = engine.resolveTopology() orelse break; 
            sys.printOut(&[_]u8{chosen});
            engine.inventory[engine.inv_cursor] = chosen; 
            engine.inv_cursor = (engine.inv_cursor + 1) % 128;
            _ = try soul.absorb(vsa.generate(chosen), chosen, null);
            
            // Paragraph break or Concept Drift limit
            if (soul.last_boundary == .paragraph or vsa.hammingDistance(soul.concept, generation_start_concept) > 450) break;
        }
        if (tokens_generated == MAX_TOKENS) {
            sys.printOut("\n[SAFETY] Concept Drift Limit: Forced Break.\n");
        }
        sys.printOut("\n\n");
    }
}
