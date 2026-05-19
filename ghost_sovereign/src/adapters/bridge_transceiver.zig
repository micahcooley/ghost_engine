const std = @import("std");

const SegmentBytes: usize = 32 * 1024;
const SegmentBits: u64 = SegmentBytes * 8;

const Format = enum {
    json,
    raw,
};

const Options = struct {
    input_path: []const u8 = "state/ghost_absolute.bin",
    output_path: ?[]const u8 = null,
    format: Format = .json,
    emit_limit: usize = 100,
    emit_all: bool = false,
    scan_limit: ?usize = null,
};

const ScanResult = struct {
    input_path: []const u8,
    file_bytes: usize,
    total_segments: usize,
    scanned_segments: usize,
    emitted_segments: usize,
    bytes_scanned: usize,
    elapsed_ns: u64,
    total_symmetry: u128,
    min_symmetry: u64,
    max_symmetry: u64,
    scores: []u64,

    fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.scores);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options = try parseOptions(allocator);
    var result = try scanFile(allocator, options);
    defer result.deinit(allocator);

    if (options.output_path) |path| {
        var out = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer out.close();
        try emit(options.format, out.writer(), &result);
    } else {
        const stdout = std.io.getStdOut().writer();
        try emit(options.format, stdout, &result);
    }
}

fn parseOptions(allocator: std.mem.Allocator) !Options {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var options = Options{};
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            options.input_path = args.next() orelse return error.MissingInputPath;
        } else if (std.mem.eql(u8, arg, "--output")) {
            options.output_path = args.next() orelse return error.MissingOutputPath;
        } else if (std.mem.eql(u8, arg, "--format")) {
            const value = args.next() orelse return error.MissingFormat;
            if (std.mem.eql(u8, value, "json")) {
                options.format = .json;
            } else if (std.mem.eql(u8, value, "raw")) {
                options.format = .raw;
            } else {
                return error.UnknownFormat;
            }
        } else if (std.mem.eql(u8, arg, "--emit-limit")) {
            const value = args.next() orelse return error.MissingEmitLimit;
            options.emit_limit = try std.fmt.parseInt(usize, value, 10);
            options.emit_all = false;
        } else if (std.mem.eql(u8, arg, "--emit-all")) {
            options.emit_all = true;
        } else if (std.mem.eql(u8, arg, "--scan-limit")) {
            const value = args.next() orelse return error.MissingScanLimit;
            options.scan_limit = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            try printUsage(std.io.getStdOut().writer());
            std.process.exit(0);
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: bridge_transceiver [--input path] [--output path] [--format json|raw]
        \\                          [--emit-limit n|--emit-all] [--scan-limit n]
        \\
        \\Scans a manifold file in read-only 32KiB segments and emits Hamming
        \\symmetry scores. The score is the number of bit positions matching
        \\their bit-reversed opposite inside each 64-bit lane.
        \\
    );
}

fn scanFile(allocator: std.mem.Allocator, options: Options) !ScanResult {
    var file = try std.fs.cwd().openFile(options.input_path, .{ .mode = .read_only });
    defer file.close();

    const file_bytes = try file.getEndPos();
    if (file_bytes == 0) {
        return .{
            .input_path = options.input_path,
            .file_bytes = 0,
            .total_segments = 0,
            .scanned_segments = 0,
            .emitted_segments = 0,
            .bytes_scanned = 0,
            .elapsed_ns = 0,
            .total_symmetry = 0,
            .min_symmetry = 0,
            .max_symmetry = 0,
            .scores = try allocator.alloc(u64, 0),
        };
    }

    const mapped = try std.posix.mmap(
        null,
        file_bytes,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(mapped);

    const total_segments = (file_bytes + SegmentBytes - 1) / SegmentBytes;
    const scan_segments = if (options.scan_limit) |limit| @min(limit, total_segments) else total_segments;
    const emit_cap = if (options.emit_all) scan_segments else @min(options.emit_limit, scan_segments);

    var scores = try std.ArrayList(u64).initCapacity(allocator, emit_cap);
    errdefer scores.deinit();

    var total_symmetry: u128 = 0;
    var min_symmetry: u64 = std.math.maxInt(u64);
    var max_symmetry: u64 = 0;
    var bytes_scanned: usize = 0;

    var timer = try std.time.Timer.start();
    var segment_index: usize = 0;
    while (segment_index < scan_segments) : (segment_index += 1) {
        const start = segment_index * SegmentBytes;
        const end = @min(start + SegmentBytes, mapped.len);
        const score = segmentSymmetry(mapped[start..end]);

        total_symmetry += score;
        min_symmetry = @min(min_symmetry, score);
        max_symmetry = @max(max_symmetry, score);
        bytes_scanned += end - start;
        if (scores.items.len < emit_cap) try scores.append(score);
    }
    const elapsed_ns = timer.read();

    if (scan_segments == 0) min_symmetry = 0;

    return .{
        .input_path = options.input_path,
        .file_bytes = file_bytes,
        .total_segments = total_segments,
        .scanned_segments = scan_segments,
        .emitted_segments = scores.items.len,
        .bytes_scanned = bytes_scanned,
        .elapsed_ns = elapsed_ns,
        .total_symmetry = total_symmetry,
        .min_symmetry = min_symmetry,
        .max_symmetry = max_symmetry,
        .scores = try scores.toOwnedSlice(),
    };
}

fn segmentSymmetry(segment: []const u8) u64 {
    var score: u64 = 0;
    var i: usize = 0;
    while (i + @sizeOf(u64) <= segment.len) : (i += @sizeOf(u64)) {
        const word = std.mem.readInt(u64, segment[i..][0..8], .little);
        score += @as(u64, 64 - @popCount(word ^ @bitReverse(word)));
    }
    while (i < segment.len) : (i += 1) {
        const byte = segment[i];
        score += @as(u64, 8 - @popCount(byte ^ @bitReverse(byte)));
    }
    return score;
}

fn emit(format: Format, writer: anytype, result: *const ScanResult) !void {
    switch (format) {
        .json => try emitJson(writer, result),
        .raw => try emitRaw(writer, result.scores),
    }
}

fn emitRaw(writer: anytype, scores: []const u64) !void {
    for (scores) |score| {
        var bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &bytes, score, .little);
        try writer.writeAll(&bytes);
    }
}

fn emitJson(writer: anytype, result: *const ScanResult) !void {
    const throughput_bps = if (result.elapsed_ns == 0)
        0.0
    else
        (@as(f64, @floatFromInt(result.bytes_scanned)) * 1_000_000_000.0) / @as(f64, @floatFromInt(result.elapsed_ns));
    const avg_density = if (result.bytes_scanned == 0)
        0.0
    else
        @as(f64, @floatFromInt(result.total_symmetry)) / @as(f64, @floatFromInt(result.bytes_scanned * 8));

    try writer.writeAll("{\n  \"input\": ");
    try std.json.encodeJsonString(result.input_path, .{}, writer);
    try writer.writeAll(",\n");
    try writer.print(
        "  \"metric\": \"hamming_symmetry_bitreverse_u64\",\n" ++
            "  \"segment_bytes\": {d},\n" ++
            "  \"segment_bits\": {d},\n" ++
            "  \"file_bytes\": {d},\n" ++
            "  \"total_segments\": {d},\n" ++
            "  \"scanned_segments\": {d},\n" ++
            "  \"emitted_segments\": {d},\n" ++
            "  \"map_truncated\": {s},\n" ++
            "  \"bytes_scanned\": {d},\n" ++
            "  \"elapsed_ns\": {d},\n" ++
            "  \"throughput_bytes_per_sec\": {d:.2},\n" ++
            "  \"throughput_gib_per_sec\": {d:.4},\n" ++
            "  \"average_density\": {d:.6},\n" ++
            "  \"min_symmetry\": {d},\n" ++
            "  \"max_symmetry\": {d},\n" ++
            "  \"scores\": [",
        .{
            SegmentBytes,
            SegmentBits,
            result.file_bytes,
            result.total_segments,
            result.scanned_segments,
            result.emitted_segments,
            if (result.emitted_segments < result.scanned_segments) "true" else "false",
            result.bytes_scanned,
            result.elapsed_ns,
            throughput_bps,
            throughput_bps / (1024.0 * 1024.0 * 1024.0),
            avg_density,
            result.min_symmetry,
            result.max_symmetry,
        },
    );
    for (result.scores, 0..) |score, idx| {
        if (idx != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{score});
    }
    try writer.writeAll("]\n}\n");
}

test "segment symmetry is maximal for zeroed data" {
    const data = [_]u8{0} ** 32;
    try std.testing.expectEqual(@as(u64, data.len * 8), segmentSymmetry(&data));
}

test "segment symmetry counts bit-reversed matches per byte tail" {
    const data = [_]u8{ 0b1000_0001, 0b1000_0000 };
    try std.testing.expectEqual(@as(u64, 14), segmentSymmetry(&data));
}
