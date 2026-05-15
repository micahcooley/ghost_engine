const std = @import("std");
const build_options = @import("build_options");
const vsa = @import("vsa_core.zig");
const semantic_encoder = @import("semantic_encoder.zig");
const lattice_mmap = @import("vsa/lattice_mmap.zig");
const mmap_hv = @import("vsa/hypervector.zig");

pub const LOCAL_STATE_SEED: u64 = 0x4652_4f4e_5441_4c31; // "FRONTAL1"
pub const LATTICE_CAPACITY: u32 = 4096;

pub const IntentRoute = enum {
    scalar,
    z3,
    vsa,
};

pub fn init(allocator: std.mem.Allocator) !void {
    _ = allocator;
}

pub fn deinit() void {}

pub const EncoderSource = enum {
    frontal_lobe,
    local_state_space,
};

pub const OffloadStatus = enum {
    skipped,
    written,
    lattice_full,
    unavailable,
};

pub const OffloadResult = struct {
    status: OffloadStatus,
    slot: ?u32 = null,
};

pub const Projection = struct {
    source: EncoderSource,
    route: IntentRoute,
    intent_vector: vsa.HyperVector,
    hidden_state: vsa.HyperVector,
    route_vector: vsa.HyperVector,
    scalar_score: u32,
    z3_score: u32,
    vsa_score: u32,
    confidence_per_mille: u16,
    state_hash: u64,
    offload: OffloadResult = .{ .status = .skipped },
};

const IntentExample = struct {
    route: IntentRoute,
    text: []const u8,
    weight: u16,
};

const bootstrap_examples = [_]IntentExample{
    .{ .route = .scalar, .text = "ready status hello ping help start engine available", .weight = 2 },
    .{ .route = .scalar, .text = "are you online system ready daemon status", .weight = 2 },
    .{ .route = .z3, .text = "prove solve arithmetic integer constraint equation logic theorem", .weight = 2 },
    .{ .route = .z3, .text = "calculate compare equals greater less than formal proof", .weight = 2 },
    .{ .route = .vsa, .text = "search recall retrieve memory lattice corpus semantic similarity", .weight = 2 },
    .{ .route = .vsa, .text = "vulkan gpu vsa vector resonance context knowledge", .weight = 2 },
};

pub fn projectLocalIntent(allocator: std.mem.Allocator, text: []const u8) !Projection {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const hidden_state = try evolveHiddenState(trimmed);
    const concept_state = semantic_encoder.encodeDomainConcept(trimmed, "human_intent");
    const intent_vector = vsa.bundle(hidden_state, concept_state, semantic_encoder.encodeConceptString(trimmed));

    var scores = IntentScores{};
    scoreExamples(&scores, trimmed, intent_vector, &bootstrap_examples);
    try scoreReviewedExamples(allocator, &scores, trimmed, intent_vector);
    scores.applyStructuralSignals(trimmed);

    const route = scores.selectRoute();
    return projectionFromRoute(.local_state_space, route, intent_vector, hidden_state, scores);
}

pub fn projectExternalIntent(text: []const u8, intent_vector: vsa.HyperVector) Projection {
    const hidden_state = evolveHiddenState(text) catch vsa.generate(LOCAL_STATE_SEED);
    var scores = IntentScores{};
    scores.scalar = 1024 -| vsa.hammingDistance(intent_vector, vsa.ROUTE_VEC_SCALAR);
    scores.z3 = 1024 -| vsa.hammingDistance(intent_vector, vsa.ROUTE_VEC_Z3);
    scores.vsa = 1024 -| vsa.hammingDistance(intent_vector, vsa.ROUTE_VEC_VSA);
    const route = scores.selectRoute();
    return projectionFromRoute(.frontal_lobe, route, intent_vector, hidden_state, scores);
}

pub fn offloadDefault(allocator: std.mem.Allocator, projection: *Projection) void {
    projection.offload = offloadToPath(allocator, defaultLatticePath(allocator) catch {
        projection.offload = .{ .status = .unavailable };
        return;
    }, projection.hidden_state) catch |err| switch (err) {
        error.LatticeFull => .{ .status = .lattice_full },
        else => .{ .status = .unavailable },
    };
}

pub fn offloadToPath(allocator: std.mem.Allocator, path: []const u8, vector: vsa.HyperVector) !OffloadResult {
    defer allocator.free(path);
    var lattice = try lattice_mmap.MmapLattice.initOrOpen(path, LATTICE_CAPACITY);
    defer lattice.deinit();
    const slot = try lattice.append(toMmapVector(vector));
    return .{ .status = .written, .slot = slot };
}

fn defaultLatticePath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GHOST_FRONTAL_LOBE_LATTICE")) |path| {
        return path;
    } else |_| {}

    const state_dir = try std.fs.path.join(allocator, &.{ build_options.project_root, ".ghost" });
    defer allocator.free(state_dir);
    try std.fs.cwd().makePath(state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "frontal_lobe_vsa.bin" });
}

fn reviewedExamplesPath(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GHOST_FRONTAL_LOBE_EXAMPLES")) |path| {
        return path;
    } else |_| {}

    const path = try std.fs.path.join(allocator, &.{ build_options.project_root, ".ghost", "frontal_lobe_routes.jsonl" });
    if (std.fs.accessAbsolute(path, .{})) |_| return path else |_| {
        allocator.free(path);
        return null;
    }
}

pub fn initAndRunInference(text: []const u8) !vsa.HyperVector {
    return try evolveHiddenState(text);
}

fn evolveHiddenState(text: []const u8) !vsa.HyperVector {
    return semantic_encoder.encodeConceptStringSeeded(text, LOCAL_STATE_SEED);
}

const IntentScores = struct {
    scalar: u32 = 0,
    z3: u32 = 0,
    vsa: u32 = 0,

    fn add(self: *IntentScores, route: IntentRoute, amount: u32) void {
        switch (route) {
            .scalar => self.scalar += amount,
            .z3 => self.z3 += amount,
            .vsa => self.vsa += amount,
        }
    }

    fn applyStructuralSignals(self: *IntentScores, text: []const u8) void {
        if (looksArithmeticOrLogic(text)) self.z3 += 1400;
        if (containsAnyAsciiIgnoreCase(text, &.{ "ready", "hello", "hi", "status", "ping", "help", "start" })) self.scalar += 900;
        if (containsAnyAsciiIgnoreCase(text, &.{ "search", "recall", "retrieve", "memory", "vsa", "lattice", "corpus", "semantic", "similar", "vulkan", "gpu" })) self.vsa += 900;
    }

    fn selectRoute(self: IntentScores) IntentRoute {
        if (self.z3 > self.scalar and self.z3 > self.vsa) return .z3;
        if (self.scalar > self.vsa) return .scalar;
        return .vsa;
    }
};

fn scoreExamples(scores: *IntentScores, text: []const u8, query: vsa.HyperVector, examples: []const IntentExample) void {
    for (examples) |example| {
        const example_vec = semantic_encoder.encodeDomainConcept(example.text, "human_intent");
        const resonance = vsa.resonanceScore(query, example_vec);
        var amount: u32 = @as(u32, resonance) * example.weight;
        if (hasAnyPrototypeTerm(text, example.text)) amount += 250;
        scores.add(example.route, amount);
    }
}

fn scoreReviewedExamples(allocator: std.mem.Allocator, scores: *IntentScores, text: []const u8, query: vsa.HyperVector) !void {
    const maybe_path = try reviewedExamplesPath(allocator);
    const path = maybe_path orelse return;
    defer allocator.free(path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024) catch return;
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const route_text = jsonString(obj, "route") orelse continue;
        const example_text = jsonString(obj, "text") orelse continue;
        const route = parseRoute(route_text) orelse continue;
        const weight = jsonInt(obj, "weight") orelse 3;
        const example = IntentExample{ .route = route, .text = example_text, .weight = @intCast(@min(@as(i64, 12), @max(@as(i64, 1), weight))) };
        scoreExamples(scores, text, query, &.{example});
    }
}

fn projectionFromRoute(source: EncoderSource, route: IntentRoute, intent_vector: vsa.HyperVector, hidden_state: vsa.HyperVector, scores: IntentScores) Projection {
    const route_vector = switch (route) {
        .scalar => vsa.ROUTE_VEC_SCALAR,
        .z3 => vsa.ROUTE_VEC_Z3,
        .vsa => vsa.ROUTE_VEC_VSA,
    };
    const confidence = confidencePerMille(route, scores);
    return .{
        .source = source,
        .route = route,
        .intent_vector = intent_vector,
        .hidden_state = hidden_state,
        .route_vector = route_vector,
        .scalar_score = scores.scalar,
        .z3_score = scores.z3,
        .vsa_score = scores.vsa,
        .confidence_per_mille = confidence,
        .state_hash = vsa.collapse(hidden_state),
    };
}

fn confidencePerMille(route: IntentRoute, scores: IntentScores) u16 {
    const selected = switch (route) {
        .scalar => scores.scalar,
        .z3 => scores.z3,
        .vsa => scores.vsa,
    };
    const total = scores.scalar + scores.z3 + scores.vsa;
    if (total == 0) return 0;
    return @intCast(@min(@as(u32, 1000), (selected * 1000) / total));
}

fn toMmapVector(vector: vsa.HyperVector) mmap_hv.HyperVector {
    return .{ .lanes = @as([16]u64, vector) };
}

fn parseRoute(text: []const u8) ?IntentRoute {
    if (std.ascii.eqlIgnoreCase(text, "scalar")) return .scalar;
    if (std.ascii.eqlIgnoreCase(text, "z3") or std.ascii.eqlIgnoreCase(text, "logic")) return .z3;
    if (std.ascii.eqlIgnoreCase(text, "vsa") or std.ascii.eqlIgnoreCase(text, "memory")) return .vsa;
    return null;
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn hasAnyPrototypeTerm(text: []const u8, prototype_text: []const u8) bool {
    var it = std.mem.splitScalar(u8, prototype_text, ' ');
    while (it.next()) |term| {
        if (term.len == 0) continue;
        if (indexOfAsciiIgnoreCase(text, term) != null) return true;
    }
    return false;
}

fn looksArithmeticOrLogic(text: []const u8) bool {
    if (containsAnyAsciiIgnoreCase(text, &.{
        "z3",
        "prove",
        "solver",
        "solve",
        "logic",
        "theorem",
        "constraint",
        "integer",
        "arithmetic",
        "equals",
    })) return true;

    var saw_digit = false;
    var saw_operator = false;
    for (text) |c| {
        if (std.ascii.isDigit(c)) saw_digit = true;
        switch (c) {
            '+', '-', '*', '/', '=', '<', '>' => saw_operator = true,
            else => {},
        }
    }
    return saw_digit and saw_operator;
}

fn containsAnyAsciiIgnoreCase(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfAsciiIgnoreCase(text, needle) != null) return true;
    }
    return false;
}

fn indexOfAsciiIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

test "local frontal lobe projects fuzzy intent into VSA route space" {
    const allocator = std.testing.allocator;
    const scalar = try projectLocalIntent(allocator, "ready");
    const logic = try projectLocalIntent(allocator, "2+3");
    const memory = try projectLocalIntent(allocator, "find related memory in the semantic lattice");

    try std.testing.expectEqual(IntentRoute.scalar, scalar.route);
    try std.testing.expectEqual(IntentRoute.z3, logic.route);
    try std.testing.expectEqual(IntentRoute.vsa, memory.route);
    try std.testing.expectEqual(@as(u16, 0), vsa.hammingDistance(logic.route_vector, vsa.ROUTE_VEC_Z3));
    try std.testing.expect(logic.confidence_per_mille > 0);
}

test "frontal lobe offloads hidden state into locked mmap lattice" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "frontal.bin" });
    var projection = try projectLocalIntent(allocator, "remember this semantic state");
    const result = try offloadToPath(allocator, path, projection.hidden_state);
    projection.offload = result;

    try std.testing.expectEqual(OffloadStatus.written, projection.offload.status);
    try std.testing.expectEqual(@as(?u32, 0), projection.offload.slot);
}
