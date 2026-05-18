const std = @import("std");
const aetheric = @import("aetheric.zig");

// THE GHOST AETHERIC ADAPTER
// The non-binary brain core.

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();

    var message: ?[]const u8 = null;
    var is_json = false;
    var corpus_path: ?[]const u8 = "/usr/share/dict/words";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (std.mem.startsWith(u8, arg, "--corpus=")) {
            corpus_path = arg["--corpus=".len..];
        } else if (std.mem.eql(u8, arg, "--render=json")) {
            is_json = true;
        }
    }

    const input = message orelse {
        try stderr.writeAll("Error: --message is required\n");
        std.process.exit(1);
    };

    var engine = try aetheric.AethericCore.init(aa);
    defer engine.deinit();

    // 1. AETHERIC INGESTION
    var dict = std.ArrayList([]const u8).init(aa);
    const file = std.fs.cwd().openFile(corpus_path.?, .{}) catch null;
    if (file) |f| {
        defer f.close();
        const content = try f.readToEndAlloc(aa, 10 * 1024 * 1024);
        try engine.ingest(content);
        
        var it = std.mem.tokenizeAny(u8, content, " \t\n\r");
        while (it.next()) |word| {
            if (word.len > 1) try dict.append(word);
        }
    } else {
        const fallback = "aetheric wave harmonic interference resonance field spontaneous alien transcend bit logic";
        try engine.ingest(fallback);
        var it = std.mem.tokenizeAny(u8, fallback, " ");
        while (it.next()) |word| try dict.append(word);
    }

    if (is_json) try stdout.writeAll("{ \"type\": \"aetheric_resonance\", \"result\": \"") else try stdout.writeAll("[Ghost Aetheric Resonance]\n");
    
    // 2. RESONATE INTENT
    try engine.resolve(input, dict.items, stdout);
    
    if (is_json) try stdout.writeAll("\" }\n");
}