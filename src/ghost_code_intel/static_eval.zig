const std = @import("std");
const axioms = @import("axioms.zig");

pub const ViolationKind = enum {
    dangling_reference,
    missing_std_member,
    comptime_type_mismatch,
};

pub const Violation = struct {
    kind: ViolationKind,
    language: axioms.AxiomLanguage,
    line: u32,
    column: u32,
    symbol: []const u8,
    axiom_rule: []const u8,
    reason: []const u8,
    authority_level: u8 = axioms.AXIOM_AUTHORITY_LEVEL,
    authority_tier: []const u8 = axioms.AXIOM_TIER_LABEL,
    contradiction: bool = true,
};

pub const Evaluation = struct {
    allocator: std.mem.Allocator,
    language: axioms.AxiomLanguage,
    passed: bool,
    axiom_vectors_considered: usize,
    violations: []Violation,

    pub fn deinit(self: *Evaluation) void {
        self.allocator.free(self.violations);
        self.* = undefined;
    }
};

const KnownType = enum {
    unknown,
    unsigned8,
    signed32,
    boolean,
    bytes,
};

const TypeAlias = struct {
    name: []const u8,
    actual: KnownType,
};

pub fn evaluateSessionHot(
    allocator: std.mem.Allocator,
    source: []const u8,
    language: axioms.AxiomLanguage,
    matrix: axioms.Matrix,
) !Evaluation {
    return evaluateSnippet(allocator, source, language, matrix);
}

pub fn evaluateSnippet(
    allocator: std.mem.Allocator,
    source: []const u8,
    language: axioms.AxiomLanguage,
    matrix: axioms.Matrix,
) !Evaluation {
    var violations = std.ArrayList(Violation).init(allocator);
    errdefer violations.deinit();

    switch (language) {
        .cpp => try evaluateCpp(source, matrix, &violations),
        .zig => try evaluateZig(source, matrix, &violations),
        .unknown => {
            try evaluateCpp(source, matrix, &violations);
            try evaluateZig(source, matrix, &violations);
        },
    }

    const passed = violations.items.len == 0;
    return .{
        .allocator = allocator,
        .language = language,
        .passed = passed,
        .axiom_vectors_considered = matrix.countForLanguage(language),
        .violations = try violations.toOwnedSlice(),
    };
}

fn evaluateCpp(source: []const u8, matrix: axioms.Matrix, violations: *std.ArrayList(Violation)) !void {
    var locals = std.ArrayList([]const u8).init(violations.allocator);
    defer locals.deinit();

    var in_reference_return_function = false;
    var brace_depth: i32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = trimLine(raw_line);
        const trimmed = std.mem.trim(u8, line, " \r\n\t");

        if (std.mem.indexOf(u8, trimmed, ".push_front(") != null) {
            const vector_axiom = matrix.find(.cpp, "std::vector::push_front", "missing_member");
            try violations.append(.{
                .kind = .missing_std_member,
                .language = .cpp,
                .line = line_no,
                .column = columnOf(line, ".push_front("),
                .symbol = "std::vector::push_front",
                .axiom_rule = "missing_member",
                .reason = if (vector_axiom) |axiom| axiom.reason else "std::vector does not declare push_front.",
            });
        }

        if (!in_reference_return_function and looksLikeCppReferenceReturn(trimmed)) {
            in_reference_return_function = true;
            locals.clearRetainingCapacity();
            brace_depth = countBraceDelta(trimmed);
        } else if (in_reference_return_function) {
            brace_depth += countBraceDelta(trimmed);
        }

        if (in_reference_return_function) {
            if (extractCppLocalName(trimmed)) |name| try locals.append(name);
            if (returnReferencesLocal(trimmed, locals.items)) {
                const lifetime_axiom = matrix.find(.cpp, "cpp.reference.local_escape", "lifetime_escape");
                try violations.append(.{
                    .kind = .dangling_reference,
                    .language = .cpp,
                    .line = line_no,
                    .column = columnOf(line, "return"),
                    .symbol = "cpp.reference.local_escape",
                    .axiom_rule = "lifetime_escape",
                    .reason = if (lifetime_axiom) |axiom| axiom.reason else "a returned C++ reference cannot bind to a dead local object.",
                });
            }
            if (brace_depth <= 0 and std.mem.indexOfScalar(u8, trimmed, '}') != null) {
                in_reference_return_function = false;
                locals.clearRetainingCapacity();
            }
        }
    }
}

fn evaluateZig(source: []const u8, matrix: axioms.Matrix, violations: *std.ArrayList(Violation)) !void {
    var aliases = std.ArrayList(TypeAlias).init(violations.allocator);
    defer aliases.deinit();

    var in_comptime = false;
    var brace_depth: i32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = trimLine(raw_line);
        const trimmed = std.mem.trim(u8, line, " \r\n\t");

        if (!in_comptime and std.mem.indexOf(u8, trimmed, "comptime") != null and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            in_comptime = true;
            aliases.clearRetainingCapacity();
            brace_depth = countBraceDelta(trimmed);
        } else if (in_comptime) {
            brace_depth += countBraceDelta(trimmed);
        }

        if (in_comptime) {
            if (parseTypeAlias(trimmed)) |alias| {
                try aliases.append(alias);
            } else if (typedDeclarationMismatch(trimmed, aliases.items)) {
                const type_axiom = matrix.find(.zig, "zig.comptime.static_type", "comptime_type_mismatch");
                try violations.append(.{
                    .kind = .comptime_type_mismatch,
                    .language = .zig,
                    .line = line_no,
                    .column = columnOf(line, ":"),
                    .symbol = "zig.comptime.static_type",
                    .axiom_rule = "comptime_type_mismatch",
                    .reason = if (type_axiom) |axiom| axiom.reason else "Zig comptime assignment contradicts the resolved static type.",
                });
            }
            if (brace_depth <= 0 and std.mem.indexOfScalar(u8, trimmed, '}') != null) {
                in_comptime = false;
                aliases.clearRetainingCapacity();
            }
        }
    }
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn columnOf(line: []const u8, needle: []const u8) u32 {
    if (std.mem.indexOf(u8, line, needle)) |idx| return @intCast(idx + 1);
    return 1;
}

fn countBraceDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    for (line) |byte| {
        if (byte == '{') delta += 1;
        if (byte == '}') delta -= 1;
    }
    return delta;
}

fn looksLikeCppReferenceReturn(trimmed: []const u8) bool {
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    if (std.mem.startsWith(u8, trimmed, "return ")) return false;
    const paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return false;
    _ = std.mem.indexOfScalar(u8, trimmed[paren..], ')') orelse return false;
    const prefix = trimmed[0..paren];
    return std.mem.indexOfScalar(u8, prefix, '&') != null and std.mem.indexOfScalar(u8, prefix, '=') == null;
}

fn extractCppLocalName(trimmed: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, trimmed, "return ")) return null;
    const prefixes = [_][]const u8{
        "int ",
        "const int ",
        "long ",
        "const long ",
        "double ",
        "float ",
        "bool ",
        "auto ",
        "std::string ",
    };
    var matched = false;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            matched = true;
            break;
        }
    }
    if (!matched) return null;
    const stop = firstIndexOrLen(trimmed, '=');
    const decl = std.mem.trim(u8, trimmed[0..@min(stop, firstIndexOrLen(trimmed, ';'))], " \r\n\t");
    if (std.mem.indexOfScalar(u8, decl, '(') != null) return null;
    return trailingIdentifier(decl);
}

fn returnReferencesLocal(trimmed: []const u8, locals: []const []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "return ")) return false;
    var expr = std.mem.trim(u8, trimmed["return ".len..], " \r\n\t");
    if (std.mem.endsWith(u8, expr, ";")) expr = std.mem.trim(u8, expr[0 .. expr.len - 1], " \r\n\t");
    for (locals) |name| {
        if (std.mem.eql(u8, expr, name)) return true;
    }
    return false;
}

fn firstIndexOrLen(text: []const u8, byte: u8) usize {
    return std.mem.indexOfScalar(u8, text, byte) orelse text.len;
}

fn trailingIdentifier(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    var end = text.len;
    while (end > 0 and !isIdentifierChar(text[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and isIdentifierChar(text[start - 1])) start -= 1;
    if (start == end) return null;
    return text[start..end];
}

fn parseTypeAlias(trimmed: []const u8) ?TypeAlias {
    if (!std.mem.startsWith(u8, trimmed, "const ")) return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':');
    if (colon != null and colon.? < eq) return null;
    const name = std.mem.trim(u8, trimmed["const ".len..eq], " \r\n\t");
    if (!isIdentifier(name)) return null;
    var rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \r\n\t");
    if (std.mem.endsWith(u8, rhs, ";")) rhs = std.mem.trim(u8, rhs[0 .. rhs.len - 1], " \r\n\t");
    const actual = knownTypeFromExpression(rhs);
    if (actual == .unknown) return null;
    return .{ .name = name, .actual = actual };
}

fn typedDeclarationMismatch(trimmed: []const u8, aliases: []const TypeAlias) bool {
    if (!std.mem.startsWith(u8, trimmed, "const ") and !std.mem.startsWith(u8, trimmed, "var ")) return false;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return false;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    if (eq < colon) return false;
    const type_text = std.mem.trim(u8, trimmed[colon + 1 .. eq], " \r\n\t");
    var rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \r\n\t");
    if (std.mem.endsWith(u8, rhs, ";")) rhs = std.mem.trim(u8, rhs[0 .. rhs.len - 1], " \r\n\t");
    const resolved = resolveKnownType(type_text, aliases);
    return valueContradictsType(rhs, resolved);
}

fn resolveKnownType(type_text: []const u8, aliases: []const TypeAlias) KnownType {
    const direct = knownTypeFromExpression(type_text);
    if (direct != .unknown) return direct;
    for (aliases) |alias| {
        if (std.mem.eql(u8, type_text, alias.name)) return alias.actual;
    }
    return .unknown;
}

fn knownTypeFromExpression(text: []const u8) KnownType {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (std.mem.eql(u8, trimmed, "u8") or std.mem.startsWith(u8, trimmed, "u8 ")) return .unsigned8;
    if (std.mem.eql(u8, trimmed, "i32") or std.mem.startsWith(u8, trimmed, "i32 ")) return .signed32;
    if (std.mem.eql(u8, trimmed, "bool")) return .boolean;
    if (std.mem.eql(u8, trimmed, "[]const u8") or std.mem.eql(u8, trimmed, "[]u8")) return .bytes;

    if (std.mem.indexOf(u8, trimmed, "if (true)") != null or std.mem.indexOf(u8, trimmed, "if (comptime true)") != null) {
        const else_idx = std.mem.indexOf(u8, trimmed, "else") orelse trimmed.len;
        const close_paren = std.mem.indexOfScalar(u8, trimmed, ')') orelse return .unknown;
        return knownTypeFromExpression(trimmed[close_paren + 1 .. else_idx]);
    }
    if (std.mem.indexOf(u8, trimmed, "if (false)") != null or std.mem.indexOf(u8, trimmed, "if (comptime false)") != null) {
        if (std.mem.indexOf(u8, trimmed, "else")) |else_idx| return knownTypeFromExpression(trimmed[else_idx + "else".len ..]);
    }
    return .unknown;
}

fn valueContradictsType(rhs: []const u8, actual: KnownType) bool {
    if (actual == .unknown) return false;
    const is_string = std.mem.startsWith(u8, rhs, "\"") or std.mem.startsWith(u8, rhs, "u8\"");
    const is_number = rhs.len != 0 and std.ascii.isDigit(rhs[0]);
    return switch (actual) {
        .unknown => false,
        .unsigned8, .signed32 => is_string,
        .boolean => is_string or is_number,
        .bytes => is_number,
    };
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text, 0..) |byte, idx| {
        if (idx == 0) {
            if (!(std.ascii.isAlphabetic(byte) or byte == '_')) return false;
        } else if (!isIdentifierChar(byte)) return false;
    }
    return true;
}

fn isIdentifierChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "static evaluator flags std::vector push_front as axiom contradiction" {
    var matrix = try axioms.defaultMatrix(std.testing.allocator, .cpp);
    defer matrix.deinit();

    var result = try evaluateSnippet(std.testing.allocator,
        \\#include <vector>
        \\void f() {
        \\    std::vector<int> values;
        \\    values.push_front(1);
        \\}
    , .cpp, matrix);
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqual(ViolationKind.missing_std_member, result.violations[0].kind);
    try std.testing.expectEqual(@as(u32, 4), result.violations[0].line);
}
