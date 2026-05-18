const std = @import("std");
const sovereign = @import("sovereign");
const void_eng = @import("void");

// --- GHOST CHAT: THE STEERING WHEEL ---

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var engine = sovereign.SovereignEngine.init(aa, 0x12345);
    defer engine.deinit();

    try stdout.writeAll("### GHOST SOVEREIGN CHAT INTERFACE ###\n");
    try stdout.writeAll("Type 'exit' to terminate.\n\n");

    var buf: [1024]u8 = undefined;
    while (true) {
        try stdout.writeAll("Intent > ");
        if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
            if (std.mem.eql(u8, input, "exit")) break;
            try engine.ingest(input);
            try stdout.writeAll("[Ghost] Resolution achieved. Manifold updated.\n");
        }
    }
}