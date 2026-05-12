const std = @import("std");
const search_client = @import("../net/search_client.zig");

pub const FallbackResult = struct {
    title: []const u8,
    url: []const u8,
    content: []const u8,
};

pub fn triggerLocalSearch(allocator: std.mem.Allocator, query: []const u8) ![]FallbackResult {
    const local_results = search_client.searchLocal(allocator, query) catch return allocator.alloc(FallbackResult, 0);
    defer search_client.freeSearchResults(allocator, local_results);
    var results = std.ArrayList(FallbackResult).init(allocator);
    errdefer {
        for (results.items) |res| {
            allocator.free(res.title);
            allocator.free(res.url);
            allocator.free(res.content);
        }
        results.deinit();
    }
    for (local_results) |res| {
        try results.append(.{
            .title = try allocator.dupe(u8, res.title),
            .url = try allocator.dupe(u8, res.url),
            .content = try allocator.dupe(u8, res.content),
        });
    }
    return results.toOwnedSlice();
}

pub fn freeFallbackResults(allocator: std.mem.Allocator, results: []FallbackResult) void {
    for (results) |res| {
        allocator.free(res.title);
        allocator.free(res.url);
        allocator.free(res.content);
    }
    allocator.free(results);
}
