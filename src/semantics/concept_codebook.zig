const std = @import("std");

pub const ASTNode = struct {
    label: []const u8 = "",
};

pub const GeneratorFn = *const fn (node: *ASTNode) []const u8;

pub const ResolveError = error{
    UnknownConstraint,
};

fn generateLockOrder(node: *ASTNode) []const u8 {
    _ = node;
    return "(assert ; LOCK_ORDER stub)";
}

fn generateNoAlloc(node: *ASTNode) []const u8 {
    _ = node;
    return "(assert ; NO_ALLOC stub)";
}

fn generateBoundsCheck(node: *ASTNode) []const u8 {
    _ = node;
    return "(assert ; BOUNDS_CHECK stub)";
}

const core_constraints = std.StaticStringMap(GeneratorFn).initComptime(.{
    .{ "LOCK_ORDER", generateLockOrder },
    .{ "NO_ALLOC", generateNoAlloc },
    .{ "BOUNDS_CHECK", generateBoundsCheck },
});

pub const ExtensibleRegistry = struct {
    allocator: std.mem.Allocator,
    generators: std.StringHashMap(GeneratorFn),

    pub fn init(allocator: std.mem.Allocator) ExtensibleRegistry {
        return .{
            .allocator = allocator,
            .generators = std.StringHashMap(GeneratorFn).init(allocator),
        };
    }

    pub fn deinit(self: *ExtensibleRegistry) void {
        var key_iter = self.generators.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.generators.deinit();
        self.* = undefined;
    }

    pub fn register(
        self: *ExtensibleRegistry,
        constraint: []const u8,
        generator: GeneratorFn,
    ) !void {
        if (self.generators.fetchRemove(constraint)) |entry| {
            self.allocator.free(entry.key);
        }

        const owned_constraint = try self.allocator.dupe(u8, constraint);
        errdefer self.allocator.free(owned_constraint);
        try self.generators.put(owned_constraint, generator);
    }
};

pub fn resolve(constraint: []const u8, registry: *const ExtensibleRegistry) ResolveError!GeneratorFn {
    if (core_constraints.get(constraint)) |generator| return generator;
    if (registry.generators.get(constraint)) |generator| return generator;
    return error.UnknownConstraint;
}

fn generateManifestConstraint(node: *ASTNode) []const u8 {
    _ = node;
    return "(assert ; MANIFEST_CONSTRAINT stub)";
}

test "core constraint resolves through comptime tier" {
    var registry = ExtensibleRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var node = ASTNode{ .label = "lock-acquire" };
    const generator = try resolve("LOCK_ORDER", &registry);

    try std.testing.expectEqualStrings("(assert ; LOCK_ORDER stub)", generator(&node));
}

test "registered constraint resolves through extension tier" {
    var registry = ExtensibleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register("MANIFEST_CONSTRAINT", generateManifestConstraint);

    var node = ASTNode{ .label = "manifest-node" };
    const generator = try resolve("MANIFEST_CONSTRAINT", &registry);

    try std.testing.expectEqualStrings("(assert ; MANIFEST_CONSTRAINT stub)", generator(&node));
}

test "unknown constraint returns UnknownConstraint" {
    var registry = ExtensibleRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectError(error.UnknownConstraint, resolve("VECTOR_SIMILARITY", &registry));
}
