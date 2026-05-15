const std = @import("std");

pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8888;
pub const MAX_QUERY_BYTES: usize = 1024;
pub const MAX_RESPONSE_BYTES: usize = 256 * 1024;
pub const MAX_RESULTS: usize = 8;

pub const SearchEndpoint = struct {
    host: []const u8 = DEFAULT_HOST,
    port: u16 = DEFAULT_PORT,

    pub fn baseUrl(self: SearchEndpoint, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ self.host, self.port });
    }
};

pub const SearchResult = struct {
    allocator: std.mem.Allocator,
    title: []u8,
    url: []u8,
    content: []u8,

    pub fn deinit(self: *SearchResult) void {
        self.allocator.free(self.title);
        self.allocator.free(self.url);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn endpointFromEnv() SearchEndpoint {
    var endpoint = SearchEndpoint{};
    if (std.posix.getenv("GHOST_SEARXNG_HOST")) |host| {
        if (host.len != 0) endpoint.host = host;
    }
    if (std.posix.getenv("GHOST_SEARXNG_PORT")) |port_text| {
        endpoint.port = std.fmt.parseInt(u16, port_text, 10) catch DEFAULT_PORT;
    }
    return endpoint;
}

pub fn renderSearchUrl(
    allocator: std.mem.Allocator,
    endpoint: SearchEndpoint,
    query: []const u8,
) ![]u8 {
    if (query.len == 0) return error.EmptySearchQuery;
    if (query.len > MAX_QUERY_BYTES) return error.SearchQueryTooLarge;
    if (!isLocalHost(endpoint.host)) return error.NonLocalSearchEndpoint;

    var escaped = std.ArrayList(u8).init(allocator);
    defer escaped.deinit();
    try percentEncode(escaped.writer(), query);

    const base = try endpoint.baseUrl(allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/search?q={s}&format=json", .{ base, escaped.items });
}

pub fn searchLocal(allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
    const url = try renderSearchUrl(allocator, endpointFromEnv(), query);
    defer allocator.free(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
        .max_append_size = MAX_RESPONSE_BYTES,
        .keep_alive = false,
    });
    if (response.status != .ok) return error.SearchHttpFailed;
    return parseSearchResults(allocator, body.items);
}

pub fn parseSearchResults(allocator: std.mem.Allocator, json_text: []const u8) ![]SearchResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSearchResponse;
    const results_value = parsed.value.object.get("results") orelse return allocator.alloc(SearchResult, 0);
    if (results_value != .array) return error.InvalidSearchResponse;

    var out = std.ArrayList(SearchResult).init(allocator);
    errdefer {
        for (out.items) |*result| result.deinit();
        out.deinit();
    }
    for (results_value.array.items) |item| {
        if (out.items.len >= MAX_RESULTS) break;
        if (item != .object) continue;
        const obj = item.object;
        try out.append(.{
            .allocator = allocator,
            .title = try allocator.dupe(u8, stringField(obj, "title")),
            .url = try allocator.dupe(u8, stringField(obj, "url")),
            .content = try allocator.dupe(u8, stringField(obj, "content")),
        });
    }
    return out.toOwnedSlice();
}

pub fn freeSearchResults(allocator: std.mem.Allocator, results: []SearchResult) void {
    for (results) |*result| result.deinit();
    allocator.free(results);
}

pub fn discoverPipRequirement(allocator: std.mem.Allocator, module_name: []const u8, diagnostic: []const u8) !?[]u8 {
    return discoverPipRequirementForYear(allocator, module_name, diagnostic, null);
}

pub fn discoverPipRequirementForYear(allocator: std.mem.Allocator, module_name: []const u8, diagnostic: []const u8, commit_year: ?u16) !?[]u8 {
    if (!isSafeModuleName(module_name)) return null;
    const query = if (commit_year) |year|
        try std.fmt.allocPrint(allocator, "python ImportError No module named {s} pip install {s} release before {d} legacy version", .{ module_name, module_name, year })
    else
        try std.fmt.allocPrint(allocator, "python ImportError No module named {s} pip install {s}", .{ module_name, module_name });
    defer allocator.free(query);
    return discoverInstallToken(allocator, query, diagnostic, .pip);
}

pub fn discoverNpmPackage(allocator: std.mem.Allocator, module_name: []const u8, diagnostic: []const u8) !?[]u8 {
    return discoverNpmPackageForYear(allocator, module_name, diagnostic, null);
}

pub fn discoverNpmPackageForYear(allocator: std.mem.Allocator, module_name: []const u8, diagnostic: []const u8, commit_year: ?u16) !?[]u8 {
    if (!isSafeNpmPackage(module_name)) return null;
    const query = if (commit_year) |year|
        try std.fmt.allocPrint(allocator, "node Cannot find module {s} npm install {s} release before {d} legacy version", .{ module_name, module_name, year })
    else
        try std.fmt.allocPrint(allocator, "node Cannot find module {s} npm install {s}", .{ module_name, module_name });
    defer allocator.free(query);
    return discoverInstallToken(allocator, query, diagnostic, .npm);
}

fn percentEncode(writer: anytype, text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else if (byte == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0F]);
        }
    }
}

const InstallKind = enum { pip, npm };

fn discoverInstallToken(allocator: std.mem.Allocator, query: []const u8, diagnostic: []const u8, kind: InstallKind) !?[]u8 {
    const results = searchLocal(allocator, query) catch return null;
    defer freeSearchResults(allocator, results);

    for (results) |result| {
        if (extractInstallToken(result.content, kind)) |token| {
            const copied = try allocator.dupe(u8, token);
            return copied;
        }
        if (extractInstallToken(result.title, kind)) |token| {
            const copied = try allocator.dupe(u8, token);
            return copied;
        }
        if (extractPackageTokenFromResult(result, kind)) |token| {
            const copied = try allocator.dupe(u8, token);
            return copied;
        }
    }
    if (extractInstallToken(diagnostic, kind)) |token| {
        const copied = try allocator.dupe(u8, token);
        return copied;
    }
    return null;
}

fn extractPackageTokenFromResult(result: SearchResult, kind: InstallKind) ?[]const u8 {
    return switch (kind) {
        .pip => extractPypiToken(result.url) orelse extractTitleSuffix(result.title, " - PyPI", isSafeRequirementSpec),
        .npm => extractNpmToken(result.url) orelse extractTitleSuffix(result.title, " - npm", isSafeNpmPackage),
    };
}

fn extractPypiToken(url: []const u8) ?[]const u8 {
    const marker = "/project/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const after = url[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const token = after[0..end];
    return if (isSafeRequirementSpec(token)) token else null;
}

fn extractNpmToken(url: []const u8) ?[]const u8 {
    const marker = "npmjs.com/package/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const after = url[start + marker.len ..];
    const end = std.mem.indexOfAny(u8, after, "?#") orelse after.len;
    const token = std.mem.trimRight(u8, after[0..end], "/");
    return if (isSafeNpmPackage(token)) token else null;
}

fn extractTitleSuffix(title: []const u8, suffix: []const u8, comptime safeFn: fn ([]const u8) bool) ?[]const u8 {
    if (!std.mem.endsWith(u8, title, suffix)) return null;
    const token = std.mem.trim(u8, title[0 .. title.len - suffix.len], " \t\r\n");
    return if (safeFn(token)) token else null;
}

pub fn extractPipRequirement(text: []const u8) ?[]const u8 {
    return extractInstallToken(text, .pip);
}

pub fn extractNpmPackage(text: []const u8) ?[]const u8 {
    return extractInstallToken(text, .npm);
}

fn extractInstallToken(text: []const u8, kind: InstallKind) ?[]const u8 {
    const prefixes = switch (kind) {
        .pip => &[_][]const u8{ "python -m pip install", "pip3 install", "pip install" },
        .npm => &[_][]const u8{ "npm install", "npm i" },
    };
    for (prefixes) |prefix| {
        if (indexOfIgnoreCase(text, prefix)) |idx| {
            var rest = std.mem.trimLeft(u8, text[idx + prefix.len ..], " \t\r\n`'\"");
            while (rest.len != 0) {
                const token_end = tokenEnd(rest);
                const raw = std.mem.trim(u8, rest[0..token_end], " \t\r\n`'\".,;:)");
                if (raw.len != 0 and raw[0] != '-') {
                    if (kind == .pip and isSafeRequirementSpec(raw)) return raw;
                    if (kind == .npm and isSafeNpmPackage(raw)) return raw;
                    return null;
                }
                if (token_end >= rest.len) break;
                rest = std.mem.trimLeft(u8, rest[token_end..], " \t\r\n`'\"");
            }
        }
    }
    return null;
}

fn tokenEnd(text: []const u8) usize {
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (std.ascii.isWhitespace(text[idx]) or text[idx] == '`' or text[idx] == '\'' or text[idx] == '"' or text[idx] == ',') break;
    }
    return idx;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = obj.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

fn isLocalHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.startsWith(u8, host, "127.");
}

fn isSafeModuleName(name: []const u8) bool {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return name.len != 0 and name.len <= 128;
}

fn isSafeRequirementSpec(name: []const u8) bool {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '<' or ch == '>' or ch == '=' or ch == '!' or ch == '~') continue;
        return false;
    }
    return name.len != 0 and name.len <= 128;
}

fn isSafeNpmPackage(name: []const u8) bool {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '@' or ch == '/') continue;
        return false;
    }
    return name.len != 0 and name.len <= 160 and std.mem.indexOf(u8, name, "..") == null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

test "search URL targets local native SearXNG JSON endpoint" {
    const allocator = std.testing.allocator;
    const url = try renderSearchUrl(allocator, .{}, "AutumnBench 2026 prompt");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8888/search?q=AutumnBench+2026+prompt&format=json",
        url,
    );
}

test "search query is bounded" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.EmptySearchQuery, renderSearchUrl(allocator, .{}, ""));
    var query: [MAX_QUERY_BYTES + 1]u8 = undefined;
    @memset(&query, 'a');
    try std.testing.expectError(error.SearchQueryTooLarge, renderSearchUrl(allocator, .{}, &query));
    try std.testing.expectError(error.NonLocalSearchEndpoint, renderSearchUrl(allocator, .{ .host = "searx.example.com" }, "query"));
}

test "SearXNG JSON parser extracts bounded results" {
    const allocator = std.testing.allocator;
    const results = try parseSearchResults(allocator,
        \\{"results":[{"title":"PyPI","url":"http://127.0.0.1/r","content":"Use pip install PyQt5 for Qt bindings."}]}
    );
    defer freeSearchResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("PyPI", results[0].title);
}

test "install command extraction stays package-token bounded" {
    try std.testing.expectEqualStrings("PyQt5", extractPipRequirement("docs say: python -m pip install PyQt5").?);
    try std.testing.expectEqualStrings("@scope/pkg", extractNpmPackage("try npm install @scope/pkg").?);
    try std.testing.expect(extractPipRequirement("pip install bad;rm") == null);
    try std.testing.expectEqualStrings("PyQt5", extractPypiToken("https://pypi.org/project/PyQt5/").?);
    try std.testing.expectEqualStrings("@scope/pkg", extractNpmToken("https://www.npmjs.com/package/@scope/pkg").?);
}

test "time-aware discovery query remains local and bounded" {
    const allocator = std.testing.allocator;
    const url = try renderSearchUrl(allocator, .{}, "python ImportError No module named babel._compat pip install babel._compat release before 2017 legacy version");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "before+2017") != null);
}
