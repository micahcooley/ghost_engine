const std = @import("std");

pub const AXIOM_AUTHORITY_LEVEL: u8 = 0;
pub const AXIOM_TIER_LABEL = "axiom_tier_0";

pub const AxiomLanguage = enum {
    cpp,
    zig,
    unknown,
};

pub const AxiomKind = enum {
    standard_library,
    compiler_semantics,
};

pub const AxiomVector = struct {
    language: AxiomLanguage,
    kind: AxiomKind,
    symbol: []const u8,
    rule: []const u8,
    reason: []const u8,
    source_path: []const u8 = "builtin:technical_axiom_matrix",
    source_line: u32 = 0,
    authority_level: u8 = AXIOM_AUTHORITY_LEVEL,
    authority_tier: []const u8 = AXIOM_TIER_LABEL,
    locked: bool = true,
    hash: u64,
};

pub const Matrix = struct {
    allocator: std.mem.Allocator,
    vectors: []AxiomVector,

    pub fn deinit(self: *Matrix) void {
        self.allocator.free(self.vectors);
        self.* = undefined;
    }

    pub fn countForLanguage(self: Matrix, language: AxiomLanguage) usize {
        var count: usize = 0;
        for (self.vectors) |vector| {
            if (language == .unknown or vector.language == language) count += 1;
        }
        return count;
    }

    pub fn footprintBytes(self: Matrix) usize {
        var total: usize = self.vectors.len * @sizeOf(AxiomVector);
        for (self.vectors) |vector| {
            total += vector.symbol.len + vector.rule.len + vector.reason.len + vector.source_path.len;
        }
        return total;
    }

    pub fn find(self: Matrix, language: AxiomLanguage, symbol: []const u8, rule: []const u8) ?AxiomVector {
        for (self.vectors) |vector| {
            if (language != .unknown and vector.language != language) continue;
            if (!std.mem.eql(u8, vector.symbol, symbol)) continue;
            if (!std.mem.eql(u8, vector.rule, rule)) continue;
            return vector;
        }
        return null;
    }
};

pub fn languageName(language: AxiomLanguage) []const u8 {
    return switch (language) {
        .cpp => "cpp",
        .zig => "zig",
        .unknown => "unknown",
    };
}

pub fn parseLanguageName(text: []const u8) ?AxiomLanguage {
    if (std.ascii.eqlIgnoreCase(text, "cpp") or
        std.ascii.eqlIgnoreCase(text, "c++"))
    {
        return .cpp;
    }
    if (std.ascii.eqlIgnoreCase(text, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(text, "unknown")) return .unknown;
    return null;
}

pub fn inferLanguageFromPath(path: []const u8) AxiomLanguage {
    if (std.mem.indexOf(u8, path, "zig/lib/std") != null or
        std.mem.indexOf(u8, path, "/lib/std") != null or
        std.mem.endsWith(u8, path, ".zig"))
    {
        return .zig;
    }
    if (std.mem.indexOf(u8, path, "/include/c++") != null or
        std.mem.indexOf(u8, path, "include/c++") != null or
        std.mem.indexOf(u8, path, "c++") != null or
        std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".hxx") or
        std.mem.endsWith(u8, path, ".hh"))
    {
        return .cpp;
    }
    return .unknown;
}

pub fn defaultMatrix(allocator: std.mem.Allocator, language: AxiomLanguage) !Matrix {
    var list = std.ArrayList(AxiomVector).init(allocator);
    errdefer list.deinit();

    if (language == .unknown or language == .cpp) {
        try appendVector(&list, .{
            .language = .cpp,
            .kind = .standard_library,
            .symbol = "std::vector::push_front",
            .rule = "missing_member",
            .reason = "std::vector does not declare push_front; this member call contradicts the C++ standard library axiom for std::vector.",
            .hash = 0,
        });
        try appendVector(&list, .{
            .language = .cpp,
            .kind = .compiler_semantics,
            .symbol = "cpp.reference.local_escape",
            .rule = "lifetime_escape",
            .reason = "a C++ reference returned from a function must not bind to an automatic local object whose lifetime ends at function exit.",
            .hash = 0,
        });
    }

    if (language == .unknown or language == .zig) {
        try appendVector(&list, .{
            .language = .zig,
            .kind = .compiler_semantics,
            .symbol = "zig.comptime.static_type",
            .rule = "comptime_type_mismatch",
            .reason = "Zig comptime execution is evaluated during compilation; the value assigned in a comptime block must satisfy the resolved static type.",
            .hash = 0,
        });
        try appendVector(&list, .{
            .language = .zig,
            .kind = .standard_library,
            .symbol = "zig.std",
            .rule = "standard_library_axiom",
            .reason = "Zig standard library declarations ingested with --axioms are Tier 0 authority for static evaluation.",
            .hash = 0,
        });
    }

    return .{
        .allocator = allocator,
        .vectors = try list.toOwnedSlice(),
    };
}

pub fn isAxiomCandidatePath(path: []const u8, language: AxiomLanguage) bool {
    const base = std.fs.path.basename(path);
    if (base.len == 0 or base[0] == '.') return false;
    if (std.mem.eql(u8, base, "LICENSE") or std.mem.eql(u8, base, "README")) return false;

    if (language == .zig) return std.mem.endsWith(u8, path, ".zig");
    if (language == .cpp) {
        return isCppSourceLike(path) or isExtensionlessStdHeader(base);
    }
    return std.mem.endsWith(u8, path, ".zig") or isCppSourceLike(path) or isExtensionlessStdHeader(base);
}

pub fn ruleForPath(language: AxiomLanguage, rel_path: []const u8) []const u8 {
    const base = std.fs.path.basename(rel_path);
    if (language == .cpp) {
        if (std.mem.eql(u8, base, "vector") or std.mem.endsWith(u8, rel_path, "/vector")) {
            return "std::vector member contract";
        }
        return "C++ standard library declaration";
    }
    if (language == .zig) return "Zig standard library declaration";
    return "standard library declaration";
}

fn appendVector(list: *std.ArrayList(AxiomVector), vector: AxiomVector) !void {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(languageName(vector.language));
    hasher.update(@tagName(vector.kind));
    hasher.update(vector.symbol);
    hasher.update(vector.rule);
    hasher.update(vector.reason);

    var owned = vector;
    owned.authority_level = AXIOM_AUTHORITY_LEVEL;
    owned.authority_tier = AXIOM_TIER_LABEL;
    owned.locked = true;
    owned.hash = hasher.final();
    try list.append(owned);
}

fn isCppSourceLike(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".h") or
        std.mem.endsWith(u8, path, ".hh") or
        std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".hxx") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".cxx") or
        std.mem.endsWith(u8, path, ".tcc") or
        std.mem.endsWith(u8, path, ".inc");
}

fn isExtensionlessStdHeader(base: []const u8) bool {
    if (std.mem.indexOfScalar(u8, base, '.') != null) return false;
    const names = [_][]const u8{
        "algorithm",
        "array",
        "atomic",
        "bit",
        "chrono",
        "concepts",
        "deque",
        "filesystem",
        "forward_list",
        "functional",
        "initializer_list",
        "iterator",
        "limits",
        "list",
        "map",
        "memory",
        "mutex",
        "optional",
        "queue",
        "ranges",
        "set",
        "span",
        "string",
        "string_view",
        "tuple",
        "type_traits",
        "unordered_map",
        "unordered_set",
        "utility",
        "variant",
        "vector",
    };
    for (names) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

test "default matrix exposes Tier 0 C++ and Zig axioms" {
    var matrix = try defaultMatrix(std.testing.allocator, .unknown);
    defer matrix.deinit();

    try std.testing.expect(matrix.countForLanguage(.cpp) >= 2);
    try std.testing.expect(matrix.countForLanguage(.zig) >= 2);
    try std.testing.expect(matrix.footprintBytes() > matrix.vectors.len * @sizeOf(AxiomVector));
    try std.testing.expect(matrix.find(.cpp, "std::vector::push_front", "missing_member") != null);
    try std.testing.expect(matrix.find(.zig, "zig.comptime.static_type", "comptime_type_mismatch") != null);
}
