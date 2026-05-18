const std = @import("std");
const void_eng = @import("void");
const flame = @import("flame");

// --- GHOST VOID CLI ADAPTER ---

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next(); // Skip binary name

    var command: ?[]const u8 = null;
    var message: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (command == null) {
            command = arg;
        }
    }

    if (command == null or message == null) {
        try stderr.writeAll("Usage: ghost_void <command> --message=<input>\n");
        std.process.exit(1);
    }

    var engine = void_eng.VoidEngine.init(0x145F2EA61D0202D9);
    engine.shapeTextPressure(0xACE, message.?);

    if (std.mem.eql(u8, command.?, "invent")) {
        try stdout.writeAll("[Ghost Void Phase-Collapse]\n");
        // We use the hyper_adapter's logic for invention or just dummy for now
        // This is a placeholder for the actual complex logic.
        try stdout.print("Result: Resolution achieved for '{s}'\n", .{message.?});
    }
}