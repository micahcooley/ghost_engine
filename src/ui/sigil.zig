const std = @import("std");
const ghost_core = @import("ghost_core");
const ipc = ghost_core.ipc_protocol;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "status")) {
        const payload = try ipc.renderStatusRequest(allocator);
        defer allocator.free(payload);
        try sendOnce(allocator, payload);
        return;
    }
    if (std.mem.eql(u8, cmd, "inject")) {
        if (args.len < 3) return error.MissingSemanticIntent;
        const intent = try joinArgs(allocator, args[2..]);
        defer allocator.free(intent);
        const payload = try ipc.renderInjectRequest(allocator, intent);
        defer allocator.free(payload);
        try sendOnce(allocator, payload);
        return;
    }
    if (std.mem.eql(u8, cmd, "watch")) {
        try watch(allocator);
        return;
    }
    if (std.mem.eql(u8, cmd, "commit")) {
        if (args.len < 3) return error.MissingRuneRef;
        const payload = try ipc.renderCommitRequest(allocator, args[2]);
        defer allocator.free(payload);
        try sendOnce(allocator, payload);
        return;
    }
    if (std.mem.eql(u8, cmd, "reload-plugin")) {
        if (args.len < 3) return error.MissingPluginPath;
        const payload = try ipc.renderReloadPluginRequest(allocator, args[2]);
        defer allocator.free(payload);
        try sendOnce(allocator, payload);
        return;
    }

    try printUsage();
    return error.InvalidSigilCommand;
}

fn sendOnce(allocator: std.mem.Allocator, payload: []const u8) !void {
    const response = try ipc.request(allocator, payload);
    defer allocator.free(response);
    try std.io.getStdOut().writer().print("{s}\n", .{response});
}

fn watch(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    while (true) {
        const payload = try ipc.renderWatchRequest(allocator);
        defer allocator.free(payload);
        const response = ipc.request(allocator, payload) catch |err| {
            try stdout.print("sigil watch disconnected: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        std.time.sleep(std.time.ns_per_s);
    }
}

fn joinArgs(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (parts, 0..) |part, idx| {
        if (idx != 0) try out.append(' ');
        try out.appendSlice(part);
    }
    return out.toOwnedSlice();
}

fn printUsage() !void {
    try std.io.getStdErr().writer().writeAll(
        \\Usage: sigil <command>
        \\
        \\Commands:
        \\  status                 Show daemon telemetry and oracle state
        \\  inject <intent>         Submit a semantic intent to the Wingman generator
        \\  commit <rune-ref>       Archive a verified rune/plugin into a binary knowledge pack
        \\  reload-plugin <path>    Ask the daemon to validate C ABI plugin symbols
        \\  watch                  Poll invention logs until interrupted
        \\
    );
}
