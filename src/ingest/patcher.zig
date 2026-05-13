const std = @import("std");
const bench_loader = @import("bench_loader.zig");
const gip_mapping = @import("../gip/mapping.zig");

pub const PatchMode = enum {
    none,
    clean,
    normalized_line_endings,
    three_way,
    failed,

    pub fn name(self: PatchMode) []const u8 {
        return @tagName(self);
    }
};

pub const PatchResult = struct {
    allocator: std.mem.Allocator,
    applied: bool,
    mode: PatchMode,
    gip_opcode: gip_mapping.GipOpCode = .GIP_OP_PATCH_INTEGRITY,
    detail: []u8,
    diff_stat: []u8,
    changed_files: []u8,

    pub fn deinit(self: *PatchResult) void {
        self.allocator.free(self.detail);
        self.allocator.free(self.diff_stat);
        self.allocator.free(self.changed_files);
        self.* = undefined;
    }
};

const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    fn exitedOk(self: CommandResult) bool {
        return switch (self.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }
};

pub fn applyChecked(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    patch_name: []const u8,
    patch_text: []const u8,
    max_output_bytes: usize,
) !PatchResult {
    try writePatchFile(allocator, cwd, patch_name, patch_text);

    var check = try runGit(allocator, cwd, &.{ "apply", "--check", "--whitespace=nowarn", patch_name }, max_output_bytes);
    defer check.deinit(allocator);
    if (check.exitedOk()) {
        return try applyWithMode(allocator, cwd, patch_name, .clean, max_output_bytes);
    }

    const normalized_name = try std.fmt.allocPrint(allocator, "{s}.lf", .{patch_name});
    defer allocator.free(normalized_name);
    const normalized_written = try writeNormalizedPatchFile(allocator, cwd, normalized_name, patch_text);
    const fuzzy_patch_name = if (normalized_written) normalized_name else patch_name;
    var normalized_check = try runGit(allocator, cwd, &.{ "apply", "--check", "--whitespace=nowarn", "--ignore-space-change", "--ignore-whitespace", fuzzy_patch_name }, max_output_bytes);
    defer normalized_check.deinit(allocator);
    if (normalized_check.exitedOk()) {
        return try applyWithMode(allocator, cwd, fuzzy_patch_name, .normalized_line_endings, max_output_bytes);
    }

    var three_way_check = try runGit(allocator, cwd, &.{ "apply", "--3way", "--check", "--whitespace=nowarn", patch_name }, max_output_bytes);
    defer three_way_check.deinit(allocator);
    if (three_way_check.exitedOk()) {
        return try applyWithMode(allocator, cwd, patch_name, .three_way, max_output_bytes);
    }

    const detail = try std.fmt.allocPrint(
        allocator,
        "patch integrity check failed: clean={s}; normalized={s}; three_way={s}",
        .{
            shorten(commandDiagnostic(check)),
            shorten(commandDiagnostic(normalized_check)),
            shorten(commandDiagnostic(three_way_check)),
        },
    );
    return .{
        .allocator = allocator,
        .applied = false,
        .mode = .failed,
        .detail = detail,
        .diff_stat = try allocator.dupe(u8, ""),
        .changed_files = try allocator.dupe(u8, ""),
    };
}

fn applyWithMode(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    patch_name: []const u8,
    mode: PatchMode,
    max_output_bytes: usize,
) !PatchResult {
    const apply_args: []const []const u8 = switch (mode) {
        .clean => &.{ "apply", "--whitespace=nowarn", patch_name },
        .normalized_line_endings => &.{ "apply", "--whitespace=nowarn", "--ignore-space-change", "--ignore-whitespace", patch_name },
        .three_way => &.{ "apply", "--3way", "--whitespace=nowarn", patch_name },
        .none, .failed => unreachable,
    };
    var applied = try runGit(allocator, cwd, apply_args, max_output_bytes);
    defer applied.deinit(allocator);
    if (!applied.exitedOk()) {
        return .{
            .allocator = allocator,
            .applied = false,
            .mode = .failed,
            .detail = try std.fmt.allocPrint(allocator, "patch apply failed after successful check: {s}", .{shorten(commandDiagnostic(applied))}),
            .diff_stat = try allocator.dupe(u8, ""),
            .changed_files = try allocator.dupe(u8, ""),
        };
    }

    var diff_stat = try runGit(allocator, cwd, &.{ "diff", "--stat", "--" }, max_output_bytes);
    defer diff_stat.deinit(allocator);
    var changed_files = try runGit(allocator, cwd, &.{ "diff", "--name-only", "--" }, max_output_bytes);
    defer changed_files.deinit(allocator);

    return .{
        .allocator = allocator,
        .applied = true,
        .mode = mode,
        .detail = try std.fmt.allocPrint(allocator, "patch integrity check passed; apply_mode={s}", .{mode.name()}),
        .diff_stat = try allocator.dupe(u8, commandOutput(diff_stat)),
        .changed_files = try allocator.dupe(u8, commandOutput(changed_files)),
    };
}

fn writePatchFile(allocator: std.mem.Allocator, cwd: []const u8, patch_name: []const u8, patch_text: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, patch_name });
    defer allocator.free(path);
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(patch_text);
}

fn writeNormalizedPatchFile(allocator: std.mem.Allocator, cwd: []const u8, patch_name: []const u8, patch_text: []const u8) !bool {
    if (std.mem.indexOfScalar(u8, patch_text, '\r') == null) return false;
    var normalized = std.ArrayList(u8).init(allocator);
    defer normalized.deinit();
    var idx: usize = 0;
    while (idx < patch_text.len) : (idx += 1) {
        if (patch_text[idx] == '\r') {
            if (idx + 1 < patch_text.len and patch_text[idx + 1] == '\n') continue;
            try normalized.append('\n');
            continue;
        }
        try normalized.append(patch_text[idx]);
    }
    try writePatchFile(allocator, cwd, patch_name, normalized.items);
    return true;
}

fn runGit(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    args: []const []const u8,
    max_output_bytes: usize,
) !CommandResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |arg| try argv.append(arg);
    try bench_loader.ensureNoDockerArgv(argv.items);
    const child = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = max_output_bytes,
    });
    return .{ .term = child.term, .stdout = child.stdout, .stderr = child.stderr };
}

fn commandOutput(result: CommandResult) []const u8 {
    if (result.stdout.len != 0) return result.stdout;
    if (result.stderr.len != 0) return result.stderr;
    return "";
}

fn commandDiagnostic(result: CommandResult) []const u8 {
    if (result.stderr.len != 0) return result.stderr;
    if (result.stdout.len != 0) return result.stdout;
    return "command failed without stdout or stderr";
}

fn shorten(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0..@min(trimmed.len, 1000)];
}

pub fn normalizeTestSelector(allocator: std.mem.Allocator, selector: []const u8) ![]u8 {
    const cut = std.mem.indexOfScalar(u8, selector, '[') orelse selector.len;
    return allocator.dupe(u8, selector[0..cut]);
}

test "normalized patch writer removes CRLF" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try std.fs.cwd().makePath(root);
    try writePatchFile(allocator, root, "raw.patch", "a\r\nb\r\n");
    try std.testing.expect(try writeNormalizedPatchFile(allocator, root, "norm.patch", "a\r\nb\r\n"));
    const path = try std.fs.path.join(allocator, &.{ root, "norm.patch" });
    defer allocator.free(path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("a\nb\n", contents);
}

test "test selector normalization strips pytest parameter suffixes" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeTestSelector(allocator, "tests/test_a.py::test_one[param-value]");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("tests/test_a.py::test_one", normalized);
}
