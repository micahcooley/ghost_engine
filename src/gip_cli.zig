// ──────────────────────────────────────────────────────────────────────────
// ghost_gip — CLI testing tool for GIP v0.1
//
// Usage:
//   ghost_gip protocol.describe
//   ghost_gip capabilities.describe
//   ghost_gip engine.status
//   ghost_gip artifact.read --path src/gip.zig --workspace /path/to/project
//   ghost_gip artifact.list --path src/ --workspace /path/to/project
//   ghost_gip --json '{"gipVersion":"gip.v0.1","kind":"protocol.describe"}'
//   echo '{"gipVersion":"gip.v0.1","kind":"engine.status"}' | ghost_gip --stdin
//
// All output is JSON on stdout.
// ──────────────────────────────────────────────────────────────────────────

const std = @import("std");
const ghost_core = @import("ghost_core");
const gip = ghost_core.gip;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    // Parse arguments
    var kind_text: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var json_input: ?[]const u8 = null;
    var use_stdin = false;
    var request_id: ?[]const u8 = null;

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "-w")) {
            idx += 1;
            if (idx < args.len) workspace = args[idx];
        } else if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
            idx += 1;
            if (idx < args.len) path = args[idx];
        } else if (std.mem.eql(u8, arg, "--json")) {
            idx += 1;
            if (idx < args.len) json_input = args[idx];
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "--request-id")) {
            idx += 1;
            if (idx < args.len) request_id = args[idx];
        } else if (arg[0] != '-') {
            if (kind_text == null) kind_text = arg;
        }
    }

    // Handle JSON input mode
    if (json_input != null or use_stdin) {
        const input = if (use_stdin) blk: {
            const stdin = std.io.getStdIn();
            break :blk try stdin.readToEndAlloc(allocator, 64 * 1024);
        } else json_input.?;
        defer if (use_stdin) allocator.free(input);

        // Extract fields from JSON
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
            try writeErrorResponse("json_contract_error", "invalid JSON input");
            std.process.exit(1);
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const j_version = if (obj.get("gipVersion")) |v| v.string else null;
        const j_kind = if (obj.get("kind")) |v| v.string else null;
        const j_path = if (obj.get("path")) |v| v.string else null;
        const j_workspace = if (obj.get("workspace")) |v| v.string else null;
        const j_request_id = if (obj.get("requestId")) |v| v.string else null;

        var result = try gip.dispatch.dispatch(
            allocator,
            j_kind,
            j_version,
            j_workspace orelse workspace,
            j_path orelse path,
            input,
        );
        defer result.deinit(allocator);

        const response = try gip.schema.renderResponse(
            allocator,
            gip.core.PROTOCOL_VERSION,
            j_request_id orelse request_id,
            if (j_kind) |k| gip.core.parseRequestKind(k) else null,
            result.status,
            result.result_state,
            result.result_json,
            result.err,
            result.stats,
        );
        defer allocator.free(response);

        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(response);
        try stdout.writeByte('\n');
        return;
    }

    // Direct CLI mode
    if (kind_text == null) {
        try printUsage();
        std.process.exit(1);
    }

    var result = try gip.dispatch.dispatch(
        allocator,
        kind_text,
        gip.core.PROTOCOL_VERSION,
        workspace,
        path,
        null,
    );
    defer result.deinit(allocator);

    const response = try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        request_id,
        if (kind_text) |k| gip.core.parseRequestKind(k) else null,
        result.status,
        result.result_state,
        result.result_json,
        result.err,
        result.stats,
    );
    defer allocator.free(response);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(response);
    try stdout.writeByte('\n');
}

fn printUsage() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(
        \\ghost_gip — Ghost Interface Protocol v0.1 CLI
        \\
        \\Usage:
        \\  ghost_gip <kind> [options]
        \\  ghost_gip --json '{"gipVersion":"gip.v0.1","kind":"..."}'
        \\  echo '...' | ghost_gip --stdin
        \\
        \\Kinds:
        \\  protocol.describe      Show protocol metadata
        \\  capabilities.describe  Show capability policies
        \\  engine.status          Show engine status
        \\  artifact.read          Read a file (--path, --workspace)
        \\  artifact.list          List directory (--path, --workspace)
        \\
        \\Options:
        \\  --workspace, -w  Workspace root path
        \\  --path, -p       Target path (relative or absolute)
        \\  --request-id     Request ID for tracing
        \\  --json           Pass full JSON request
        \\  --stdin          Read JSON request from stdin
        \\  --help, -h       Show this help
        \\
    );
}

fn writeErrorResponse(code: []const u8, message: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{{\"gipVersion\":\"{s}\",\"status\":\"rejected\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n", .{
        gip.core.PROTOCOL_VERSION,
        code,
        message,
    });
}
