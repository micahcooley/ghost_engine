const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const intent_grounding = core.intent_grounding;

pub fn main() !void {
    mainImpl() catch |err| switch (err) {
        error.InvalidArguments => {
            std.debug.print("ghost_intent_grounding: invalid arguments\nUse --help for usage.\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };
}

fn mainImpl() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return error.InvalidArguments;
    }

    var context_target: ?[]const u8 = null;
    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--context-target=")) {
            const value = arg["--context-target=".len..];
            if (value.len > 0) context_target = value;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            try positionals.append(arg);
        }
    }

    if (positionals.items.len == 0) {
        printUsage();
        return error.InvalidArguments;
    }

    const text = if (positionals.items.len == 1)
        positionals.items[0]
    else
        try std.mem.join(allocator, " ", positionals.items);
    defer if (positionals.items.len != 1) allocator.free(text);

    var grounded = try intent_grounding.ground(allocator, text, .{
        .context_target = context_target,
    });
    defer grounded.deinit();

    const rendered = try intent_grounding.renderJson(allocator, &grounded);
    defer allocator.free(rendered);
    sys.print("{s}\n", .{rendered});
}

fn printUsage() void {
    sys.print(
        "Usage: ghost_intent_grounding <natural-language request> [--context-target=spec]\n",
        .{},
    );
}
