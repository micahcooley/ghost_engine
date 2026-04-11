const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../../../../src/sys.zig");
const ghost_state = @import("../../../../src/ghost_state.zig");
const vsa = @import("../../../../src/vsa_core.zig");
const vsa_vulkan = @import("../../../../src/vsa_vulkan.zig");

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

pub const Anchor = extern struct {
    magic: u32 = 0x616E6348,
    version: u32 = 27,
    file_index: u32,
    file_offset: u64,
    active_context_hash: u64,
    sentence_count: u64,
    total_bytes: u64,
    syntax: [128]u8 align(1),
    phrase: [128]u8 align(1),
    concept: [128]u8 align(1),
    global: [128]u8 align(1),
    sentence_pool: [128]u8 align(1),
    fractal_state: [128]u8 align(1),
    spell_vector: [128]u8 align(1),
    lexical_rotor: u64,
    last_energy: u16,
    checksum: u64,
};

const CORPUS_FILES = [_][]const u8{
    "corpus/wikitext_train.txt",
    "corpus/wikitext_validation.txt",
    "corpus/wikitext_test.txt",
    "corpus/The GCIDE.txt",
    "corpus/Moby dick.txt",
    "corpus/a tale of two cities.txt",
    "corpus/shakespeare.txt",
    "corpus/The Adventures of Huckleberry Finn.txt",
};

pub fn main() void {
    _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    main_wrapped() catch |err| {
        var buf: [128]u8 = undefined;
        sys.printOut(std.fmt.bufPrint(&buf, "\n[FATAL ERROR] {any}\n", .{err}) catch "Fatal Error\n");
        if (global_vk_engine) |vk| vk.deinit();
        sys.exit(1);
    };
}

fn main_wrapped() !void {
    const allocator = std.heap.page_allocator;
    var soul = ghost_state.GhostSoul.init(allocator);
    var mapped = try sys.createMappedFile("data/unified_lattice.bin", ghost_state.UNIFIED_SIZE_BYTES);
    var vk_engine = try vsa_vulkan.VulkanEngine.init(allocator);
    global_vk_engine = &vk_engine;
    var meaning_matrix = vsa.MeaningMatrix{ .data = vk_engine.mapped_matrix.?[0..(vk_engine.matrix_slots * 1024)], .tags = vk_engine.mapped_tags.?[0..vk_engine.matrix_slots] };
    soul.meaning_matrix = &meaning_matrix;

    if (sys.openForRead("data/semantic_monolith.bin")) |hMM| {
        _ = try sys.readAll(hMM, meaning_matrix.data);
        sys.closeFile(hMM);
    }
    
    // Training loop simplified for restoration
    sys.printOut("Ghost Trainer V27 Ready.\n");
    mapped.unmap();
}
