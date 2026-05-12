const std = @import("std");

pub const DEFAULT_SOCKET_PATH = "/tmp/ghost.sock";
pub const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;

pub fn socketPath() []const u8 {
    return std.posix.getenv("GHOSTD_SOCKET_PATH") orelse DEFAULT_SOCKET_PATH;
}

pub fn connect() !std.net.Stream {
    return std.net.connectUnixSocket(socketPath());
}

pub fn readFrame(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try stream.reader().readNoEof(&len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len > MAX_FRAME_BYTES) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    try stream.reader().readNoEof(payload);
    return payload;
}

pub fn writeFrame(stream: std.net.Stream, payload: []const u8) !void {
    if (payload.len > MAX_FRAME_BYTES) return error.FrameTooLarge;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
    try stream.writer().writeAll(&len_buf);
    try stream.writer().writeAll(payload);
}

pub fn request(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var stream = try connect();
    defer stream.close();
    try writeFrame(stream, payload);
    return readFrame(allocator, stream);
}

pub fn renderStatusRequest(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"kind\":\"daemon.status\"}");
}

pub fn renderWatchRequest(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"kind\":\"sigil.watch\"}");
}

pub fn renderInjectRequest(allocator: std.mem.Allocator, intent: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"kind\":\"sigil.inject\",\"semanticIntent\":");
    try std.json.stringify(intent, .{}, w);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

pub fn renderCommitRequest(allocator: std.mem.Allocator, rune_ref: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"kind\":\"sigil.commit\",\"runeRef\":");
    try std.json.stringify(rune_ref, .{}, w);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

pub fn renderReloadPluginRequest(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"kind\":\"sigil.reloadPlugin\",\"path\":");
    try std.json.stringify(path, .{}, w);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

test "inject request escapes semantic intent" {
    const allocator = std.testing.allocator;
    const request_json = try renderInjectRequest(allocator, "warm \"tape\"");
    defer allocator.free(request_json);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "\\\"tape\\\"") != null);
}
