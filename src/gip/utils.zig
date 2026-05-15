const std = @import("std");
const gip_core = @import("../gip_core.zig");
const correction_review = @import("../correction_review.zig");

pub fn writeCountEntriesJson(w: anytype, entries: []const correction_review.CountEntry) !void {
    try w.writeByte('{');
    for (entries, 0..) |entry, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.encodeJsonString(entry.name, .{}, w);
        try w.writeByte(':');
        try std.fmt.format(w, "{d}", .{entry.count});
    }
    try w.writeByte('}');
}

pub fn countNamed(entries: []const correction_review.CountEntry, name: []const u8) usize {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.count;
    }
    return 0;
}

pub fn writeReadWarningsJson(w: anytype, warnings: []const correction_review.ReadWarning) !void {
    try w.writeByte('[');
    for (warnings, 0..) |warning, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.writeAll("\"line_number\":");
        try std.fmt.format(w, "{d}", .{warning.line_number});
        try w.writeAll(",\"message\":");
        try std.json.encodeJsonString(warning.reason, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}



pub fn getStr(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?[]const u8 {
    if (obj.get(snake)) |v| if (v == .string) return v.string;
    if (obj.get(camel)) |v| if (v == .string) return v.string;
    return null;
}

pub fn getBool(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?bool {
    if (obj.get(snake)) |v| if (v == .bool) return v.bool;
    if (obj.get(camel)) |v| if (v == .bool) return v.bool;
    return null;
}

pub fn getInt(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8) ?i64 {
    if (obj.get(snake)) |v| if (v == .integer) return v.integer;
    if (obj.get(camel)) |v| if (v == .integer) return v.integer;
    return null;
}

pub fn boundedCount(obj: std.json.ObjectMap, snake: []const u8, camel: []const u8, default_value: usize, max_value: usize) usize {
    const requested = getInt(obj, snake, camel) orelse return default_value;
    if (requested <= 0) return 0;
    return @min(@as(usize, @intCast(requested)), max_value);
}

pub fn writeNegativeKnowledgeReadWarningsJson(w: anytype, warnings: anytype) !void {
    try w.writeByte('[');
    for (warnings, 0..) |warning, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.writeAll("\"line_number\":");
        try std.fmt.format(w, "{d}", .{warning.line_number});
        try w.writeAll(",\"message\":");
        try std.json.encodeJsonString(warning.reason, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

pub fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

pub fn getSpanText(file_content: []const u8, start_line: usize, start_col: usize, end_line: usize, end_col: usize) ?[]const u8 {
    if (start_line < 1 or end_line < 1 or start_col < 1 or end_col < 1) return null;
    if (start_line > end_line) return null;
    if (start_line == end_line and start_col > end_col) return null;

    var line_num: usize = 1;
    var offset: usize = 0;
    var span_start: ?usize = null;
    var span_end: ?usize = null;

    while (offset < file_content.len) {
        if (line_num == start_line and span_start == null) span_start = offset + start_col - 1;
        if (line_num == end_line and span_end == null) span_end = offset + end_col - 1;
        if (file_content[offset] == '\n') line_num += 1;
        offset += 1;
    }
    if (line_num == start_line and span_start == null) span_start = offset + start_col - 1;
    if (line_num == end_line and span_end == null) span_end = offset + end_col - 1;

    if (span_start) |s| {
        if (span_end) |e| {
            if (s <= e and e <= file_content.len and s <= file_content.len) return file_content[s..e];
        }
    }
    return null;
}

pub fn boundedMaxItems(obj: std.json.ObjectMap, default_value: usize, max_value: usize) usize {
    const requested = getInt(obj, "max_items", "maxItems") orelse return default_value;
    if (requested <= 0) return 0;
    return @min(@as(usize, @intCast(requested)), max_value);
}


