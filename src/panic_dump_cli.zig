const std = @import("std");
const core = @import("ghost_core");
const panic_dump = core.panic_dump;
const sys = core.sys;

const Command = enum {
    read,
    replay,
};

const RenderMode = enum {
    summary,
    json,
    report,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        printUsage();
        return error.InvalidArguments;
    }

    const command = parseCommand(args[1]) orelse {
        printUsage();
        return error.InvalidArguments;
    };

    var render_mode: RenderMode = if (command == .replay) .summary else .summary;
    var allow_external = true;
    var path: ?[]const u8 = null;

    for (args[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--render=")) {
            render_mode = parseRenderMode(arg["--render=".len..]) orelse {
                printUsage();
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--no-external")) {
            allow_external = false;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (path == null) {
            path = arg;
        } else {
            printUsage();
            return error.InvalidArguments;
        }
    }

    if (path == null) {
        printUsage();
        return error.InvalidArguments;
    }

    var dump = try panic_dump.readFile(allocator, path.?);
    defer dump.deinit();

    switch (command) {
        .read => {
            if (render_mode == .report) {
                printUsage();
                return error.InvalidArguments;
            }
            const rendered = switch (render_mode) {
                .summary => try panic_dump.renderSummary(allocator, &dump, null),
                .json => try panic_dump.renderJson(allocator, &dump, null),
                .report => unreachable,
            };
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .replay => {
            var inspection = try panic_dump.inspectReplay(allocator, &dump, allow_external);
            defer inspection.deinit(allocator);

            const rendered = switch (render_mode) {
                .summary => try panic_dump.renderSummary(allocator, &dump, &inspection),
                .json => try panic_dump.renderJson(allocator, &dump, &inspection),
                .report => try panic_dump.renderReplayReport(allocator, &dump, &inspection),
            };
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
    }
}

fn parseCommand(text: []const u8) ?Command {
    if (std.mem.eql(u8, text, "read")) return .read;
    if (std.mem.eql(u8, text, "replay")) return .replay;
    return null;
}

fn parseRenderMode(text: []const u8) ?RenderMode {
    if (std.mem.eql(u8, text, "summary")) return .summary;
    if (std.mem.eql(u8, text, "json")) return .json;
    if (std.mem.eql(u8, text, "report")) return .report;
    return null;
}

fn printUsage() void {
    sys.print(
        "Usage: ghost_panic_dump <read|replay> <dump-path> [--render=summary|json|report] [--no-external]\n",
        .{},
    );
}
