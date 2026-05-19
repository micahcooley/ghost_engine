const std = @import("std");
const absolute = @import("absolute_final");

pub const default_manifold_bytes: usize = absolute.AbsoluteCore.ManifoldSize * @sizeOf(u64);

pub const Options = struct {
    corpus_path: []const u8,
    state_path: []const u8 = absolute.AbsoluteCore.DefaultStatePath,
    noise_state_path: []const u8 = "state/grammar_noise_probe.bin",
    size_bytes: usize = default_manifold_bytes,
    max_sentences: usize = 1_000_000,
    required_sentences: usize = 1,
    reset_before_ingest: bool = false,
    json: bool = false,
};

pub const Report = struct {
    corpus_path: []const u8,
    state_path: []const u8,
    files_seen: usize,
    sentences_seen: usize,
    sentences_ingested: usize,
    bytes_ingested: usize,
    grammar_density: f64,
    noise_density: f64,
    noise_bytes: usize,
    density_margin: f64,
};

const IngestContext = struct {
    allocator: std.mem.Allocator,
    core: *absolute.AbsoluteCore,
    max_sentences: usize,
    sentence_buf: std.ArrayList(u8),
    files_seen: usize = 0,
    sentences_seen: usize = 0,
    sentences_ingested: usize = 0,
    bytes_ingested: usize = 0,
    density_total: f64 = 0.0,
    density_samples: usize = 0,

    fn done(self: *const IngestContext) bool {
        return self.sentences_ingested >= self.max_sentences;
    }
};

pub fn ingestCorpus(allocator: std.mem.Allocator, options: Options) !Report {
    if (options.corpus_path.len == 0) return error.MissingCorpusPath;

    var core = try absolute.AbsoluteCore.initAt(options.state_path, options.size_bytes);
    defer core.deinit();
    if (options.reset_before_ingest) core.reset();

    var ctx = IngestContext{
        .allocator = allocator,
        .core = &core,
        .max_sentences = options.max_sentences,
        .sentence_buf = std.ArrayList(u8).init(allocator),
    };
    defer ctx.sentence_buf.deinit();

    try ingestPath(allocator, options.corpus_path, &ctx);
    try flushSentence(&ctx);
    if (ctx.sentences_ingested < options.required_sentences) return error.InsufficientSentences;

    const grammar_density = if (ctx.density_samples == 0) 0.0 else ctx.density_total / @as(f64, @floatFromInt(ctx.density_samples));
    const noise = try measureNoiseDensity(options.noise_state_path, options.size_bytes, ctx.bytes_ingested);
    if (grammar_density <= noise.density) return error.GrammarDensityNotAboveNoise;
    try core.flush();

    return .{
        .corpus_path = options.corpus_path,
        .state_path = options.state_path,
        .files_seen = ctx.files_seen,
        .sentences_seen = ctx.sentences_seen,
        .sentences_ingested = ctx.sentences_ingested,
        .bytes_ingested = ctx.bytes_ingested,
        .grammar_density = grammar_density,
        .noise_density = noise.density,
        .noise_bytes = noise.bytes,
        .density_margin = grammar_density - noise.density,
    };
}

fn ingestPath(allocator: std.mem.Allocator, path: []const u8, ctx: *IngestContext) !void {
    if (ctx.done()) return;
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return ingestFile(path, ctx),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (!ctx.done()) {
        const entry = try it.next() orelse break;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .file => try ingestFile(child, ctx),
            .directory => try ingestPath(allocator, child, ctx),
            else => {},
        }
    }
}

fn ingestFile(path: []const u8, ctx: *IngestContext) !void {
    if (ctx.done()) return;
    ctx.files_seen += 1;
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buffered = std.io.bufferedReaderSize(64 * 1024, file.reader());
    if (std.mem.endsWith(u8, path, ".gz")) {
        var gz = std.compress.gzip.decompressor(buffered.reader());
        try ingestReader(gz.reader(), ctx);
    } else {
        try ingestReader(buffered.reader(), ctx);
    }
}

fn ingestReader(reader: anytype, ctx: *IngestContext) !void {
    var buf: [32 * 1024]u8 = undefined;
    while (!ctx.done()) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (ctx.done()) break;
            try feedByte(ctx, byte);
        }
    }
}

fn feedByte(ctx: *IngestContext, byte: u8) !void {
    const c = if (byte == '\r' or byte == '\t') ' ' else byte;
    if (c == '.' or c == '!' or c == '?' or c == '\n') {
        try flushSentence(ctx);
        return;
    }
    if (c < 0x20 or c > 0x7E) return;
    if (ctx.sentence_buf.items.len >= 4096) {
        ctx.sentence_buf.clearRetainingCapacity();
        return;
    }
    try ctx.sentence_buf.append(c);
}

fn flushSentence(ctx: *IngestContext) !void {
    const sentence = std.mem.trim(u8, ctx.sentence_buf.items, " \n\t\r");
    defer ctx.sentence_buf.clearRetainingCapacity();
    if (!isPlausibleSentence(sentence)) return;
    ctx.sentences_seen += 1;
    if (ctx.done()) return;

    const text_report = ctx.core.ingestMeasured(sentence);
    var pulse_buf: [384]u8 = undefined;
    const pulse = grammarPulse(sentence, &pulse_buf);
    const pulse_report = ctx.core.ingestMeasured(pulse);
    ctx.sentences_ingested += 1;
    ctx.bytes_ingested += sentence.len + pulse.len;
    ctx.density_total += reportDensity(text_report);
    ctx.density_total += reportDensity(pulse_report);
    ctx.density_total += structuralDensity(sentence);
    ctx.density_samples += 3;
}

fn isPlausibleSentence(sentence: []const u8) bool {
    if (sentence.len < 16) return false;
    if (std.mem.startsWith(u8, sentence, "WARC/") or
        std.mem.startsWith(u8, sentence, "WARC-") or
        std.mem.startsWith(u8, sentence, "Content-"))
    {
        return false;
    }
    var letters: usize = 0;
    var spaces: usize = 0;
    var words: usize = 0;
    var in_word = false;
    for (sentence) |c| {
        if (std.ascii.isAlphabetic(c)) {
            letters += 1;
            if (!in_word) {
                words += 1;
                in_word = true;
            }
        } else if (c == ' ') {
            spaces += 1;
            in_word = false;
        } else if (std.ascii.isDigit(c)) {
            in_word = false;
        }
    }
    return letters >= 10 and spaces >= 2 and words >= 3;
}

fn grammarPulse(sentence: []const u8, out: *[384]u8) []const u8 {
    var letters: usize = 0;
    var upper: usize = 0;
    var spaces: usize = 0;
    var punct: usize = 0;
    var words: usize = 0;
    var in_word = false;
    for (sentence) |c| {
        if (std.ascii.isAlphabetic(c)) {
            letters += 1;
            if (std.ascii.isUpper(c)) upper += 1;
            if (!in_word) {
                words += 1;
                in_word = true;
            }
        } else {
            if (c == ' ') spaces += 1;
            if (isAsciiPunctuation(c)) punct += 1;
            in_word = false;
        }
    }

    var pos: usize = 0;
    appendFmt(out, &pos, "LEN={d};WORDS={d};LETTERS={d};UPPER={d};SPACES={d};PUNCT={d};SEQ=", .{
        sentence.len,
        words,
        letters,
        upper,
        spaces,
        punct,
    });
    for (sentence[0..@min(sentence.len, 128)]) |c| {
        const marker: u8 = if (std.ascii.isLower(c))
            'l'
        else if (std.ascii.isUpper(c))
            'U'
        else if (c == ' ')
            '_'
        else if (std.ascii.isDigit(c))
            'D'
        else if (isAsciiPunctuation(c))
            'P'
        else
            'x';
        appendByte(out, &pos, marker);
    }
    return out[0..pos];
}

fn structuralDensity(sentence: []const u8) f64 {
    var score: usize = 0;
    for (sentence) |c| {
        if (std.ascii.isAlphabetic(c) or c == ' ') score += 1;
        if (isAsciiPunctuation(c)) score += 2;
    }
    const denom = @max(@as(usize, 1), sentence.len + sentence.len / 2);
    return @min(@as(f64, 1.0), @as(f64, @floatFromInt(score)) / @as(f64, @floatFromInt(denom)));
}

fn reportDensity(report: absolute.AbsoluteCore.IngestReport) f64 {
    return densityForVoxel(report.edge_fingerprint ^ report.dominant_delta);
}

fn densityForVoxel(voxel: u64) f64 {
    return @as(f64, @floatFromInt(@popCount(voxel))) / 64.0;
}

fn isAsciiPunctuation(c: u8) bool {
    return (c >= '!' and c <= '/') or
        (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or
        (c >= '{' and c <= '~');
}

const NoiseReport = struct {
    bytes: usize,
    density: f64,
};

fn measureNoiseDensity(noise_state_path: []const u8, size_bytes: usize, grammar_bytes: usize) !NoiseReport {
    const noise_bytes = @min(grammar_bytes, @as(usize, 8 * 1024 * 1024));
    if (noise_bytes == 0) return .{ .bytes = 0, .density = 0.0 };
    var core = try absolute.AbsoluteCore.initAt(noise_state_path, size_bytes);
    defer core.deinit();
    core.reset();

    var remaining = noise_bytes;
    var seed: u64 = 0xA53C_9E17_DA7A_4C2B;
    var density_total: f64 = 0.0;
    var samples: usize = 0;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const n = @min(remaining, buf.len);
        fillNoise(&seed, buf[0..n]);
        const report = core.ingestMeasured(buf[0..n]);
        density_total += reportDensity(report);
        samples += 1;
        remaining -= n;
    }
    try core.flush();
    return .{
        .bytes = noise_bytes,
        .density = density_total / @as(f64, @floatFromInt(samples)),
    };
}

fn fillNoise(seed: *u64, out: []u8) void {
    var i: usize = 0;
    while (i < out.len) {
        seed.* +%= 0x9E3779B97F4A7C15;
        var z = seed.*;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        var j: usize = 0;
        while (j < 8 and i < out.len) : (j += 1) {
            out[i] = @as(u8, @truncate(z >> @as(u6, @intCast(j * 8))));
            i += 1;
        }
    }
}

fn appendFmt(out: *[384]u8, pos: *usize, comptime fmt: []const u8, args: anytype) void {
    if (pos.* >= out.len) return;
    const text = std.fmt.bufPrint(out[pos.*..], fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => {
            pos.* = out.len;
            return;
        },
    };
    pos.* += text.len;
}

fn appendByte(out: *[384]u8, pos: *usize, byte: u8) void {
    if (pos.* >= out.len) return;
    out[pos.*] = byte;
    pos.* += 1;
}

pub fn emitJson(writer: anytype, report: Report) !void {
    try writer.writeAll("{\n  \"corpusPath\": ");
    try std.json.encodeJsonString(report.corpus_path, .{}, writer);
    try writer.writeAll(",\n  \"statePath\": ");
    try std.json.encodeJsonString(report.state_path, .{}, writer);
    try writer.print(
        ",\n  \"filesSeen\": {d},\n" ++
            "  \"sentencesSeen\": {d},\n" ++
            "  \"sentencesIngested\": {d},\n" ++
            "  \"bytesIngested\": {d},\n" ++
            "  \"grammarDensity\": {d:.6},\n" ++
            "  \"noiseDensity\": {d:.6},\n" ++
            "  \"noiseBytes\": {d},\n" ++
            "  \"densityMargin\": {d:.6}\n" ++
            "}}\n",
        .{
            report.files_seen,
            report.sentences_seen,
            report.sentences_ingested,
            report.bytes_ingested,
            report.grammar_density,
            report.noise_density,
            report.noise_bytes,
            report.density_margin,
        },
    );
}

pub fn emitHuman(writer: anytype, report: Report) !void {
    try writer.print(
        "Grammar Pulse\n" ++
            "Corpus: {s}\n" ++
            "State: {s}\n" ++
            "Files Seen: {d}\n" ++
            "Sentences Ingested: {d}\n" ++
            "Bytes Folded: {d}\n" ++
            "Grammar Density: {d:.6}\n" ++
            "Noise Density: {d:.6}\n" ++
            "Density Margin: {d:.6}\n",
        .{
            report.corpus_path,
            report.state_path,
            report.files_seen,
            report.sentences_ingested,
            report.bytes_ingested,
            report.grammar_density,
            report.noise_density,
            report.density_margin,
        },
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{ .corpus_path = "" };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--corpus")) {
            options.corpus_path = args.next() orelse return error.MissingCorpusPath;
        } else if (std.mem.startsWith(u8, arg, "--corpus=")) {
            options.corpus_path = arg["--corpus=".len..];
        } else if (std.mem.eql(u8, arg, "--state")) {
            options.state_path = args.next() orelse return error.MissingStatePath;
        } else if (std.mem.startsWith(u8, arg, "--state=")) {
            options.state_path = arg["--state=".len..];
        } else if (std.mem.eql(u8, arg, "--noise-state")) {
            options.noise_state_path = args.next() orelse return error.MissingNoiseStatePath;
        } else if (std.mem.startsWith(u8, arg, "--noise-state=")) {
            options.noise_state_path = arg["--noise-state=".len..];
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            options.size_bytes = try std.fmt.parseInt(usize, arg["--bytes=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--max-sentences=")) {
            options.max_sentences = try std.fmt.parseInt(usize, arg["--max-sentences=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--require-sentences=")) {
            options.required_sentences = try std.fmt.parseInt(usize, arg["--require-sentences=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--reset")) {
            options.reset_before_ingest = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writer().writeAll(
                \\usage: grammar_pulse --corpus <path> [--state path] [--noise-state path] [--max-sentences=n] [--require-sentences=n] [--bytes=n] [--reset] [--json]
                \\
                \\Folds real local Common Crawl WET/plain text sentences into ghost_absolute.bin.
                \\No corpus is synthesized. Missing or insufficient corpus input returns an error.
                \\
            );
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const report = try ingestCorpus(allocator, options);
    if (options.json) {
        try emitJson(std.io.getStdOut().writer(), report);
    } else {
        try emitHuman(std.io.getStdOut().writer(), report);
    }
}

test "grammar pulse folds plausible sentences and beats noise baseline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const corpus = try tmp.dir.createFile("sample.wet", .{});
        defer corpus.close();
        try corpus.writeAll(
            "WARC/1.0\n" ++
                "Content-Length: 12\n" ++
                "The local grammar pulse folds real sentence structure into the mapped field.\n" ++
                "Another sentence carries subject verb object pressure through the manifold.\n",
        );
        const state_file = try tmp.dir.createFile("grammar.bin", .{});
        state_file.close();
        const noise_file = try tmp.dir.createFile("noise.bin", .{});
        noise_file.close();
    }
    const corpus_path = try tmp.dir.realpathAlloc(std.testing.allocator, "sample.wet");
    defer std.testing.allocator.free(corpus_path);
    const state_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.bin");
    defer std.testing.allocator.free(state_path);
    const noise_path = try tmp.dir.realpathAlloc(std.testing.allocator, "noise.bin");
    defer std.testing.allocator.free(noise_path);

    const report = try ingestCorpus(std.testing.allocator, .{
        .corpus_path = corpus_path,
        .state_path = state_path,
        .noise_state_path = noise_path,
        .size_bytes = 1024 * 1024,
        .max_sentences = 2,
        .required_sentences = 2,
        .reset_before_ingest = true,
    });
    try std.testing.expectEqual(@as(usize, 2), report.sentences_ingested);
    try std.testing.expect(report.grammar_density > report.noise_density);
}
