const std = @import("std");

pub const MAX_CYCLES: u8 = 5;
pub const DEFAULT_DIAGNOSTIC_BUFFER_BYTES: usize = 64 * 1024;

pub const DiagnosticKind = enum {
    none,
    type_mismatch,
    unused_variable,
    unknown,

    pub fn name(self: DiagnosticKind) []const u8 {
        return @tagName(self);
    }
};

pub const CandidateKind = enum {
    none,
    compatible_signature_lookup,
    discard_unused_variable,
    no_safe_mutation,

    pub fn name(self: CandidateKind) []const u8 {
        return @tagName(self);
    }
};

pub const Options = struct {
    cwd: []const u8 = ".",
    test_file: ?[]const u8 = null,
    source: ?[]const u8 = null,
    max_cycles: u8 = MAX_CYCLES,
    diagnostic_buffer_bytes: usize = DEFAULT_DIAGNOSTIC_BUFFER_BYTES,
};

const Location = struct {
    line: u32 = 0,
    column: u32 = 0,
};

const Cycle = struct {
    index: u8,
    test_file: []u8,
    exit_code: ?u8,
    diagnostic_kind: DiagnosticKind,
    diagnostic_excerpt: []u8,
    candidate_kind: CandidateKind,
    candidate_summary: []u8,
    applied_to_temp: bool = false,

    fn deinit(self: *Cycle, allocator: std.mem.Allocator) void {
        allocator.free(self.test_file);
        allocator.free(self.diagnostic_excerpt);
        allocator.free(self.candidate_summary);
        self.* = undefined;
    }
};

const RunResult = struct {
    cycles: std.ArrayList(Cycle),
    final_status: []const u8,
    final_tier: []const u8,
    unstable_coordinates: bool,
    candidate_verified: bool,
    source_mutation: bool,
    commands_executed: bool,
    verifiers_executed: bool,
    max_cycles: u8,

    fn deinit(self: *RunResult) void {
        for (self.cycles.items) |*cycle| cycle.deinit(self.cycles.allocator);
        self.cycles.deinit();
        self.* = undefined;
    }
};

const ChildCapture = struct {
    term: std.process.Child.Term,
    stderr: []u8,

    fn deinit(self: *ChildCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn runAndRenderJson(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var result = try run(allocator, options);
    defer result.deinit();
    return renderJson(allocator, result);
}

fn run(allocator: std.mem.Allocator, options: Options) !RunResult {
    const max_cycles = @min(if (options.max_cycles == 0) @as(u8, 1) else options.max_cycles, MAX_CYCLES);
    var cycles = std.ArrayList(Cycle).init(allocator);
    errdefer {
        for (cycles.items) |*cycle| cycle.deinit(allocator);
        cycles.deinit();
    }

    var owned_current_file: ?[]u8 = null;
    defer if (owned_current_file) |value| allocator.free(value);

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |value| allocator.free(value);

    const initial_file = if (options.source) |source| blk: {
        owned_source = try allocator.dupe(u8, source);
        owned_current_file = try writeTempSource(allocator, options.cwd, source, 0);
        break :blk owned_current_file.?;
    } else options.test_file orelse return error.MissingTestFileOrSource;

    var current_file: []const u8 = initial_file;
    var last_source: ?[]const u8 = owned_source;
    if (last_source == null and options.test_file != null) {
        owned_source = readSourceForMutation(allocator, options.cwd, options.test_file.?) catch null;
        last_source = owned_source;
    }

    var verified = false;
    var terminal_failure = false;

    var cycle_index: u8 = 0;
    while (cycle_index < max_cycles) : (cycle_index += 1) {
        var capture = try runZigTestCapture(allocator, options.cwd, current_file, options.diagnostic_buffer_bytes);
        defer capture.deinit(allocator);

        const clean_exit = termExitCode(capture.term) orelse 255;
        const diagnostic = classifyDiagnostic(capture.stderr);
        const effective_diagnostic = if (clean_exit == 0) DiagnosticKind.none else diagnostic;
        const excerpt = try boundedExcerpt(allocator, capture.stderr, options.diagnostic_buffer_bytes);
        const candidate_kind = candidateKindFor(effective_diagnostic);
        const candidate_summary = try candidateSummary(allocator, effective_diagnostic, capture.stderr, last_source);

        try cycles.append(.{
            .index = cycle_index + 1,
            .test_file = try allocator.dupe(u8, current_file),
            .exit_code = termExitCode(capture.term),
            .diagnostic_kind = effective_diagnostic,
            .diagnostic_excerpt = excerpt,
            .candidate_kind = candidate_kind,
            .candidate_summary = candidate_summary,
            .applied_to_temp = false,
        });

        if (clean_exit == 0) {
            verified = true;
            break;
        }

        if (diagnostic != .unused_variable or last_source == null) {
            terminal_failure = true;
            break;
        }

        const loc = parseFirstLocation(capture.stderr) orelse {
            terminal_failure = true;
            break;
        };
        const patched = applyUnusedVariableDiscard(allocator, last_source.?, loc.line) catch {
            terminal_failure = true;
            break;
        };
        if (std.mem.eql(u8, patched, last_source.?)) {
            allocator.free(patched);
            terminal_failure = true;
            break;
        }

        if (owned_source) |old| allocator.free(old);
        owned_source = patched;
        last_source = owned_source;

        if (owned_current_file) |old_file| allocator.free(old_file);
        owned_current_file = try writeTempSource(allocator, options.cwd, patched, cycle_index + 1);
        current_file = owned_current_file.?;
        cycles.items[cycles.items.len - 1].applied_to_temp = true;
    }

    const failed_after_budget = !verified and !terminal_failure and cycles.items.len >= max_cycles;
    return .{
        .cycles = cycles,
        .final_status = if (verified) "verified_candidate" else if (failed_after_budget) "cycle_budget_exhausted" else "unresolved",
        .final_tier = if (verified) "verified_candidate" else "tier_5_trash_candidate",
        .unstable_coordinates = !verified,
        .candidate_verified = verified,
        .source_mutation = false,
        .commands_executed = cycles.items.len != 0,
        .verifiers_executed = cycles.items.len != 0,
        .max_cycles = max_cycles,
    };
}

fn runZigTestCapture(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    test_file: []const u8,
    max_stderr_bytes: usize,
) !ChildCapture {
    var child = std.process.Child.init(&.{ "zig", "test", test_file }, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer _ = child.kill() catch {};

    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, max_stderr_bytes);
    errdefer allocator.free(stderr);
    const term = try child.wait();
    return .{ .term = term, .stderr = stderr };
}

fn readSourceForMutation(allocator: std.mem.Allocator, cwd: []const u8, test_file: []const u8) ![]u8 {
    const path = if (std.fs.path.isAbsolute(test_file))
        try allocator.dupe(u8, test_file)
    else
        try std.fs.path.join(allocator, &.{ cwd, test_file });
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

fn writeTempSource(allocator: std.mem.Allocator, cwd: []const u8, source: []const u8, cycle: u8) ![]u8 {
    const hash = std.hash.Fnv1a_64.hash(source);
    const rel_dir = try std.fmt.allocPrint(allocator, ".zig-cache/ghost_auto_fix/{x}", .{hash});
    defer allocator.free(rel_dir);

    const abs_dir = if (std.fs.path.isAbsolute(cwd))
        try std.fs.path.join(allocator, &.{ cwd, rel_dir })
    else
        try std.fs.path.join(allocator, &.{ cwd, rel_dir });
    defer allocator.free(abs_dir);
    try std.fs.cwd().makePath(abs_dir);

    const rel_file = try std.fmt.allocPrint(allocator, "{s}/candidate_{d}.zig", .{ rel_dir, cycle });
    errdefer allocator.free(rel_file);
    const abs_file = if (std.fs.path.isAbsolute(cwd))
        try std.fs.path.join(allocator, &.{ cwd, rel_file })
    else
        try std.fs.path.join(allocator, &.{ cwd, rel_file });
    defer allocator.free(abs_file);

    var file = try std.fs.cwd().createFile(abs_file, .{ .truncate = true });
    defer file.close();
    try file.writeAll(source);
    return rel_file;
}

pub fn classifyDiagnostic(stderr: []const u8) DiagnosticKind {
    if (stderr.len == 0) return .none;
    if (indexOfIgnoreCase(stderr, "type mismatch") != null or indexOfIgnoreCase(stderr, "expected type") != null) return .type_mismatch;
    if (indexOfIgnoreCase(stderr, "unused local") != null or indexOfIgnoreCase(stderr, "unused variable") != null or indexOfIgnoreCase(stderr, "unused capture") != null) return .unused_variable;
    return .unknown;
}

fn candidateKindFor(kind: DiagnosticKind) CandidateKind {
    return switch (kind) {
        .none => .none,
        .type_mismatch => .compatible_signature_lookup,
        .unused_variable => .discard_unused_variable,
        .unknown => .no_safe_mutation,
    };
}

fn candidateSummary(
    allocator: std.mem.Allocator,
    kind: DiagnosticKind,
    stderr: []const u8,
    source: ?[]const u8,
) ![]u8 {
    return switch (kind) {
        .none => allocator.dupe(u8, "compiler accepted the candidate"),
        .type_mismatch => allocator.dupe(u8, "inspect compatible rune signatures before changing code; no automatic mutation was applied"),
        .unused_variable => blk: {
            const loc = parseFirstLocation(stderr);
            if (loc != null and source != null) {
                if (try symbolAtDeclarationLine(allocator, source.?, loc.?.line)) |symbol| {
                    defer allocator.free(symbol);
                    break :blk std.fmt.allocPrint(allocator, "candidate temp patch inserts `_ = {s};` after the declaration", .{symbol});
                }
            }
            break :blk allocator.dupe(u8, "candidate temp patch inserts an explicit discard for the unused declaration when the symbol is recoverable");
        },
        .unknown => allocator.dupe(u8, "diagnostic did not match a safe deterministic mutation rule"),
    };
}

fn boundedExcerpt(allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) ![]u8 {
    const limit = @min(bytes.len, max_bytes);
    return allocator.dupe(u8, bytes[0..limit]);
}

fn parseFirstLocation(stderr: []const u8) ?Location {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const err_pos = std.mem.indexOf(u8, line, ": error:") orelse continue;
        const prefix = line[0..err_pos];
        const col_colon = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse continue;
        const line_colon = std.mem.lastIndexOfScalar(u8, prefix[0..col_colon], ':') orelse continue;
        const line_no = std.fmt.parseUnsigned(u32, prefix[line_colon + 1 .. col_colon], 10) catch continue;
        const col_no = std.fmt.parseUnsigned(u32, prefix[col_colon + 1 ..], 10) catch continue;
        return .{ .line = line_no, .column = col_no };
    }
    return null;
}

fn symbolAtDeclarationLine(allocator: std.mem.Allocator, source: []const u8, one_based_line: u32) !?[]u8 {
    if (one_based_line == 0) return null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no != one_based_line) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const after_keyword = if (std.mem.startsWith(u8, trimmed, "var "))
            trimmed["var ".len..]
        else if (std.mem.startsWith(u8, trimmed, "const "))
            trimmed["const ".len..]
        else
            return null;
        var end: usize = 0;
        while (end < after_keyword.len and isIdentByte(after_keyword[end])) : (end += 1) {}
        if (end == 0) return null;
        return try allocator.dupe(u8, after_keyword[0..end]);
    }
    return null;
}

pub fn applyUnusedVariableDiscard(allocator: std.mem.Allocator, source: []const u8, one_based_line: u32) ![]u8 {
    const symbol = try symbolAtDeclarationLine(allocator, source, one_based_line) orelse return allocator.dupe(u8, source);
    defer allocator.free(symbol);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    var first = true;
    const writer = out.writer();
    while (lines.next()) |line| : (line_no += 1) {
        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.writeAll(line);
        if (line_no == one_based_line) {
            try writer.writeByte('\n');
            try writeIndentFromLine(writer, line);
            try writer.print("_ = {s};", .{symbol});
        }
    }
    return out.toOwnedSlice();
}

fn writeIndentFromLine(writer: anytype, line: []const u8) !void {
    for (line) |byte| {
        if (byte == ' ' or byte == '\t') {
            try writer.writeByte(byte);
        } else {
            return;
        }
    }
}

fn isIdentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn termExitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        else => null,
    };
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn renderJson(allocator: std.mem.Allocator, result: RunResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"autoFix\":{\"status\":");
    try std.json.stringify(result.final_status, .{}, w);
    try w.writeAll(",\"finalTier\":");
    try std.json.stringify(result.final_tier, .{}, w);
    try w.print(",\"cycleCount\":{d},\"maxCycles\":{d},\"candidateVerified\":{s},\"unstableCoordinates\":{s}", .{
        result.cycles.items.len,
        result.max_cycles,
        if (result.candidate_verified) "true" else "false",
        if (result.unstable_coordinates) "true" else "false",
    });
    try w.writeAll(",\"cycles\":[");
    for (result.cycles.items, 0..) |cycle, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print("{{\"index\":{d},\"testFile\":", .{cycle.index});
        try std.json.stringify(cycle.test_file, .{}, w);
        if (cycle.exit_code) |code| {
            try w.print(",\"exitCode\":{d}", .{code});
        } else {
            try w.writeAll(",\"exitCode\":null");
        }
        try w.writeAll(",\"diagnosticKind\":");
        try std.json.stringify(cycle.diagnostic_kind.name(), .{}, w);
        try w.writeAll(",\"candidateKind\":");
        try std.json.stringify(cycle.candidate_kind.name(), .{}, w);
        try w.writeAll(",\"candidateSummary\":");
        try std.json.stringify(cycle.candidate_summary, .{}, w);
        try w.print(",\"appliedToTemp\":{s},\"stderrExcerpt\":", .{if (cycle.applied_to_temp) "true" else "false"});
        try std.json.stringify(cycle.diagnostic_excerpt, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"mutationFlags\":{\"sourceMutation\":false,\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":");
    try w.writeAll(if (result.commands_executed) "true" else "false");
    try w.writeAll(",\"verifiersExecuted\":");
    try w.writeAll(if (result.verifiers_executed) "true" else "false");
    try w.writeAll("},\"authorityFlags\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false},\"notes\":[\"automatic source mutation is disabled; successful repairs are verified temp candidates only\"]}}");
    return out.toOwnedSlice();
}

test "diagnostic parser recognizes zig type mismatch language" {
    try std.testing.expectEqual(DiagnosticKind.type_mismatch, classifyDiagnostic("x.zig:1:1: error: expected type 'u8', found 'u32'"));
}

test "unused variable discard patch is deterministic" {
    const source =
        \\test "x" {
        \\    const value = 1;
        \\}
    ;
    const patched = try applyUnusedVariableDiscard(std.testing.allocator, source, 2);
    defer std.testing.allocator.free(patched);
    try std.testing.expect(std.mem.indexOf(u8, patched, "_ = value;") != null);
}

test "unknown diagnostics do not create mutation candidates" {
    try std.testing.expectEqual(DiagnosticKind.unknown, classifyDiagnostic("x.zig:1:1: error: something else"));
    try std.testing.expectEqual(CandidateKind.no_safe_mutation, candidateKindFor(.unknown));
}
