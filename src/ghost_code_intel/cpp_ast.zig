const std = @import("std");

pub const Summary = struct {
    text: []u8,
    symbol_count: usize,
    inheritance_count: usize,
    virtual_count: usize,
    template_count: usize,
    call_edge_count: usize,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn isCppPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cpp") or
        std.ascii.eqlIgnoreCase(ext, ".cc") or
        std.ascii.eqlIgnoreCase(ext, ".cxx") or
        std.ascii.eqlIgnoreCase(ext, ".h") or
        std.ascii.eqlIgnoreCase(ext, ".hh") or
        std.ascii.eqlIgnoreCase(ext, ".hpp") or
        std.ascii.eqlIgnoreCase(ext, ".hxx") or
        std.ascii.eqlIgnoreCase(ext, ".ipp");
}

pub fn extract(allocator: std.mem.Allocator, source_root: []const u8, rel_path: []const u8, bytes: []const u8) !?Summary {
    if (!isCppPath(rel_path)) return null;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    const compile_commands = try compileCommandsStatus(allocator, source_root);
    defer allocator.free(compile_commands);
    try writer.print("ghost_code_intel cpp_symbol_graph source_path {s} compile_commands {s}", .{ rel_path, compile_commands });

    var symbol_count: usize = 0;
    var inheritance_count: usize = 0;
    var virtual_count: usize = 0;
    var template_count: usize = 0;
    var call_edge_count: usize = 0;
    var template_pending = false;
    var current_class: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "template")) {
            template_pending = true;
            template_count += 1;
            try writer.writeAll(" template_declaration");
            continue;
        }
        if (classDecl(line)) |decl| {
            current_class = decl.name;
            symbol_count += 1;
            try writer.print(" class {s}", .{decl.name});
            if (decl.base.len != 0) {
                inheritance_count += 1;
                try writer.print(" inherits {s}", .{decl.base});
            }
            if (template_pending) try writer.print(" template_class {s}", .{decl.name});
            template_pending = false;
            continue;
        }
        if (virtualFunctionName(line)) |name| {
            virtual_count += 1;
            symbol_count += 1;
            if (current_class) |class_name| {
                try writer.print(" virtual_function {s}::{s}", .{ class_name, name });
            } else {
                try writer.print(" virtual_function {s}", .{name});
            }
            if (template_pending) try writer.print(" template_function {s}", .{name});
            template_pending = false;
            continue;
        }
        if (qualifiedFunctionName(line)) |fn_name| {
            symbol_count += 1;
            try writer.print(" function {s}", .{fn_name});
            template_pending = false;
        }
        if (callCandidate(line)) |call| {
            call_edge_count += 1;
            try writer.print(" call_edge {s}", .{call});
        }
    }

    try writer.print(
        " symbol_count {d} inheritance_count {d} virtual_count {d} template_count {d} call_edge_count {d}",
        .{ symbol_count, inheritance_count, virtual_count, template_count, call_edge_count },
    );

    return .{
        .text = try out.toOwnedSlice(),
        .symbol_count = symbol_count,
        .inheritance_count = inheritance_count,
        .virtual_count = virtual_count,
        .template_count = template_count,
        .call_edge_count = call_edge_count,
    };
}

const ClassDecl = struct {
    name: []const u8,
    base: []const u8 = "",
};

fn classDecl(line: []const u8) ?ClassDecl {
    const rest = if (std.mem.startsWith(u8, line, "class "))
        line["class ".len..]
    else if (std.mem.startsWith(u8, line, "struct "))
        line["struct ".len..]
    else
        return null;
    const name = leadingIdentifier(std.mem.trimLeft(u8, rest, " \t")) orelse return null;
    const colon_idx = std.mem.indexOfScalar(u8, rest, ':') orelse return .{ .name = name };
    var after_colon = std.mem.trimLeft(u8, rest[colon_idx + 1 ..], " \t");
    if (std.mem.startsWith(u8, after_colon, "public ")) after_colon = std.mem.trimLeft(u8, after_colon["public ".len..], " \t");
    if (std.mem.startsWith(u8, after_colon, "protected ")) after_colon = std.mem.trimLeft(u8, after_colon["protected ".len..], " \t");
    if (std.mem.startsWith(u8, after_colon, "private ")) after_colon = std.mem.trimLeft(u8, after_colon["private ".len..], " \t");
    const base = leadingQualifiedIdentifier(after_colon) orelse "";
    return .{ .name = name, .base = base };
}

fn virtualFunctionName(line: []const u8) ?[]const u8 {
    const virtual_idx = std.mem.indexOf(u8, line, "virtual ") orelse return null;
    const open_idx = std.mem.indexOfScalarPos(u8, line, virtual_idx, '(') orelse return null;
    return identifierBefore(line[0..open_idx]);
}

fn qualifiedFunctionName(line: []const u8) ?[]const u8 {
    const scope_idx = std.mem.indexOf(u8, line, "::") orelse return null;
    const open_idx = std.mem.indexOfScalarPos(u8, line, scope_idx, '(') orelse return null;
    return leadingQualifiedIdentifierBackwards(line[0..open_idx]);
}

fn callCandidate(line: []const u8) ?[]const u8 {
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (open_idx == 0) return null;
    const name = identifierBefore(line[0..open_idx]) orelse return null;
    if (isControlWord(name)) return null;
    return name;
}

fn leadingIdentifier(text: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < text.len and isIdentByte(text[end])) : (end += 1) {}
    if (end == 0) return null;
    return text[0..end];
}

fn leadingQualifiedIdentifier(text: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < text.len and (isIdentByte(text[end]) or text[end] == ':')) : (end += 1) {}
    if (end == 0) return null;
    return text[0..end];
}

fn leadingQualifiedIdentifierBackwards(text: []const u8) ?[]const u8 {
    var start = text.len;
    while (start > 0 and (isIdentByte(text[start - 1]) or text[start - 1] == ':')) : (start -= 1) {}
    if (start == text.len) return null;
    return text[start..];
}

fn identifierBefore(text: []const u8) ?[]const u8 {
    var end = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    var start = end;
    while (start > 0 and isIdentByte(text[start - 1])) : (start -= 1) {}
    if (start == end) return null;
    return text[start..end];
}

fn isIdentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isControlWord(name: []const u8) bool {
    return std.mem.eql(u8, name, "if") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "while") or
        std.mem.eql(u8, name, "switch") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "sizeof");
}

fn compileCommandsStatus(allocator: std.mem.Allocator, source_root: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ source_root, "compile_commands.json" });
    defer allocator.free(path);
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        file.close();
        return allocator.dupe(u8, "present");
    } else |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "missing"),
        else => return err,
    }
}

test "C++ AST summary captures templates virtuals and inheritance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "compile_commands.json", .data = "[]" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source =
        \\template <typename T>
        \\class ZenithUltraSynth : public TrackManager {
        \\public:
        \\  virtual void renderBlock(float** out);
        \\};
        \\void ZenithUltraSynth::renderBlock(float** out) { processTrack(out); }
    ;
    var summary = (try extract(allocator, root, "ZenithUltraSynth.hpp", source)).?;
    defer summary.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "class ZenithUltraSynth") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "inherits TrackManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "virtual_function ZenithUltraSynth::renderBlock") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.text, "template_class ZenithUltraSynth") != null);
}
