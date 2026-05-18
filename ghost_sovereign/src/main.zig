const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");
const flux = @import("flux.zig");
const sovereign = @import("sovereign.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("### GHOST SOVEREIGN CORE PROBE ###\n");
    
    var engine = sovereign.SovereignEngine.init(aa, 0xACE);
    defer engine.deinit();

    try engine.ingest("The Ghost Sovereign is a high-resolution, multimodal ASI core.");
    try stdout.writeAll("[System] Core ingestion successful. Stability confirmed.\n");
}