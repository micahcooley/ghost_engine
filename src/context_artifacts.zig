const std = @import("std");
const context_autopsy = @import("context_autopsy.zig");

pub const DEFAULT_MAX_FILE_BYTES: usize = 64 * 1024;
pub const DEFAULT_MAX_CHUNK_BYTES: usize = 32 * 1024;
pub const DEFAULT_MAX_FILES: usize = 128;
pub const DEFAULT_MAX_ENTRIES: usize = 512;
pub const DEFAULT_MAX_BYTES: usize = 512 * 1024;

pub const MAX_FILE_BYTES: usize = 256 * 1024;
pub const MAX_CHUNK_BYTES: usize = 128 * 1024;
pub const MAX_FILES: usize = 512;
pub const MAX_ENTRIES: usize = 4096;
pub const MAX_BYTES: usize = 2 * 1024 * 1024;

pub const ArtifactRefKind = enum {
    file,
    directory,
};

pub const ArtifactRef = struct {
    kind: ArtifactRefKind = .file,
    path: []const u8,
    purpose: []const u8 = "",
    reason: []const u8 = "",
    include_filters: []const []const u8 = &.{},
    exclude_filters: []const []const u8 = &.{},
    max_file_bytes: usize = DEFAULT_MAX_FILE_BYTES,
    max_chunk_bytes: usize = DEFAULT_MAX_CHUNK_BYTES,
    max_files: usize = DEFAULT_MAX_FILES,
    max_entries: usize = DEFAULT_MAX_ENTRIES,
    max_bytes: usize = DEFAULT_MAX_BYTES,
};

pub const ArtifactRequestReport = struct {
    kind: []const u8,
    path: []const u8,
    purpose: []const u8 = "",
    reason: []const u8 = "",
    include_filters: []const []const u8 = &.{},
    exclude_filters: []const []const u8 = &.{},
    max_file_bytes: usize,
    max_chunk_bytes: usize,
    max_files: usize,
    max_entries: usize,
    max_bytes: usize,
};

pub const CoverageFile = struct {
    path: []const u8,
    reason: []const u8,
    bytes: usize = 0,
};

pub const CoverageUnknown = struct {
    name: []const u8,
    path: []const u8,
    reason: []const u8,
};

pub const CoverageReport = struct {
    artifacts_requested: []ArtifactRequestReport = &.{},
    files_considered: usize = 0,
    files_read: usize = 0,
    bytes_read: usize = 0,
    files_skipped: usize = 0,
    skipped_inputs: []CoverageFile = &.{},
    files_truncated: usize = 0,
    truncated_inputs: []CoverageFile = &.{},
    budget_hits: []const []const u8 = &.{},
    unknowns: []CoverageUnknown = &.{},
};

const Builder = struct {
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    requests: std.ArrayList(ArtifactRequestReport),
    skipped: std.ArrayList(CoverageFile),
    truncated: std.ArrayList(CoverageFile),
    budget_hits: std.ArrayList([]const u8),
    unknowns: std.ArrayList(CoverageUnknown),
    files_considered: usize = 0,
    files_read: usize = 0,
    bytes_read: usize = 0,
    entries_seen: usize = 0,
    aggregate_budget_hit: bool = false,

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

    fn addRequest(self: *Builder, ref: ArtifactRef) !void {
        try self.requests.append(.{
            .kind = if (ref.kind == .directory) "directory" else "file",
            .path = try self.allocator.dupe(u8, ref.path),
            .purpose = try self.allocator.dupe(u8, ref.purpose),
            .reason = try self.allocator.dupe(u8, ref.reason),
            .include_filters = try dupeStringList(self.allocator, ref.include_filters),
            .exclude_filters = try dupeStringList(self.allocator, ref.exclude_filters),
            .max_file_bytes = ref.max_file_bytes,
            .max_chunk_bytes = ref.max_chunk_bytes,
            .max_files = ref.max_files,
            .max_entries = ref.max_entries,
            .max_bytes = ref.max_bytes,
        });
    }

    fn addSkip(self: *Builder, path: []const u8, reason: []const u8) !void {
        try self.skipped.append(.{
            .path = try self.allocator.dupe(u8, path),
            .reason = try self.allocator.dupe(u8, reason),
        });
        try self.addUnknown("artifact_region_unread", path, reason);
    }

    fn addTruncation(self: *Builder, path: []const u8, reason: []const u8, bytes: usize) !void {
        try self.truncated.append(.{
            .path = try self.allocator.dupe(u8, path),
            .reason = try self.allocator.dupe(u8, reason),
            .bytes = bytes,
        });
        try self.addUnknown("artifact_region_truncated", path, reason);
    }

    fn addBudgetHit(self: *Builder, reason: []const u8) !void {
        for (self.budget_hits.items) |existing| {
            if (std.mem.eql(u8, existing, reason)) return;
        }
        try self.budget_hits.append(try self.allocator.dupe(u8, reason));
    }

    fn addUnknown(self: *Builder, name: []const u8, path: []const u8, reason: []const u8) !void {
        try self.unknowns.append(.{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .reason = try self.allocator.dupe(u8, reason),
        });
    }

    fn finish(self: *Builder) !CoverageReport {
        return .{
            .artifacts_requested = try self.requests.toOwnedSlice(),
            .files_considered = self.files_considered,
            .files_read = self.files_read,
            .bytes_read = self.bytes_read,
            .files_skipped = self.skipped.items.len,
            .skipped_inputs = try self.skipped.toOwnedSlice(),
            .files_truncated = self.truncated.items.len,
            .truncated_inputs = try self.truncated.toOwnedSlice(),
            .budget_hits = try self.budget_hits.toOwnedSlice(),
            .unknowns = try self.unknowns.toOwnedSlice(),
        };
    }
};

pub fn collect(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    refs: []const ArtifactRef,
) !CoverageReport {
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

pub fn appendUnknownsToBuilder(
    report: *const CoverageReport,
    builder: anytype,
) !void {
    for (report.unknowns) |unknown| {
        try builder.addUnknown(context_autopsy.ContextUnknown{
            .name = unknown.name,
            .source_pack = "artifact_refs",
            .importance = "high",
            .reason = unknown.reason,
        });
    }
}

fn sanitizeRef(ref: ArtifactRef) ArtifactRef {
    var out = ref;
    out.max_file_bytes = bounded(out.max_file_bytes, DEFAULT_MAX_FILE_BYTES, MAX_FILE_BYTES);
    out.max_chunk_bytes = bounded(out.max_chunk_bytes, DEFAULT_MAX_CHUNK_BYTES, MAX_CHUNK_BYTES);
    out.max_files = bounded(out.max_files, DEFAULT_MAX_FILES, MAX_FILES);
    out.max_entries = bounded(out.max_entries, DEFAULT_MAX_ENTRIES, MAX_ENTRIES);
    out.max_bytes = bounded(out.max_bytes, DEFAULT_MAX_BYTES, MAX_BYTES);
    return out;
}

fn bounded(value: usize, default_value: usize, max_value: usize) usize {
    if (value == 0) return default_value;
    return @min(value, max_value);
}

fn collectRef(builder: *Builder, ref: ArtifactRef) !void {
    const full_path = resolveContainedPath(builder.allocator, builder.root_abs, ref.path) catch |err| {
        try builder.addSkip(ref.path, @errorName(err));
        return;
    };
    defer builder.allocator.free(full_path);

    switch (ref.kind) {
        .file => try readOneFile(builder, ref, full_path, relPath(builder.root_abs, full_path, ref.path)),
        .directory => try collectDirectory(builder, ref, full_path, relPath(builder.root_abs, full_path, ref.path)),
    }
}

fn collectDirectory(builder: *Builder, ref: ArtifactRef, full_path: []const u8, rel_root: []const u8) !void {
    var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch |err| {
        try builder.addSkip(rel_root, @errorName(err));
        return;
    };
    defer dir.close();
    try walkDir(builder, ref, dir, rel_root, 0);
}

const LocalEntry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,

    fn lessThan(_: void, a: LocalEntry, b: LocalEntry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

fn walkDir(builder: *Builder, ref: ArtifactRef, dir: std.fs.Dir, prefix: []const u8, depth: usize) !void {
    if (builder.entries_seen >= ref.max_entries) {
        try builder.addBudgetHit("max_entries");
        try builder.addUnknown("artifact_region_unread", prefix, "max_entries");
        return;
    }

    var local = std.ArrayList(LocalEntry).init(builder.allocator);
    defer {
        for (local.items) |item| builder.allocator.free(item.name);
        local.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |raw| {
        try local.append(.{ .name = try builder.allocator.dupe(u8, raw.name), .kind = raw.kind });
    }
    std.mem.sort(LocalEntry, local.items, {}, LocalEntry.lessThan);

    for (local.items) |entry| {
        if (builder.entries_seen >= ref.max_entries) {
            try builder.addBudgetHit("max_entries");
            try builder.addUnknown("artifact_region_unread", prefix, "max_entries");
            return;
        }
        builder.entries_seen += 1;
        const child_rel = try joinRel(builder.allocator, prefix, entry.name);
        defer builder.allocator.free(child_rel);

        if (isDefaultExcluded(entry.name) or matchesAny(child_rel, ref.exclude_filters)) {
            try builder.addSkip(child_rel, "excluded_by_filter");
            continue;
        }

        if (entry.kind == .directory) {
            if (depth + 1 > 32) {
                try builder.addSkip(child_rel, "max_depth");
                continue;
            }
            var child = dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
                try builder.addSkip(child_rel, @errorName(err));
                continue;
            };
            defer child.close();
            try walkDir(builder, ref, child, child_rel, depth + 1);
            continue;
        }

        if (entry.kind != .file) {
            try builder.addSkip(child_rel, "unsupported_entry_kind");
            continue;
        }
        if (!included(child_rel, ref.include_filters)) {
            try builder.addSkip(child_rel, "filtered_by_include");
            continue;
        }
        if (builder.files_read >= ref.max_files) {
            try builder.addSkip(child_rel, "max_files");
            try builder.addBudgetHit("max_files");
            continue;
        }
        const full = try std.fs.path.join(builder.allocator, &.{ builder.root_abs, child_rel });
        defer builder.allocator.free(full);
        try readOneFile(builder, ref, full, child_rel);
    }
}

fn readOneFile(builder: *Builder, ref: ArtifactRef, full_path: []const u8, rel: []const u8) !void {
    builder.files_considered += 1;
    if (!included(rel, ref.include_filters)) {
        try builder.addSkip(rel, "filtered_by_include");
        return;
    }
    if (matchesAny(rel, ref.exclude_filters)) {
        try builder.addSkip(rel, "excluded_by_filter");
        return;
    }
    if (builder.files_read >= ref.max_files) {
        try builder.addSkip(rel, "max_files");
        try builder.addBudgetHit("max_files");
        return;
    }
    if (builder.bytes_read >= ref.max_bytes) {
        try builder.addSkip(rel, "aggregate_max_bytes");
        try builder.addBudgetHit("aggregate_max_bytes");
        builder.aggregate_budget_hit = true;
        return;
    }

    const file = std.fs.openFileAbsolute(full_path, .{}) catch |err| {
        try builder.addSkip(rel, @errorName(err));
        return;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        try builder.addSkip(rel, @errorName(err));
        return;
    };
    if (stat.kind != .file) {
        try builder.addSkip(rel, "unsupported_entry_kind");
        return;
    }

    const remaining = ref.max_bytes - builder.bytes_read;
    const read_limit = @min(@min(ref.max_file_bytes, ref.max_chunk_bytes), remaining);
    if (read_limit == 0) {
        try builder.addSkip(rel, "aggregate_max_bytes");
        try builder.addBudgetHit("aggregate_max_bytes");
        return;
    }

    const buf = try builder.allocator.alloc(u8, read_limit);
    defer builder.allocator.free(buf);
    const amt = try file.read(buf);
    const sample = buf[0..amt];
    if (isBinary(sample)) {
        try builder.addSkip(rel, "binary_or_unsupported");
        return;
    }

    builder.files_read += 1;
    builder.bytes_read += amt;
    if (stat.size > amt) {
        try builder.addTruncation(rel, if (amt >= ref.max_chunk_bytes) "max_chunk_bytes" else "max_file_bytes_or_aggregate_budget", amt);
        if (builder.bytes_read >= ref.max_bytes) try builder.addBudgetHit("aggregate_max_bytes");
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

fn joinRel(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0 or std.mem.eql(u8, prefix, ".")) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ prefix, name });
}

fn included(path: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    return matchesAny(path, filters);
}

fn matchesAny(path: []const u8, filters: []const []const u8) bool {
    for (filters) |filter| {
        if (matchesFilter(path, filter)) return true;
    }
    return false;
}

fn matchesFilter(path: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return false;
    if (globMatches(path, filter)) return true;
    if (!hasGlobMeta(filter)) return std.mem.indexOf(u8, path, filter) != null;
    return false;
}

const MAX_GLOB_SEGMENTS: usize = 256;

fn globMatches(path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, pattern, 0) != null) return false;

    var path_storage: [MAX_GLOB_SEGMENTS][]const u8 = undefined;
    var pattern_storage: [MAX_GLOB_SEGMENTS][]const u8 = undefined;
    const path_segments = splitGlobSegments(path, &path_storage) orelse return false;
    const pattern_segments = splitGlobSegments(pattern, &pattern_storage) orelse return false;

    var path_idx: usize = 0;
    var pattern_idx: usize = 0;
    var doublestar_idx: ?usize = null;
    var doublestar_path_idx: usize = 0;

    while (path_idx < path_segments.len) {
        if (pattern_idx < pattern_segments.len and std.mem.eql(u8, pattern_segments[pattern_idx], "**")) {
            doublestar_idx = pattern_idx;
            pattern_idx += 1;
            doublestar_path_idx = path_idx;
            continue;
        }
        if (pattern_idx < pattern_segments.len and segmentMatches(path_segments[path_idx], pattern_segments[pattern_idx])) {
            path_idx += 1;
            pattern_idx += 1;
            continue;
        }
        if (doublestar_idx) |star_idx| {
            pattern_idx = star_idx + 1;
            doublestar_path_idx += 1;
            path_idx = doublestar_path_idx;
            continue;
        }
        return false;
    }

    while (pattern_idx < pattern_segments.len and std.mem.eql(u8, pattern_segments[pattern_idx], "**")) {
        pattern_idx += 1;
    }
    return pattern_idx == pattern_segments.len;
}

fn splitGlobSegments(input: []const u8, storage: *[MAX_GLOB_SEGMENTS][]const u8) ?[]const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, input, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (count >= storage.len) return null;
        storage[count] = segment;
        count += 1;
    }
    return storage[0..count];
}

fn segmentMatches(text: []const u8, pattern: []const u8) bool {
    var text_idx: usize = 0;
    var pattern_idx: usize = 0;
    var star_idx: ?usize = null;
    var star_text_idx: usize = 0;

    while (text_idx < text.len) {
        if (pattern_idx < pattern.len and (pattern[pattern_idx] == '?' or pattern[pattern_idx] == text[text_idx])) {
            text_idx += 1;
            pattern_idx += 1;
            continue;
        }
        if (pattern_idx < pattern.len and pattern[pattern_idx] == '*') {
            star_idx = pattern_idx;
            pattern_idx += 1;
            star_text_idx = text_idx;
            continue;
        }
        if (star_idx) |star| {
            pattern_idx = star + 1;
            star_text_idx += 1;
            text_idx = star_text_idx;
            continue;
        }
        return false;
    }

    while (pattern_idx < pattern.len and pattern[pattern_idx] == '*') {
        pattern_idx += 1;
    }
    return pattern_idx == pattern.len;
}

fn hasGlobMeta(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
}

fn isDefaultExcluded(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".ghost_zig_cache") or
        std.mem.eql(u8, name, ".ghost_zig_global_cache") or
        std.mem.eql(u8, name, ".ghost_zig_local_cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "corpus");
}

fn isBinary(sample: []const u8) bool {
    for (sample) |b| {
        if (b == 0) return true;
    }
    return false;
}

fn dupeStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, idx| out[idx] = try allocator.dupe(u8, value);
    return out;
}

test "directory reference enumerates files with include and exclude filters" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "keep.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.makeDir("zig-out");
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/ignored.zig", .data = "ignore\n" });
    try tmp.dir.writeFile(.{ .sub_path = "skip.txt", .data = "ignore\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"*.zig"},
        .exclude_filters = &.{"skip"},
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expect(report.files_skipped >= 1);
    try std.testing.expect(report.bytes_read > 0);
}

test "glob filters support recursive and segment-local source patterns" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const root = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/deep.zig", .data = "const deep = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/deep.md", .data = "ignore\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const recursive_refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"src/**/*.zig"},
    }};
    const recursive_report = try collect(arena.allocator(), root, &recursive_refs);
    try std.testing.expectEqual(@as(usize, 2), recursive_report.files_read);

    const segment_refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"src/*.zig"},
    }};
    const segment_report = try collect(arena.allocator(), root, &segment_refs);
    try std.testing.expectEqual(@as(usize, 1), segment_report.files_read);
    try std.testing.expect(hasSkipReason(&segment_report, "filtered_by_include"));
}

test "glob filters support basename star and question mark" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "ab.zig", .data = "const ab = 1;\n" });
    try tmp.dir.makePath("nested");
    try tmp.dir.writeFile(.{ .sub_path = "nested/c.zig", .data = "const c = 1;\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extension_refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"*.zig"},
    }};
    const extension_report = try collect(arena.allocator(), root, &extension_refs);
    try std.testing.expectEqual(@as(usize, 2), extension_report.files_read);

    const question_refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"?.zig"},
    }};
    const question_report = try collect(arena.allocator(), root, &question_refs);
    try std.testing.expectEqual(@as(usize, 1), question_report.files_read);
}

test "glob exclude filters skip common generated roots recursively" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "keep.txt", .data = "keep\n" });
    try tmp.dir.makePath(".git/objects");
    try tmp.dir.makePath("zig-out/bin");
    try tmp.dir.makePath(".zig-cache/o");
    try tmp.dir.makePath("node_modules/pkg");
    try tmp.dir.writeFile(.{ .sub_path = ".git/objects/ignored.txt", .data = "ignore\n" });
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/bin/ignored.txt", .data = "ignore\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".zig-cache/o/ignored.txt", .data = "ignore\n" });
    try tmp.dir.writeFile(.{ .sub_path = "node_modules/pkg/ignored.txt", .data = "ignore\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .exclude_filters = &.{ ".git/**", "zig-out/**", ".zig-cache/**", "node_modules/**" },
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expect(report.files_skipped >= 4);
    try std.testing.expect(hasSkippedPathWithReason(&report, ".git", "excluded_by_filter"));
    try std.testing.expect(hasSkippedPathWithReason(&report, "zig-out", "excluded_by_filter"));
    try std.testing.expect(hasSkippedPathWithReason(&report, ".zig-cache", "excluded_by_filter"));
    try std.testing.expect(hasSkippedPathWithReason(&report, "node_modules", "excluded_by_filter"));
}

test "exclude glob wins over include glob" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/generated");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const main = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/generated/out.zig", .data = "const generated = 1;\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"src/**/*.zig"},
        .exclude_filters = &.{"src/generated/**"},
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expect(hasSkippedPathWithReason(&report, "src/generated", "excluded_by_filter"));
}

test "empty include filters read all non-excluded files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.md", .data = "b\n" });
    try tmp.dir.makePath("skip");
    try tmp.dir.writeFile(.{ .sub_path = "skip/c.txt", .data = "c\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .exclude_filters = &.{"skip/**"},
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 2), report.files_read);
    try std.testing.expect(hasSkippedPathWithReason(&report, "skip", "excluded_by_filter"));
}

test "filtered glob coverage reports skipped files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "keep.zig", .data = "const keep = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "skip.md", .data = "skip\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"*.zig"},
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expectEqual(@as(usize, 1), report.files_skipped);
    try std.testing.expectEqualStrings("skip.md", report.skipped_inputs[0].path);
    try std.testing.expectEqualStrings("filtered_by_include", report.skipped_inputs[0].reason);
    try std.testing.expectEqual(@as(usize, 1), report.unknowns.len);
}

test "large file is chunk limited and creates unknown" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(.{ .sub_path = "large.txt", .data = data });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .file,
        .path = "large.txt",
        .max_chunk_bytes = 128,
        .max_file_bytes = 128,
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expectEqual(@as(usize, 1), report.files_truncated);
    try std.testing.expectEqual(@as(usize, 1), report.unknowns.len);
}

test "binary files are skipped safely" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "binary.bin", .data = "abc\x00def" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{ .kind = .file, .path = "binary.bin" }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 0), report.files_read);
    try std.testing.expectEqual(@as(usize, 1), report.files_skipped);
    try std.testing.expectEqualStrings("binary_or_unsupported", report.skipped_inputs[0].reason);
}

test "aggregate budget hit is reported" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "aaaa" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "bbbb" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"*.txt"},
        .max_bytes = 4,
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expect(report.budget_hits.len > 0);
}

test "directory enumeration is bounded by max entries" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "b" });
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "c" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const refs = [_]ArtifactRef{.{
        .kind = .directory,
        .path = ".",
        .include_filters = &.{"*.txt"},
        .max_entries = 1,
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try collect(arena.allocator(), root, &refs);

    try std.testing.expectEqual(@as(usize, 1), report.files_read);
    try std.testing.expectEqualStrings("max_entries", report.budget_hits[0]);
}

fn hasSkipReason(report: *const CoverageReport, reason: []const u8) bool {
    for (report.skipped_inputs) |skip| {
        if (std.mem.eql(u8, skip.reason, reason)) return true;
    }
    return false;
}

fn hasSkippedPathWithReason(report: *const CoverageReport, path: []const u8, reason: []const u8) bool {
    for (report.skipped_inputs) |skip| {
        if (std.mem.eql(u8, skip.path, path) and std.mem.eql(u8, skip.reason, reason)) return true;
    }
    return false;
}
