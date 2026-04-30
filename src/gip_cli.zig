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
            break :blk readBoundedRequest(allocator, stdin.reader(), gip.core.MAX_STDIN_REQUEST_BYTES) catch |err| switch (err) {
                error.RequestTooLarge => {
                    const details = try std.fmt.allocPrint(
                        allocator,
                        "maximum stdin request size is {d} bytes",
                        .{gip.core.MAX_STDIN_REQUEST_BYTES},
                    );
                    defer allocator.free(details);
                    try writeStructuredErrorResponse(
                        allocator,
                        null,
                        null,
                        .rejected,
                        .{
                            .code = .request_too_large,
                            .message = "stdin JSON request exceeds maximum size",
                            .details = details,
                            .fix_hint = "reduce the request payload or split it into smaller GIP requests",
                        },
                    );
                    std.process.exit(1);
                },
                else => return err,
            };
        } else json_input.?;
        defer if (use_stdin) allocator.free(input);

        // Extract fields from JSON
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
            try writeStructuredErrorResponse(
                allocator,
                request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "invalid JSON input" },
            );
            std.process.exit(1);
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try writeStructuredErrorResponse(
                allocator,
                request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "GIP request must be a JSON object" },
            );
            std.process.exit(1);
        }

        const obj = parsed.value.object;
        const j_request_id = jsonStringField(obj, "requestId") catch {
            try writeStructuredErrorResponse(
                allocator,
                request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "requestId must be a string when present" },
            );
            std.process.exit(1);
        };
        const j_version = jsonStringField(obj, "gipVersion") catch {
            try writeStructuredErrorResponse(
                allocator,
                j_request_id orelse request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "gipVersion must be a string when present" },
            );
            std.process.exit(1);
        };
        const j_kind = jsonStringField(obj, "kind") catch {
            try writeStructuredErrorResponse(
                allocator,
                j_request_id orelse request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "kind must be a string when present" },
            );
            std.process.exit(1);
        };
        const j_path = jsonStringField(obj, "path") catch {
            try writeStructuredErrorResponse(
                allocator,
                j_request_id orelse request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "path must be a string when present" },
            );
            std.process.exit(1);
        };
        const j_workspace = jsonStringField(obj, "workspace") catch {
            try writeStructuredErrorResponse(
                allocator,
                j_request_id orelse request_id,
                null,
                .rejected,
                .{ .code = .json_contract_error, .message = "workspace must be a string when present" },
            );
            std.process.exit(1);
        };

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

fn readBoundedRequest(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_bytes: usize,
) ![]u8 {
    const input = reader.readAllAlloc(allocator, max_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => return error.RequestTooLarge,
        else => return err,
    };
    errdefer allocator.free(input);

    if (input.len > max_bytes) return error.RequestTooLarge;
    return input;
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

fn jsonStringField(obj: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value != .string) return error.JsonFieldMustBeString;
    return value.string;
}

fn writeStructuredErrorResponse(
    allocator: std.mem.Allocator,
    request_id: ?[]const u8,
    kind: ?gip.core.RequestKind,
    status: gip.core.ProtocolStatus,
    err: gip.schema.GipError,
) !void {
    const response = try gip.schema.renderResponse(
        allocator,
        gip.core.PROTOCOL_VERSION,
        request_id,
        kind,
        status,
        null,
        null,
        err,
        null,
    );
    defer allocator.free(response);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(response);
    try stdout.writeByte('\n');
}

test "json string field rejects non-string GIP envelope fields" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"kind\":42}", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectError(error.JsonFieldMustBeString, jsonStringField(parsed.value.object, "kind"));
}

test "json string field accepts missing and string GIP envelope fields" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"kind\":\"engine.status\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("engine.status", (try jsonStringField(parsed.value.object, "kind")).?);
    try std.testing.expect((try jsonStringField(parsed.value.object, "workspace")) == null);
}

test "stdin request limit is named and larger than legacy 64KB cap" {
    try std.testing.expect(gip.core.MAX_STDIN_REQUEST_BYTES == 1024 * 1024);
    try std.testing.expect(gip.core.MAX_STDIN_REQUEST_BYTES > 64 * 1024);
}

test "bounded request reader accepts small stdin-style GIP request" {
    const allocator = std.testing.allocator;
    var stream = std.io.fixedBufferStream("{\"gipVersion\":\"gip.v0.1\",\"kind\":\"engine.status\"}");
    const input = try readBoundedRequest(allocator, stream.reader(), gip.core.MAX_STDIN_REQUEST_BYTES);
    defer allocator.free(input);

    try std.testing.expect(std.mem.indexOf(u8, input, "\"engine.status\"") != null);
}

test "bounded request reader accepts context.autopsy payload larger than legacy 64KB cap" {
    const allocator = std.testing.allocator;
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();

    try payload.appendNTimes('a', 70 * 1024);
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();
    try request.writer().print(
        "{{\"gipVersion\":\"gip.v0.1\",\"kind\":\"context.autopsy\",\"context\":{{\"summary\":\"{s}\"}}}}",
        .{payload.items},
    );

    var stream = std.io.fixedBufferStream(request.items);
    const input = try readBoundedRequest(allocator, stream.reader(), gip.core.MAX_STDIN_REQUEST_BYTES);
    defer allocator.free(input);

    try std.testing.expect(input.len > 64 * 1024);
    try std.testing.expect(input.len < gip.core.MAX_STDIN_REQUEST_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, input, "\"context.autopsy\"") != null);
}

test "bounded request reader rejects oversized stdin request" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, gip.core.MAX_STDIN_REQUEST_BYTES + 1);
    defer allocator.free(payload);
    @memset(payload, 'x');

    var stream = std.io.fixedBufferStream(payload);
    try std.testing.expectError(
        error.RequestTooLarge,
        readBoundedRequest(allocator, stream.reader(), gip.core.MAX_STDIN_REQUEST_BYTES),
    );
}
