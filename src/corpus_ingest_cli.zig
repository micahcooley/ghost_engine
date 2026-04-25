const std = @import("std");
const core = @import("ghost_core");
const corpus_ingest = core.corpus_ingest;
const sys = core.sys;

pub fn main() !void {
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

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
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
        "Usage: ghost_corpus_ingest <corpus-path> [--project-shard=id] [--trust-class=exploratory|project|promoted|core] [--source-label=name] [--max-file-bytes=N] [--max-files=N]\n",
        .{},
    );
}
