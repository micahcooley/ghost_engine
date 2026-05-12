const std = @import("std");

pub const MAX_STATIC_IMPORTS: usize = 64;
pub const MAX_STATIC_UNITS: usize = 64;
pub const MAX_STATIC_CLUSTERS: usize = 32;

pub const PhysicalDomain = enum(u8) {
    database,
    dsp,
    graphics,
    network,
    filesystem,
    crypto,
    ui,

    pub fn tag(self: PhysicalDomain) []const u8 {
        return switch (self) {
            .database => "DATABASE",
            .dsp => "DSP",
            .graphics => "GRAPHICS",
            .network => "NETWORK",
            .filesystem => "FILESYSTEM",
            .crypto => "CRYPTO",
            .ui => "UI",
        };
    }

    fn bit(self: PhysicalDomain) u32 {
        return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(self)));
    }
};

pub const DomainSet = packed struct(u32) {
    database: bool = false,
    dsp: bool = false,
    graphics: bool = false,
    network: bool = false,
    filesystem: bool = false,
    crypto: bool = false,
    ui: bool = false,
    _reserved: u25 = 0,

    pub const empty: DomainSet = .{};

    pub fn with(domain: PhysicalDomain) DomainSet {
        var set: DomainSet = .{};
        set.add(domain);
        return set;
    }

    pub fn add(self: *DomainSet, domain: PhysicalDomain) void {
        var bits = self.toBits();
        bits |= domain.bit();
        self.* = fromBits(bits);
    }

    pub fn merge(self: *DomainSet, other: DomainSet) void {
        self.* = fromBits(self.toBits() | other.toBits());
    }

    pub fn contains(self: DomainSet, domain: PhysicalDomain) bool {
        return (self.toBits() & domain.bit()) != 0;
    }

    pub fn isEmpty(self: DomainSet) bool {
        return self.toBits() == 0;
    }

    pub fn eql(a: DomainSet, b: DomainSet) bool {
        return a.toBits() == b.toBits();
    }

    pub fn toBits(self: DomainSet) u32 {
        return @bitCast(self);
    }

    pub fn fromBits(bits: u32) DomainSet {
        return @bitCast(bits);
    }
};

pub const ImportKind = enum {
    c_include,
    cpp_import,
    zig_import,
};

pub const ImportRef = struct {
    kind: ImportKind,
    raw: []const u8,
    normalized: []const u8,
    line: u32,
    domains: DomainSet,
};

pub const TranslationUnitInput = struct {
    path: []const u8,
    source: []const u8,
};

pub const TranslationUnit = struct {
    path: []const u8,
    imports: []ImportRef,
    domains: DomainSet,

    pub fn deinit(self: TranslationUnit, allocator: std.mem.Allocator) void {
        allocator.free(self.imports);
    }
};

pub const SemanticCluster = struct {
    id: usize,
    domains: DomainSet,
    translation_units: []usize,
    import_count: usize,
};

pub const DomainMap = struct {
    translation_units: []TranslationUnit,
    clusters: []SemanticCluster,

    pub fn deinit(self: DomainMap, allocator: std.mem.Allocator) void {
        for (self.translation_units) |unit| {
            unit.deinit(allocator);
        }
        for (self.clusters) |cluster| {
            allocator.free(cluster.translation_units);
        }
        allocator.free(self.translation_units);
        allocator.free(self.clusters);
    }
};

pub const StaticImportScan = struct {
    imports: [MAX_STATIC_IMPORTS]ImportRef = undefined,
    len: usize = 0,
    domains: DomainSet = .{},
    overflow: bool = false,

    pub fn slice(self: *const StaticImportScan) []const ImportRef {
        return self.imports[0..self.len];
    }
};

pub const StaticUnit = struct {
    path: []const u8,
    import_start: usize,
    import_len: usize,
    domains: DomainSet,
};

pub const StaticCluster = struct {
    id: usize,
    domains: DomainSet,
    units: [MAX_STATIC_UNITS]usize = undefined,
    unit_len: usize = 0,
    import_count: usize = 0,

    pub fn unitSlice(self: *const StaticCluster) []const usize {
        return self.units[0..self.unit_len];
    }
};

pub const StaticDomainMap = struct {
    imports: [MAX_STATIC_IMPORTS]ImportRef = undefined,
    import_len: usize = 0,
    units: [MAX_STATIC_UNITS]StaticUnit = undefined,
    unit_len: usize = 0,
    clusters: [MAX_STATIC_CLUSTERS]StaticCluster = undefined,
    cluster_len: usize = 0,
    overflow: bool = false,

    pub fn importSlice(self: *const StaticDomainMap) []const ImportRef {
        return self.imports[0..self.import_len];
    }

    pub fn unitSlice(self: *const StaticDomainMap) []const StaticUnit {
        return self.units[0..self.unit_len];
    }

    pub fn clusterSlice(self: *const StaticDomainMap) []const StaticCluster {
        return self.clusters[0..self.cluster_len];
    }
};

pub fn inferDomainMap(
    allocator: std.mem.Allocator,
    inputs: []const TranslationUnitInput,
) !DomainMap {
    var units = std.ArrayList(TranslationUnit).init(allocator);
    errdefer {
        for (units.items) |unit| unit.deinit(allocator);
        units.deinit();
    }

    for (inputs) |input| {
        var imports = std.ArrayList(ImportRef).init(allocator);
        errdefer imports.deinit();

        const domains = try scanImports(allocator, input.source, &imports);
        try units.append(.{
            .path = input.path,
            .imports = try imports.toOwnedSlice(),
            .domains = domains,
        });
    }

    var clusters = std.ArrayList(SemanticCluster).init(allocator);
    errdefer {
        for (clusters.items) |cluster| allocator.free(cluster.translation_units);
        clusters.deinit();
    }

    for (units.items, 0..) |unit, unit_index| {
        const cluster_index = findCluster(clusters.items, unit.domains) orelse blk: {
            try clusters.append(.{
                .id = clusters.items.len,
                .domains = unit.domains,
                .translation_units = &.{},
                .import_count = 0,
            });
            break :blk clusters.items.len - 1;
        };

        var members = std.ArrayList(usize).init(allocator);
        errdefer members.deinit();
        try members.appendSlice(clusters.items[cluster_index].translation_units);
        try members.append(unit_index);
        allocator.free(clusters.items[cluster_index].translation_units);
        clusters.items[cluster_index].translation_units = try members.toOwnedSlice();
        clusters.items[cluster_index].import_count += unit.imports.len;
    }

    return .{
        .translation_units = try units.toOwnedSlice(),
        .clusters = try clusters.toOwnedSlice(),
    };
}

fn findCluster(clusters: []const SemanticCluster, domains: DomainSet) ?usize {
    for (clusters, 0..) |cluster, index| {
        if (DomainSet.eql(cluster.domains, domains)) return index;
    }
    return null;
}

pub fn scanImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    imports: *std.ArrayList(ImportRef),
) !DomainSet {
    _ = allocator;
    var domains: DomainSet = .{};
    var scanner = Scanner.init(source);
    while (scanner.nextImport()) |import_ref| {
        try imports.append(import_ref);
        domains.merge(import_ref.domains);
    }
    return domains;
}

pub fn scanImportsComptime(comptime source: []const u8) StaticImportScan {
    @setEvalBranchQuota(source.len * 16 + 2048);
    var out: StaticImportScan = .{};
    var scanner = Scanner.init(source);
    while (scanner.nextImport()) |import_ref| {
        out.domains.merge(import_ref.domains);
        if (out.len >= MAX_STATIC_IMPORTS) {
            out.overflow = true;
            continue;
        }
        out.imports[out.len] = import_ref;
        out.len += 1;
    }
    return out;
}

pub fn inferDomainMapComptime(comptime inputs: []const TranslationUnitInput) StaticDomainMap {
    @setEvalBranchQuota(inputs.len * 4096 + 4096);
    var out: StaticDomainMap = .{};

    for (inputs) |input| {
        if (out.unit_len >= MAX_STATIC_UNITS) {
            out.overflow = true;
            continue;
        }

        const import_start = out.import_len;
        var scan = scanImportsComptime(input.source);
        for (scan.slice()) |import_ref| {
            if (out.import_len >= MAX_STATIC_IMPORTS) {
                out.overflow = true;
                break;
            }
            out.imports[out.import_len] = import_ref;
            out.import_len += 1;
        }
        if (scan.overflow) out.overflow = true;

        const unit_index = out.unit_len;
        out.units[unit_index] = .{
            .path = input.path,
            .import_start = import_start,
            .import_len = out.import_len - import_start,
            .domains = scan.domains,
        };
        out.unit_len += 1;

        const cluster_index = findStaticCluster(out.clusterSlice(), scan.domains) orelse blk: {
            if (out.cluster_len >= MAX_STATIC_CLUSTERS) {
                out.overflow = true;
                continue;
            }
            out.clusters[out.cluster_len] = .{
                .id = out.cluster_len,
                .domains = scan.domains,
            };
            out.cluster_len += 1;
            break :blk out.cluster_len - 1;
        };

        var cluster = &out.clusters[cluster_index];
        if (cluster.unit_len >= MAX_STATIC_UNITS) {
            out.overflow = true;
            continue;
        }
        cluster.units[cluster.unit_len] = unit_index;
        cluster.unit_len += 1;
        cluster.import_count += out.units[unit_index].import_len;
    }

    return out;
}

fn findStaticCluster(clusters: []const StaticCluster, domains: DomainSet) ?usize {
    for (clusters, 0..) |cluster, index| {
        if (DomainSet.eql(cluster.domains, domains)) return index;
    }
    return null;
}

const Scanner = struct {
    source: []const u8,
    cursor: usize = 0,
    line: u32 = 1,
    in_block_comment: bool = false,

    fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    fn nextImport(self: *Scanner) ?ImportRef {
        while (self.cursor < self.source.len) {
            const line_start = self.cursor;
            var line_end = line_start;
            while (line_end < self.source.len and self.source[line_end] != '\n') : (line_end += 1) {}
            self.cursor = if (line_end < self.source.len) line_end + 1 else line_end;

            const line_no = self.line;
            self.line += 1;

            const code_line = lineWithoutTrailingComment(self.source[line_start..line_end], &self.in_block_comment) orelse continue;
            if (parseInclude(code_line, line_no)) |include| return include;
            if (parseCppImport(code_line, line_no)) |cpp_import| return cpp_import;
            if (parseZigImport(code_line, line_no)) |zig_import| return zig_import;
        }
        return null;
    }
};

fn lineWithoutTrailingComment(line: []const u8, in_block_comment: *bool) ?[]const u8 {
    if (in_block_comment.*) {
        const close = std.mem.indexOf(u8, line, "*/") orelse return null;
        in_block_comment.* = false;
        return lineWithoutTrailingComment(line[close + 2 ..], in_block_comment);
    }

    const line_comment = std.mem.indexOf(u8, line, "//");
    const block_comment = std.mem.indexOf(u8, line, "/*");

    const end = if (line_comment) |line_pos|
        if (block_comment) |block_pos| blk: {
            if (line_pos < block_pos) break :blk line_pos;
            in_block_comment.* = true;
            break :blk block_pos;
        } else line_pos
    else if (block_comment) |block_pos| blk: {
        in_block_comment.* = true;
        break :blk block_pos;
    } else line.len;

    return line[0..end];
}

fn parseInclude(line: []const u8, line_no: u32) ?ImportRef {
    var rest = trim(line);
    if (!std.mem.startsWith(u8, rest, "#")) return null;
    rest = trim(rest[1..]);
    if (!std.mem.startsWith(u8, rest, "include")) return null;
    rest = rest["include".len..];
    if (rest.len > 0 and isIdentByte(rest[0])) return null;
    return parseDelimitedImport(.c_include, rest, line_no);
}

fn parseCppImport(line: []const u8, line_no: u32) ?ImportRef {
    var rest = trim(line);
    if (!std.mem.startsWith(u8, rest, "import")) return null;
    rest = rest["import".len..];
    if (rest.len > 0 and isIdentByte(rest[0])) return null;
    rest = trim(rest);

    if (parseDelimitedImport(.cpp_import, rest, line_no)) |delimited| return delimited;

    const end = moduleImportEnd(rest);
    if (end == 0) return null;
    const raw = trim(rest[0..end]);
    if (raw.len == 0) return null;
    const normalized = normalizeImport(raw);
    return .{
        .kind = .cpp_import,
        .raw = raw,
        .normalized = normalized,
        .line = line_no,
        .domains = domainsForImport(normalized),
    };
}

fn parseZigImport(line: []const u8, line_no: u32) ?ImportRef {
    const marker = "@import";
    const pos = std.mem.indexOf(u8, line, marker) orelse return null;
    var rest = trim(line[pos + marker.len ..]);
    if (rest.len == 0 or rest[0] != '(') return null;
    rest = trim(rest[1..]);
    if (rest.len == 0 or rest[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    const raw = rest[0 .. close + 1];
    const normalized = normalizeImport(rest[1..close]);
    return .{
        .kind = .zig_import,
        .raw = raw,
        .normalized = normalized,
        .line = line_no,
        .domains = domainsForImport(normalized),
    };
}

fn parseDelimitedImport(kind: ImportKind, text: []const u8, line_no: u32) ?ImportRef {
    const rest = trim(text);
    if (rest.len < 2) return null;

    const close_char: u8 = switch (rest[0]) {
        '<' => '>',
        '"' => '"',
        else => return null,
    };

    const close = std.mem.indexOfScalarPos(u8, rest, 1, close_char) orelse return null;
    const raw = rest[0 .. close + 1];
    const normalized = normalizeImport(rest[1..close]);
    return .{
        .kind = kind,
        .raw = raw,
        .normalized = normalized,
        .line = line_no,
        .domains = domainsForImport(normalized),
    };
}

fn moduleImportEnd(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ';', ' ', '\t', '\r' => return i,
            else => {},
        }
    }
    return i;
}

pub fn domainsForImport(import_name: []const u8) DomainSet {
    const normalized = normalizeImport(import_name);
    var domains: DomainSet = .{};

    inline for (domain_rules) |rule| {
        inline for (rule.needles) |needle| {
            if (std.mem.indexOf(u8, normalized, needle) != null) {
                domains.add(rule.domain);
                break;
            }
        }
    }

    return domains;
}

const DomainRule = struct {
    domain: PhysicalDomain,
    needles: []const []const u8,
};

const domain_rules = [_]DomainRule{
    .{ .domain = .database, .needles = &.{ "sqlite3.h", "sqlite.h", "sqlite/", "libpq-fe.h", "mysql.h", "postgres", "rocksdb", "lmdb", "leveldb" } },
    .{ .domain = .dsp, .needles = &.{ "juce_audio_processors", "juce_audio_basics", "juce_dsp", "juce_audio_devices", "vst3", "audio_processor", "portaudio", "sndfile", "fftw", "aubio" } },
    .{ .domain = .graphics, .needles = &.{ "vulkan", "glfw", "opengl", "glad", "metal/", "d3d12", "directx", "wgpu", "sdl_video" } },
    .{ .domain = .network, .needles = &.{ "curl/", "curl.h", "asio", "winsock", "sys/socket.h", "netinet/", "arpa/inet.h", "openssl/ssl.h", "quic", "grpc" } },
    .{ .domain = .filesystem, .needles = &.{ "filesystem", "dirent.h", "sys/stat.h", "unistd.h", "fcntl.h", "fileapi.h" } },
    .{ .domain = .crypto, .needles = &.{ "openssl/", "sodium", "mbedtls", "wolfssl", "bcrypt.h", "cryptopp", "sha256", "blake3" } },
    .{ .domain = .ui, .needles = &.{ "juce_gui", "imgui", "gtk/", "qtwidgets", "uikit", "appkit", "x11/", "windows.h" } },
};

fn normalizeImport(import_name: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = import_name.len;

    while (start < end and isImportWrapper(import_name[start])) start += 1;
    while (end > start and isImportWrapper(import_name[end - 1])) end -= 1;

    while (start < end and (import_name[start] == '.' or import_name[start] == '/')) start += 1;
    return import_name[start..end];
}

fn isImportWrapper(byte: u8) bool {
    return byte == '<' or byte == '>' or byte == '"' or byte == '\'' or std.ascii.isWhitespace(byte);
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn isIdentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "scanner extracts C C++ and Zig imports with domain tags" {
    const source =
        \\#include <sqlite3.h>
        \\#include "neutral/local.h"
        \\import <juce_audio_processors/juce_audio_processors.h>;
        \\const std = @import("std");
        \\const vk = @import("vulkan");
    ;

    var imports = std.ArrayList(ImportRef).init(std.testing.allocator);
    defer imports.deinit();

    const domains = try scanImports(std.testing.allocator, source, &imports);
    try std.testing.expectEqual(@as(usize, 5), imports.items.len);
    try std.testing.expect(domains.contains(.database));
    try std.testing.expect(domains.contains(.dsp));
    try std.testing.expect(domains.contains(.graphics));
    try std.testing.expect(!domains.contains(.network));
}

test "cluster-level inference keeps DSP and DATABASE isolated" {
    const inputs = [_]TranslationUnitInput{
        .{
            .path = "plugin/audio_processor.cpp",
            .source =
            \\#include <juce_audio_processors/juce_audio_processors.h>
            \\#include "PluginProcessor.h"
            ,
        },
        .{
            .path = "storage/sqlite_store.c",
            .source =
            \\#include <sqlite3.h>
            \\#include "sqlite_store.h"
            ,
        },
        .{
            .path = "shared/logging.cpp",
            .source =
            \\#include "logging.h"
            ,
        },
    };

    var map = try inferDomainMap(std.testing.allocator, &inputs);
    defer map.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), map.translation_units.len);
    try std.testing.expectEqual(@as(usize, 3), map.clusters.len);

    const dsp_cluster = clusterByDomain(map.clusters, DomainSet.with(.dsp)).?;
    const database_cluster = clusterByDomain(map.clusters, DomainSet.with(.database)).?;
    const neutral_cluster = clusterByDomain(map.clusters, .{}).?;

    try std.testing.expectEqual(@as(usize, 1), dsp_cluster.translation_units.len);
    try std.testing.expectEqual(@as(usize, 1), database_cluster.translation_units.len);
    try std.testing.expectEqual(@as(usize, 1), neutral_cluster.translation_units.len);

    try std.testing.expectEqualStrings("plugin/audio_processor.cpp", map.translation_units[dsp_cluster.translation_units[0]].path);
    try std.testing.expectEqualStrings("storage/sqlite_store.c", map.translation_units[database_cluster.translation_units[0]].path);
    try std.testing.expectEqualStrings("shared/logging.cpp", map.translation_units[neutral_cluster.translation_units[0]].path);

    try std.testing.expect(!dsp_cluster.domains.contains(.database));
    try std.testing.expect(!database_cluster.domains.contains(.dsp));
}

test "comptime inference resolves static import graph without runtime setup" {
    const static = comptime inferDomainMapComptime(&.{
        .{
            .path = "audio/plugin.cpp",
            .source = "#include <juce_audio_processors/juce_audio_processors.h>\n",
        },
        .{
            .path = "db/store.cpp",
            .source = "#include <sqlite3.h>\n",
        },
    });

    try std.testing.expect(!static.overflow);
    try std.testing.expectEqual(@as(usize, 2), static.unitSlice().len);
    try std.testing.expectEqual(@as(usize, 2), static.clusterSlice().len);
    try std.testing.expect(static.clusterSlice()[0].domains.contains(.dsp));
    try std.testing.expect(static.clusterSlice()[1].domains.contains(.database));
}

fn clusterByDomain(clusters: []const SemanticCluster, domains: DomainSet) ?SemanticCluster {
    for (clusters) |cluster| {
        if (DomainSet.eql(cluster.domains, domains)) return cluster;
    }
    return null;
}
