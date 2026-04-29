const std = @import("std");
const context_autopsy = @import("context_autopsy.zig");

pub const DEFAULT_MAX_BYTES: usize = 64 * 1024;
pub const MAX_BYTES: usize = 256 * 1024;

pub const InputRefKind = enum {
    file,
    unsupported,
};

pub const InputRef = struct {
    kind: InputRefKind = .file,
    path: []const u8,
    id: []const u8 = "",
    label: []const u8 = "",
    purpose: []const u8 = "",
    reason: []const u8 = "",
    max_bytes: usize = DEFAULT_MAX_BYTES,
};

pub const InputRequestReport = struct {
    kind: []const u8,
    path: []const u8,
    id: []const u8 = "",
    label: []const u8 = "",
    purpose: []const u8 = "",
    reason: []const u8 = "",
    max_bytes: usize,
};

pub const InputCoverageFile = struct {
    path: []const u8,
    id: []const u8 = "",
    label: []const u8 = "",
    reason: []const u8,
    bytes: usize = 0,
};

pub const InputCoverageUnknown = struct {
    name: []const u8,
    path: []const u8,
    id: []const u8 = "",
    label: []const u8 = "",
    reason: []const u8,
};

pub const InputCoverageReport = struct {
    input_refs_requested: []InputRequestReport = &.{},
    inputs_considered: usize = 0,
    inputs_read: usize = 0,
    bytes_read: usize = 0,
    inputs_skipped: usize = 0,
    skipped_inputs: []InputCoverageFile = &.{},
    inputs_truncated: usize = 0,
    truncated_inputs: []InputCoverageFile = &.{},
    budget_hits: []const []const u8 = &.{},
    unknowns: []InputCoverageUnknown = &.{},
};

const Builder = struct {
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    requests: std.ArrayList(InputRequestReport),
    skipped: std.ArrayList(InputCoverageFile),
    truncated: std.ArrayList(InputCoverageFile),
    budget_hits: std.ArrayList([]const u8),
    unknowns: std.ArrayList(InputCoverageUnknown),
    inputs_considered: usize = 0,
    inputs_read: usize = 0,
    bytes_read: usize = 0,

    fn init(allocator: std.mem.Allocator, root_abs: []const u8) Builder {
        return .{
            .allocator = allocator,
            .root_abs = root_abs,
            .requests = .init(allocator),
            .skipped = .init(allocator),
            .truncated = .init(allocator),
            .budget_hits = .init(allocator),
            .unknowns = .init(allocator),
        };
    }

    fn addRequest(self: *Builder, ref: InputRef) !void {
        try self.requests.append(.{
            .kind = if (ref.kind == .file) "file" else "unsupported",
            .path = try self.allocator.dupe(u8, ref.path),
            .id = try self.allocator.dupe(u8, ref.id),
            .label = try self.allocator.dupe(u8, ref.label),
            .purpose = try self.allocator.dupe(u8, ref.purpose),
            .reason = try self.allocator.dupe(u8, ref.reason),
            .max_bytes = ref.max_bytes,
        });
    }

    fn addSkip(self: *Builder, ref: InputRef, reason: []const u8) !void {
        try self.skipped.append(.{
            .path = try self.allocator.dupe(u8, ref.path),
            .id = try self.allocator.dupe(u8, ref.id),
            .label = try self.allocator.dupe(u8, ref.label),
            .reason = try self.allocator.dupe(u8, reason),
        });
        try self.addUnknown(ref, "context_input_region_unread", reason);
    }

    fn addTruncation(self: *Builder, ref: InputRef, rel_path: []const u8, reason: []const u8, bytes: usize) !void {
        try self.truncated.append(.{
            .path = try self.allocator.dupe(u8, rel_path),
            .id = try self.allocator.dupe(u8, ref.id),
            .label = try self.allocator.dupe(u8, ref.label),
            .reason = try self.allocator.dupe(u8, reason),
            .bytes = bytes,
        });
        var unknown_ref = ref;
        unknown_ref.path = rel_path;
        try self.addUnknown(unknown_ref, "context_input_region_truncated", reason);
    }

    fn addBudgetHit(self: *Builder, reason: []const u8) !void {
        for (self.budget_hits.items) |existing| {
            if (std.mem.eql(u8, existing, reason)) return;
        }
        try self.budget_hits.append(try self.allocator.dupe(u8, reason));
    }

    fn addUnknown(self: *Builder, ref: InputRef, name: []const u8, reason: []const u8) !void {
        try self.unknowns.append(.{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, ref.path),
            .id = try self.allocator.dupe(u8, ref.id),
            .label = try self.allocator.dupe(u8, ref.label),
            .reason = try self.allocator.dupe(u8, reason),
        });
    }

    fn finish(self: *Builder) !InputCoverageReport {
        return .{
            .input_refs_requested = try self.requests.toOwnedSlice(),
            .inputs_considered = self.inputs_considered,
            .inputs_read = self.inputs_read,
            .bytes_read = self.bytes_read,
            .inputs_skipped = self.skipped.items.len,
            .skipped_inputs = try self.skipped.toOwnedSlice(),
            .inputs_truncated = self.truncated.items.len,
            .truncated_inputs = try self.truncated.toOwnedSlice(),
            .budget_hits = try self.budget_hits.toOwnedSlice(),
            .unknowns = try self.unknowns.toOwnedSlice(),
        };
    }
};

pub fn collect(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    refs: []const InputRef,
) !InputCoverageReport {
    const root_abs = try std.fs.cwd().realpathAlloc(allocator, workspace_root);
    defer allocator.free(root_abs);

    var builder = Builder.init(allocator, root_abs);
    for (refs) |raw_ref| {
        const ref = sanitizeRef(raw_ref);
        try builder.addRequest(ref);
        try collectRef(&builder, ref);
    }
    return builder.finish();
}

pub fn appendSignalsToBuilder(
    report: *const InputCoverageReport,
    builder: anytype,
) !void {
    for (report.skipped_inputs) |skip| {
        _ = skip;
    }
    for (report.input_refs_requested) |request| {
        try builder.addSignal(context_autopsy.ContextSignal{
            .name = "context_input_ref_requested",
            .source_pack = "context_input_refs",
            .kind = "file_backed_context_input",
            .confidence = "medium",
            .reason = request.purpose,
        });
    }
    if (report.inputs_read > 0) {
        try builder.addEvidenceExpectation(context_autopsy.EvidenceExpectation{
            .id = "context_input_refs_review",
            .summary = "Review bounded file-backed context input before relying on it.",
            .expectation_kind = "soft",
            .expected_signal = "context_input_refs_reviewed",
            .source_pack = "context_input_refs",
            .reason = "File-backed context input was read only within declared byte budgets and remains non-authorizing.",
        });
    }
    for (report.unknowns) |unknown| {
        try builder.addUnknown(context_autopsy.ContextUnknown{
            .name = unknown.name,
            .source_pack = "context_input_refs",
            .importance = "high",
            .reason = unknown.reason,
        });
    }
}

fn sanitizeRef(ref: InputRef) InputRef {
    var out = ref;
    out.max_bytes = bounded(out.max_bytes, DEFAULT_MAX_BYTES, MAX_BYTES);
    return out;
}

fn bounded(value: usize, default_value: usize, max_value: usize) usize {
    if (value == 0) return default_value;
    return @min(value, max_value);
}

fn collectRef(builder: *Builder, ref: InputRef) !void {
    builder.inputs_considered += 1;
    if (ref.kind != .file) {
        try builder.addSkip(ref, "unsupported_input_ref_kind");
        return;
    }

    const full_path = resolveContainedPath(builder.allocator, builder.root_abs, ref.path) catch |err| {
        try builder.addSkip(ref, @errorName(err));
        return;
    };
    defer builder.allocator.free(full_path);
    const rel = relPath(builder.root_abs, full_path, ref.path);

    const file = std.fs.openFileAbsolute(full_path, .{}) catch |err| {
        try builder.addSkip(ref, @errorName(err));
        return;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        try builder.addSkip(ref, @errorName(err));
        return;
    };
    if (stat.kind != .file) {
        try builder.addSkip(ref, "unsupported_entry_kind");
        return;
    }

    const buf = try builder.allocator.alloc(u8, ref.max_bytes);
    defer builder.allocator.free(buf);
    const amt = try file.read(buf);
    const sample = buf[0..amt];
    if (isBinary(sample)) {
        try builder.addSkip(ref, "binary_or_unsupported");
        return;
    }

    builder.inputs_read += 1;
    builder.bytes_read += amt;
    if (stat.size > amt) {
        try builder.addTruncation(ref, rel, "max_bytes", amt);
        try builder.addBudgetHit("max_bytes");
    }
}

fn resolveContainedPath(allocator: std.mem.Allocator, root_abs: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0 or std.mem.indexOf(u8, path, "\x00") != null) return error.InvalidPath;
    const joined = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ root_abs, path });
    defer allocator.free(joined);
    const real = try std.fs.cwd().realpathAlloc(allocator, joined);
    errdefer allocator.free(real);
    if (!isContained(root_abs, real)) return error.PathOutsideWorkspace;
    return real;
}

fn isContained(root_abs: []const u8, path_abs: []const u8) bool {
    if (std.mem.eql(u8, root_abs, path_abs)) return true;
    if (!std.mem.startsWith(u8, path_abs, root_abs)) return false;
    return path_abs.len > root_abs.len and path_abs[root_abs.len] == std.fs.path.sep;
}

fn relPath(root_abs: []const u8, full_path: []const u8, fallback: []const u8) []const u8 {
    if (isContained(root_abs, full_path) and full_path.len > root_abs.len) {
        var start = root_abs.len;
        if (full_path[start] == std.fs.path.sep) start += 1;
        return full_path[start..];
    }
    return fallback;
}

fn isBinary(sample: []const u8) bool {
    for (sample) |b| {
        if (b == 0) return true;
    }
    return false;
}

test "file-backed context input ref reads bounded text" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "context.txt", .data = "large context lives in a file\n" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const refs = [_]InputRef{.{
        .kind = .file,
        .path = "context.txt",
        .id = "transcript",
        .max_bytes = 1024,
    }};
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.inputs_read);
    try std.testing.expect(report.bytes_read > 0);
    try std.testing.expectEqual(@as(usize, 0), report.inputs_truncated);
}

test "file-backed context input ref outside workspace is reported unread" {
    var workspace = std.testing.tmpDir(.{ .iterate = true });
    defer workspace.cleanup();
    var outside = std.testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try outside.dir.writeFile(.{ .sub_path = "outside.txt", .data = "outside\n" });
    const root = try workspace.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const outside_path = try outside.dir.realpathAlloc(std.testing.allocator, "outside.txt");
    defer std.testing.allocator.free(outside_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const refs = [_]InputRef{.{ .kind = .file, .path = outside_path }};
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 0), report.inputs_read);
    try std.testing.expectEqual(@as(usize, 1), report.inputs_skipped);
    try std.testing.expectEqualStrings("PathOutsideWorkspace", report.skipped_inputs[0].reason);
    try std.testing.expectEqualStrings("context_input_region_unread", report.unknowns[0].name);
}

test "large file-backed context input ref is truncated with unknown" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data = try std.testing.allocator.alloc(u8, 2048);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(.{ .sub_path = "large.txt", .data = data });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const refs = [_]InputRef{.{ .kind = .file, .path = "large.txt", .max_bytes = 64 }};
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.inputs_read);
    try std.testing.expectEqual(@as(usize, 64), report.bytes_read);
    try std.testing.expectEqual(@as(usize, 1), report.inputs_truncated);
    try std.testing.expectEqualStrings("context_input_region_truncated", report.unknowns[0].name);
    try std.testing.expectEqualStrings("max_bytes", report.budget_hits[0]);
}
