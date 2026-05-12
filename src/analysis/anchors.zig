const std = @import("std");
const inference = @import("domain_inference");

pub const MAX_FUNCTIONS: usize = 96;
pub const MAX_CALLS: usize = 512;
pub const MAX_SINKS: usize = 64;
pub const MAX_REACHABLE: usize = MAX_FUNCTIONS;

pub const DiscoveryTier = enum {
    hal_sink,
    public_interface_fallback,
    none,
};

pub const AnchorFailure = enum {
    none,
    no_domain_for_unit,
    no_functions,
    no_hal_sink,
    no_public_interface,
    test_double_ignored,
    capacity_exceeded,
};

pub const Anchor = struct {
    function_name: []const u8,
    line: u32,
    tier: DiscoveryTier,
    domain: ?inference.PhysicalDomain = null,
    sink_name: ?[]const u8 = null,
    score: u32 = 0,
};

pub const FunctionNode = struct {
    name: []const u8,
    line: u32,
    body_start: usize,
    body_end: usize,
    public_api: bool,
    test_double: bool,
    call_start: usize = 0,
    call_len: usize = 0,
    sink_start: usize = 0,
    sink_len: usize = 0,
};

pub const CallEdge = struct {
    caller: usize,
    callee_name: []const u8,
    callee: ?usize = null,
    line: u32,
};

pub const SinkHit = struct {
    function_index: usize,
    sink_name: []const u8,
    line: u32,
    domain: inference.PhysicalDomain,
};

pub const AnchorResult = struct {
    path: []const u8,
    tier: DiscoveryTier = .none,
    anchor: ?Anchor = null,
    failure: AnchorFailure = .none,
    domains: inference.DomainSet = .{},
    functions: [MAX_FUNCTIONS]FunctionNode = undefined,
    function_len: usize = 0,
    calls: [MAX_CALLS]CallEdge = undefined,
    call_len: usize = 0,
    sinks: [MAX_SINKS]SinkHit = undefined,
    sink_len: usize = 0,
    overflow: bool = false,

    pub fn functionSlice(self: *const AnchorResult) []const FunctionNode {
        return self.functions[0..self.function_len];
    }

    pub fn callSlice(self: *const AnchorResult) []const CallEdge {
        return self.calls[0..self.call_len];
    }

    pub fn sinkSlice(self: *const AnchorResult) []const SinkHit {
        return self.sinks[0..self.sink_len];
    }
};

pub fn discoverAnchorForUnit(
    source: []const u8,
    path: []const u8,
    domain_map: inference.DomainMap,
) AnchorResult {
    const domains = domainsForPath(path, domain_map) orelse {
        return .{
            .path = path,
            .failure = .no_domain_for_unit,
        };
    };
    return discoverAnchorForDomains(source, path, domains);
}

pub fn discoverAnchorForStaticUnit(
    comptime source: []const u8,
    comptime path: []const u8,
    comptime domain_map: inference.StaticDomainMap,
) AnchorResult {
    const domains = comptime staticDomainsForPath(path, domain_map) orelse {
        return .{
            .path = path,
            .failure = .no_domain_for_unit,
        };
    };
    return comptime discoverAnchorForDomainsComptime(source, path, domains);
}

pub fn discoverAnchorForDomains(
    source: []const u8,
    path: []const u8,
    domains: inference.DomainSet,
) AnchorResult {
    var result = parseTranslationUnit(source, path, domains);
    if (result.overflow) {
        result.failure = .capacity_exceeded;
        return result;
    }
    if (result.function_len == 0) {
        result.failure = .no_functions;
        return result;
    }
    if (isTestDoubleUnit(path, source)) {
        result.failure = .test_double_ignored;
        result.anchor = null;
        result.tier = .none;
        return result;
    }

    if (discoverTier1(&result)) |anchor| {
        result.tier = .hal_sink;
        result.anchor = anchor;
        result.failure = .none;
        return result;
    }

    if (discoverTier2(&result)) |anchor| {
        result.tier = .public_interface_fallback;
        result.anchor = anchor;
        result.failure = .no_hal_sink;
        return result;
    }

    result.failure = .no_public_interface;
    return result;
}

pub fn discoverAnchorForDomainsComptime(
    comptime source: []const u8,
    comptime path: []const u8,
    comptime domains: inference.DomainSet,
) AnchorResult {
    @setEvalBranchQuota(source.len * 64 + 8192);
    return comptime discoverAnchorForDomains(source, path, domains);
}

fn domainsForPath(path: []const u8, domain_map: inference.DomainMap) ?inference.DomainSet {
    for (domain_map.translation_units) |unit| {
        if (std.mem.eql(u8, unit.path, path)) return unit.domains;
    }
    return null;
}

fn staticDomainsForPath(comptime path: []const u8, comptime domain_map: inference.StaticDomainMap) ?inference.DomainSet {
    for (domain_map.unitSlice()) |unit| {
        if (std.mem.eql(u8, unit.path, path)) return unit.domains;
    }
    return null;
}

fn parseTranslationUnit(
    source: []const u8,
    path: []const u8,
    domains: inference.DomainSet,
) AnchorResult {
    var result: AnchorResult = .{
        .path = path,
        .domains = domains,
    };

    var cursor: usize = 0;
    while (cursor < source.len) {
        const open_brace = indexOfScalarPos(source, cursor, '{') orelse break;
        const header = functionHeaderBefore(source, open_brace) orelse {
            cursor = open_brace + 1;
            continue;
        };
        const close_brace = matchingBrace(source, open_brace) orelse {
            cursor = open_brace + 1;
            continue;
        };

        if (result.function_len >= MAX_FUNCTIONS) {
            result.overflow = true;
            return result;
        }

        result.functions[result.function_len] = .{
            .name = header.name,
            .line = lineForOffset(source, header.name_start),
            .body_start = open_brace + 1,
            .body_end = close_brace,
            .public_api = isPublicFunctionHeader(header.header, header.name),
            .test_double = isTestDoubleName(header.name),
        };
        result.function_len += 1;
        cursor = close_brace + 1;
    }

    var function_index: usize = 0;
    while (function_index < result.function_len) : (function_index += 1) {
        scanFunctionBody(source, &result, function_index);
    }
    resolveCalls(&result);
    return result;
}

fn scanFunctionBody(source: []const u8, result: *AnchorResult, function_index: usize) void {
    var function = &result.functions[function_index];
    const body = source[function.body_start..function.body_end];
    function.call_start = result.call_len;
    function.sink_start = result.sink_len;

    for (hal_sink_rules) |rule| {
        if (!result.domains.contains(rule.domain)) continue;
        if (function.test_double) continue;

        var search: usize = 0;
        while (indexOfNameCall(body, rule.name, search)) |hit| {
            if (result.sink_len >= MAX_SINKS) {
                result.overflow = true;
                return;
            }
            result.sinks[result.sink_len] = .{
                .function_index = function_index,
                .sink_name = rule.name,
                .line = lineForOffset(source, function.body_start + hit),
                .domain = rule.domain,
            };
            result.sink_len += 1;
            search = hit + rule.name.len;
        }
    }

    var scan: usize = 0;
    while (scan < body.len) {
        const paren = indexOfScalarPos(body, scan, '(') orelse break;
        const name_bounds = identifierBefore(body, paren) orelse {
            scan = paren + 1;
            continue;
        };
        const name = body[name_bounds.start..name_bounds.end];
        scan = paren + 1;

        if (isControlKeyword(name) or isBuiltinLike(name) or isTypeLikeCall(name)) continue;
        if (result.call_len >= MAX_CALLS) {
            result.overflow = true;
            return;
        }
        result.calls[result.call_len] = .{
            .caller = function_index,
            .callee_name = name,
            .line = lineForOffset(source, function.body_start + name_bounds.start),
        };
        result.call_len += 1;
    }

    function.call_len = result.call_len - function.call_start;
    function.sink_len = result.sink_len - function.sink_start;
}

fn resolveCalls(result: *AnchorResult) void {
    var call_index: usize = 0;
    while (call_index < result.call_len) : (call_index += 1) {
        result.calls[call_index].callee = findFunctionByName(result.functionSlice(), result.calls[call_index].callee_name);
    }
}

fn discoverTier1(result: *const AnchorResult) ?Anchor {
    if (result.sink_len == 0) return null;

    var best: ?Anchor = null;
    var best_function_index: usize = 0;
    var sink_index: usize = 0;
    while (sink_index < result.sink_len) : (sink_index += 1) {
        const sink = result.sinks[sink_index];
        var reaches = [_]bool{false} ** MAX_FUNCTIONS;
        reaches[sink.function_index] = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (result.callSlice()) |call| {
                if (call.callee) |callee| {
                    if (callee < reaches.len and reaches[callee] and !reaches[call.caller]) {
                        reaches[call.caller] = true;
                        changed = true;
                    }
                }
            }
        }

        var candidate_index: usize = sink.function_index;
        var candidate_score: u32 = 0;
        var i: usize = 0;
        while (i < result.function_len) : (i += 1) {
            if (!reaches[i] or result.functions[i].test_double) continue;
            if (hasReachingCaller(result, reaches, i)) continue;
            const depth = longestPathTo(result, i, sink.function_index, 0);
            const public_bonus: u32 = if (result.functions[i].public_api) 10_000 else 0;
            const score = public_bonus + depth;
            if (score > candidate_score or
                (score == candidate_score and result.functions[i].line < result.functions[candidate_index].line))
            {
                candidate_index = i;
                candidate_score = score;
            }
        }

        const candidate = result.functions[candidate_index];
        const anchor: Anchor = .{
            .function_name = candidate.name,
            .line = candidate.line,
            .tier = .hal_sink,
            .domain = sink.domain,
            .sink_name = sink.sink_name,
            .score = candidate_score,
        };

        if (best == null or anchor.score > best.?.score or
            (anchor.score == best.?.score and candidate.line < result.functions[best_function_index].line))
        {
            best = anchor;
            best_function_index = candidate_index;
        }
    }

    return best;
}

fn discoverTier2(result: *const AnchorResult) ?Anchor {
    var best: ?Anchor = null;
    var best_line: u32 = std.math.maxInt(u32);

    var function_index: usize = 0;
    while (function_index < result.function_len) : (function_index += 1) {
        const function = result.functions[function_index];
        if (!function.public_api or function.test_double) continue;

        const fan_in = reachableInternalFanIn(result, function_index);
        if (best == null or fan_in > best.?.score or
            (fan_in == best.?.score and function.line < best_line))
        {
            best = .{
                .function_name = function.name,
                .line = function.line,
                .tier = .public_interface_fallback,
                .domain = null,
                .sink_name = null,
                .score = fan_in,
            };
            best_line = function.line;
        }
    }

    return best;
}

pub fn comptimeReachableInternalFanIn(comptime result: AnchorResult, comptime function_index: usize) u32 {
    @setEvalBranchQuota(MAX_FUNCTIONS * MAX_CALLS * 8);
    return comptime reachableInternalFanIn(&result, function_index);
}

fn reachableInternalFanIn(result: *const AnchorResult, function_index: usize) u32 {
    var reachable = [_]bool{false} ** MAX_FUNCTIONS;
    markReachableCallees(result, function_index, &reachable);

    var count: u32 = 0;
    var i: usize = 0;
    while (i < result.function_len) : (i += 1) {
        if (i != function_index and reachable[i] and !result.functions[i].public_api) count += 1;
    }
    return count;
}

fn markReachableCallees(result: *const AnchorResult, function_index: usize, reachable: *[MAX_FUNCTIONS]bool) void {
    var call_index: usize = result.functions[function_index].call_start;
    const end = call_index + result.functions[function_index].call_len;
    while (call_index < end) : (call_index += 1) {
        if (result.calls[call_index].callee) |callee| {
            if (reachable[callee]) continue;
            reachable[callee] = true;
            markReachableCallees(result, callee, reachable);
        }
    }
}

fn hasReachingCaller(result: *const AnchorResult, reaches: [MAX_FUNCTIONS]bool, function_index: usize) bool {
    for (result.callSlice()) |call| {
        if (call.callee != null and call.callee.? == function_index and reaches[call.caller]) return true;
    }
    return false;
}

fn longestPathTo(result: *const AnchorResult, from: usize, target: usize, depth: u32) u32 {
    if (from == target) return depth;
    var best: u32 = 0;
    const function = result.functions[from];
    var call_index = function.call_start;
    const end = function.call_start + function.call_len;
    while (call_index < end) : (call_index += 1) {
        if (result.calls[call_index].callee) |callee| {
            if (depth >= MAX_REACHABLE) return depth;
            const candidate = longestPathTo(result, callee, target, depth + 1);
            if (candidate > best) best = candidate;
        }
    }
    return best;
}

const HalSinkRule = struct {
    name: []const u8,
    domain: inference.PhysicalDomain,
};

const hal_sink_rules = [_]HalSinkRule{
    .{ .name = "vkQueueSubmit", .domain = .graphics },
    .{ .name = "vkQueuePresentKHR", .domain = .graphics },
    .{ .name = "vkCmdDraw", .domain = .graphics },
    .{ .name = "write", .domain = .filesystem },
    .{ .name = "pwrite", .domain = .filesystem },
    .{ .name = "send", .domain = .network },
    .{ .name = "sendto", .domain = .network },
    .{ .name = "SSL_write", .domain = .network },
    .{ .name = "processBlock", .domain = .dsp },
    .{ .name = "audioDeviceIOCallback", .domain = .dsp },
    .{ .name = "sqlite3_step", .domain = .database },
};

const Header = struct {
    header: []const u8,
    name: []const u8,
    name_start: usize,
};

const Bounds = struct {
    start: usize,
    end: usize,
};

fn functionHeaderBefore(source: []const u8, open_brace: usize) ?Header {
    var close_paren = open_brace;
    while (close_paren > 0 and std.ascii.isWhitespace(source[close_paren - 1])) close_paren -= 1;
    if (close_paren == 0 or source[close_paren - 1] != ')') return null;
    close_paren -= 1;

    const open_paren = matchingOpenParen(source, close_paren) orelse return null;
    const name_bounds = identifierBefore(source, open_paren) orelse return null;
    const name = source[name_bounds.start..name_bounds.end];
    if (isControlKeyword(name) or isBuiltinLike(name)) return null;

    const header_start = headerStart(source, name_bounds.start);
    const header = source[header_start..open_brace];
    if (std.mem.indexOfScalar(u8, header, ';') != null) return null;
    if (std.mem.indexOfScalar(u8, header, '=') != null and !std.mem.startsWith(u8, std.mem.trim(u8, header, " \t\r\n"), "operator")) return null;

    return .{
        .header = header,
        .name = name,
        .name_start = name_bounds.start,
    };
}

fn headerStart(source: []const u8, name_start: usize) usize {
    var i = name_start;
    while (i > 0) : (i -= 1) {
        switch (source[i - 1]) {
            '}', ';', '\n' => return i,
            else => {},
        }
    }
    return 0;
}

fn matchingOpenParen(source: []const u8, close_paren: usize) ?usize {
    var depth: usize = 1;
    var i = close_paren;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn matchingBrace(source: []const u8, open_brace: usize) ?usize {
    var depth: usize = 1;
    var i = open_brace + 1;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn identifierBefore(source: []const u8, offset: usize) ?Bounds {
    if (offset == 0) return null;
    var end = offset;
    while (end > 0 and std.ascii.isWhitespace(source[end - 1])) end -= 1;
    while (end > 0 and source[end - 1] == ':') end -= 1;
    if (end == 0 or !isIdentTail(source[end - 1])) return null;

    var start = end - 1;
    while (start > 0 and isIdentBody(source[start - 1])) start -= 1;
    return .{ .start = start, .end = end };
}

fn isPublicFunctionHeader(header: []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, header, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "pub fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "export fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "static ")) return false;
    if (std.mem.startsWith(u8, trimmed, "private:")) return false;
    if (std.mem.indexOf(u8, trimmed, " static ") != null) return false;
    if (std.mem.startsWith(u8, name, "_")) return false;
    return true;
}

fn indexOfNameCall(text: []const u8, name: []const u8, start: usize) ?usize {
    var search = start;
    while (std.mem.indexOfPos(u8, text, search, name)) |hit| {
        const before_ok = hit == 0 or !isIdentBody(text[hit - 1]);
        const after_name = hit + name.len;
        var after = after_name;
        while (after < text.len and std.ascii.isWhitespace(text[after])) after += 1;
        const after_ok = after < text.len and text[after] == '(';
        if (before_ok and after_ok) return hit;
        search = after_name;
    }
    return null;
}

fn findFunctionByName(functions: []const FunctionNode, name: []const u8) ?usize {
    for (functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, name)) return index;
    }
    return null;
}

fn lineForOffset(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

fn indexOfScalarPos(source: []const u8, start: usize, byte: u8) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == byte) return i;
    }
    return null;
}

fn isControlKeyword(name: []const u8) bool {
    inline for (.{ "if", "for", "while", "switch", "return", "sizeof", "catch", "defer", "errdefer" }) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn isBuiltinLike(name: []const u8) bool {
    return name.len > 0 and name[0] == '@';
}

fn isTypeLikeCall(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

fn isIdentTail(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isIdentBody(byte: u8) bool {
    return isIdentTail(byte) or byte == ':';
}

fn isTestDoubleUnit(path: []const u8, source: []const u8) bool {
    return containsAnyFold(path, &.{ "test", "tests", "mock", "mocks", "fake", "fakes", "fixture", "fixtures" }) or
        containsAnyFold(source, &.{ "gmock", "gtest", "catch2", "doctest", "mock_framework", "test_double" });
}

fn isTestDoubleName(name: []const u8) bool {
    return containsAnyFold(name, &.{ "mock", "fake", "stub", "test" });
}

fn containsAnyFold(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfFold(text, needle) != null) return true;
    }
    return false;
}

fn indexOfFold(text: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > text.len) return null;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}

test "tier 1 traces HAL sink upward through graphics domain" {
    const source =
        \\#include <vulkan/vulkan.h>
        \\
        \\static void submit_frame() {
        \\    vkQueueSubmit(queue, 1, &submit, fence);
        \\}
        \\
        \\void render_frame() {
        \\    submit_frame();
        \\}
    ;
    const domain_map = comptime inference.inferDomainMapComptime(&.{
        .{ .path = "renderer/vulkan_backend.cpp", .source = source },
    });

    const result = comptime discoverAnchorForStaticUnit(source, "renderer/vulkan_backend.cpp", domain_map);
    try std.testing.expectEqual(DiscoveryTier.hal_sink, result.tier);
    try std.testing.expect(result.anchor != null);
    try std.testing.expectEqualStrings("render_frame", result.anchor.?.function_name);
    try std.testing.expectEqual(inference.PhysicalDomain.graphics, result.anchor.?.domain.?);
    try std.testing.expectEqualStrings("vkQueueSubmit", result.anchor.?.sink_name.?);
}

test "tier 1 ignores mock HAL sinks without polluting real domain anchors" {
    const source =
        \\#include <vulkan/vulkan.h>
        \\void fake_submit() {
        \\    vkQueueSubmit(queue, 1, &submit, fence);
        \\}
    ;
    const domain_map = comptime inference.inferDomainMapComptime(&.{
        .{ .path = "tests/mock_vulkan_backend.cpp", .source = source },
    });

    const result = comptime discoverAnchorForStaticUnit(source, "tests/mock_vulkan_backend.cpp", domain_map);
    try std.testing.expectEqual(DiscoveryTier.none, result.tier);
    try std.testing.expectEqual(AnchorFailure.test_double_ignored, result.failure);
    try std.testing.expect(result.anchor == null);
}

test "tier 2 selects public library API with deepest internal fan-in at comptime" {
    const source =
        \\static int rotate(int x) { return x + 1; }
        \\static int mix(int x) { return rotate(x) ^ 7; }
        \\static int compress(int x) { return mix(x) + rotate(x); }
        \\int hash_bytes(const unsigned char *data, int len) {
        \\    return compress(len);
        \\}
        \\int version(void) {
        \\    return 1;
        \\}
    ;
    const domain_map = comptime inference.inferDomainMapComptime(&.{
        .{ .path = "crypto/hash.c", .source = source },
    });

    const result = comptime discoverAnchorForStaticUnit(source, "crypto/hash.c", domain_map);
    try std.testing.expectEqual(DiscoveryTier.public_interface_fallback, result.tier);
    try std.testing.expect(result.anchor != null);
    try std.testing.expectEqualStrings("hash_bytes", result.anchor.?.function_name);
    try std.testing.expectEqual(@as(u32, 3), result.anchor.?.score);
}
