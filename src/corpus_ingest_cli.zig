const std = @import("std");
const core = @import("ghost_core");
const corpus_ingest = core.corpus_ingest;
const sys = core.sys;

pub fn main() !void {
    mainImpl() catch |err| switch (err) {
        error.InvalidArguments, error.InvalidCharacter, error.Overflow => {
            std.debug.print("ghost_corpus_ingest: invalid arguments\nUse --help for usage.\n", .{});
            std.process.exit(2);
        },
        error.NoStagedCorpus => {
            std.debug.print("ghost_corpus_ingest: no staged corpus manifest exists for the selected shard\nUse --help for usage.\n", .{});
            std.process.exit(1);
        },
        error.FileNotFound => {
            std.debug.print("ghost_corpus_ingest: corpus path was not found\nUse --help for usage.\n", .{});
            std.process.exit(1);
        },
        error.AccessDenied => {
            std.debug.print("ghost_corpus_ingest: corpus path could not be accessed\nUse --help for usage.\n", .{});
            std.process.exit(1);
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

    var corpus_path: ?[]const u8 = null;
    var project_shard: ?[]const u8 = null;
    var trust_class: ?core.abstractions.TrustClass = null;
    var source_label: ?[]const u8 = null;
    var max_file_bytes: usize = corpus_ingest.DEFAULT_MAX_FILE_BYTES;
    var max_files: usize = corpus_ingest.DEFAULT_MAX_FILES;
    var apply_staged = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        }
        if (std.mem.eql(u8, arg, "--apply-staged")) {
            apply_staged = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project-shard=")) {
            const value = arg["--project-shard=".len..];
            if (value.len > 0) project_shard = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--trust-class=")) {
            trust_class = core.abstractions.parseTrustClassName(arg["--trust-class=".len..]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--source-label=")) {
            const value = arg["--source-label=".len..];
            if (value.len > 0) source_label = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--max-file-bytes=")) {
            max_file_bytes = try std.fmt.parseUnsigned(usize, arg["--max-file-bytes=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--max-files=")) {
            max_files = try std.fmt.parseUnsigned(usize, arg["--max-files=".len..], 10);
            continue;
        }
        if (corpus_path == null) {
            corpus_path = arg;
            continue;
        }
        return error.InvalidArguments;
    }

    if (apply_staged) {
        if (corpus_path != null or source_label != null or trust_class != null or max_file_bytes != corpus_ingest.DEFAULT_MAX_FILE_BYTES or max_files != corpus_ingest.DEFAULT_MAX_FILES) {
            return error.InvalidArguments;
        }
        try applyStaged(allocator, project_shard);
        return;
    }

    const path = corpus_path orelse {
        printUsage();
        return error.InvalidArguments;
    };

    var result = try corpus_ingest.stage(allocator, .{
        .corpus_path = path,
        .project_shard = project_shard,
        .trust_class = trust_class,
        .source_label = source_label,
        .max_file_bytes = max_file_bytes,
        .max_files = max_files,
    });
    defer result.deinit();

    const rendered = try corpus_ingest.renderJson(allocator, &result);
    defer allocator.free(rendered);
    sys.print("{s}\n", .{rendered});
}

fn printUsage() void {
    sys.print(
        "Usage: ghost_corpus_ingest <corpus-path> [--project-shard=id] [--trust-class=exploratory|project|promoted|core] [--source-label=name] [--max-file-bytes=N] [--max-files=N]\n       ghost_corpus_ingest --apply-staged [--project-shard=id]\n",
        .{},
    );
}

fn applyStaged(allocator: std.mem.Allocator, project_shard: ?[]const u8) !void {
    var shard_metadata = if (project_shard) |value|
        try core.shards.resolveProjectMetadata(allocator, value)
    else
        try core.shards.resolveCoreMetadata(allocator);
    defer shard_metadata.deinit();

    var paths = try core.shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();

    if (!fileExistsAbsolute(paths.corpus_ingest_staged_manifest_abs_path)) return error.NoStagedCorpus;

    try corpus_ingest.applyStaged(allocator, &paths);

    sys.print("{{\"status\":\"applied\",\"shard\":{{\"kind\":\"{s}\",\"id\":\"", .{@tagName(paths.metadata.kind)});
    try writeEscaped(paths.metadata.id);
    sys.print("\",\"root\":\"", .{});
    try writeEscaped(paths.root_abs_path);
    sys.print("\"}},\"liveManifest\":\"", .{});
    try writeEscaped(paths.corpus_ingest_live_manifest_abs_path);
    sys.print("\",\"liveFilesRoot\":\"", .{});
    try writeEscaped(paths.corpus_ingest_live_files_abs_path);
    sys.print("\"}}\n", .{});
}

fn fileExistsAbsolute(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn writeEscaped(value: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    for (value) |c| {
        switch (c) {
            '"' => try stdout.writeAll("\\\""),
            '\\' => try stdout.writeAll("\\\\"),
            '\n' => try stdout.writeAll("\\n"),
            '\r' => try stdout.writeAll("\\r"),
            '\t' => try stdout.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try stdout.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try stdout.writeByte(c);
                }
            },
        }
    }
}
