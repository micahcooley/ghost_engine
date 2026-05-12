const std = @import("std");
const inference = @import("domain_inference");

pub const INTENT_LANES: usize = 4;
pub const DOMAIN_LANES: usize = 8;
pub const TARGET_LANES: usize = 16;
pub const MAX_TARGETS: usize = TARGET_LANES;
pub const TARGET_EMIT_FLOOR: f32 = 0.18;

pub const IntentVector = @Vector(INTENT_LANES, f32);
pub const DomainVector = @Vector(DOMAIN_LANES, f32);
pub const TargetVector = @Vector(TARGET_LANES, f32);

pub const Intent = enum(u8) {
    optimize,
    secure,
    refactor,
    stabilize,

    pub fn lane(self: Intent) usize {
        return @intFromEnum(self);
    }

    pub fn tag(self: Intent) []const u8 {
        return switch (self) {
            .optimize => "OPTIMIZE",
            .secure => "SECURE",
            .refactor => "REFACTOR",
            .stabilize => "STABILIZE",
        };
    }
};

pub const SemanticTarget = enum(u8) {
    branch_prediction_flattening,
    heap_allocation_ban,
    sample_buffer_locality,
    realtime_thread_budget,
    io_wait_reduction,
    index_traversal,
    transaction_batching,
    query_plan_stability,
    input_validation,
    secret_zeroization,
    bounds_checking,
    lock_contention_reduction,
    api_surface_simplification,
    state_isolation,
    shader_batching,
    socket_backpressure,

    pub fn lane(self: SemanticTarget) usize {
        return @intFromEnum(self);
    }

    pub fn tag(self: SemanticTarget) []const u8 {
        return switch (self) {
            .branch_prediction_flattening => "branch_prediction_flattening",
            .heap_allocation_ban => "heap_allocation_ban",
            .sample_buffer_locality => "sample_buffer_locality",
            .realtime_thread_budget => "realtime_thread_budget",
            .io_wait_reduction => "io_wait_reduction",
            .index_traversal => "index_traversal",
            .transaction_batching => "transaction_batching",
            .query_plan_stability => "query_plan_stability",
            .input_validation => "input_validation",
            .secret_zeroization => "secret_zeroization",
            .bounds_checking => "bounds_checking",
            .lock_contention_reduction => "lock_contention_reduction",
            .api_surface_simplification => "api_surface_simplification",
            .state_isolation => "state_isolation",
            .shader_batching => "shader_batching",
            .socket_backpressure => "socket_backpressure",
        };
    }
};

pub const ConfidenceBand = enum {
    green_verified,
    yellow_heuristic,

    pub fn tag(self: ConfidenceBand) []const u8 {
        return switch (self) {
            .green_verified => "GREEN/VERIFIED_PROOF_READY",
            .yellow_heuristic => "YELLOW/HEURISTIC_WARNING",
        };
    }
};

pub const ResolvedTarget = struct {
    target: SemanticTarget,
    score: f32,
};

pub const SemanticResult = struct {
    intent: IntentVector,
    domain: DomainVector,
    target_scores: TargetVector,
    confidence: f32,
    confidence_band: ConfidenceBand,
    targets: [MAX_TARGETS]ResolvedTarget = undefined,
    target_len: usize = 0,
    sparse_or_unknown_domain: bool = false,

    pub fn targetSlice(self: *const SemanticResult) []const ResolvedTarget {
        return self.targets[0..self.target_len];
    }

    pub fn hasTarget(self: *const SemanticResult, target: SemanticTarget) bool {
        for (self.targetSlice()) |resolved| {
            if (resolved.target == target) return true;
        }
        return false;
    }
};

pub fn intentVector(intent: Intent) IntentVector {
    var out: IntentVector = @splat(0.0);
    out[intent.lane()] = 1.0;
    return out;
}

pub fn blendedIntentVector(intents: []const Intent) IntentVector {
    var out: IntentVector = @splat(0.0);
    for (intents) |intent| {
        out[intent.lane()] = 1.0;
    }
    return out;
}

pub fn domainVector(domain: inference.PhysicalDomain) DomainVector {
    var out: DomainVector = @splat(0.0);
    out[domainLane(domain)] = 1.0;
    return out;
}

pub fn unknownDomainVector() DomainVector {
    var out: DomainVector = @splat(0.0);
    out[unknown_domain_lane] = 1.0;
    return out;
}

pub fn domainVectorFromSet(domains: inference.DomainSet) DomainVector {
    var out: DomainVector = @splat(0.0);
    if (domains.contains(.database)) out[domainLane(.database)] = 1.0;
    if (domains.contains(.dsp)) out[domainLane(.dsp)] = 1.0;
    if (domains.contains(.graphics)) out[domainLane(.graphics)] = 1.0;
    if (domains.contains(.network)) out[domainLane(.network)] = 1.0;
    if (domains.contains(.filesystem)) out[domainLane(.filesystem)] = 1.0;
    if (domains.contains(.crypto)) out[domainLane(.crypto)] = 1.0;
    if (domains.contains(.ui)) out[domainLane(.ui)] = 1.0;
    if (domains.isEmpty()) out[unknown_domain_lane] = 1.0;
    return out;
}

pub fn resolve(intent: IntentVector, domain: DomainVector) SemanticResult {
    var scores: TargetVector = @splat(0.0);

    inline for (0..INTENT_LANES) |intent_lane| {
        inline for (0..DOMAIN_LANES) |domain_lane_index| {
            const scalar = intent[intent_lane] * domain[domain_lane_index];
            scores += @as(TargetVector, @splat(scalar)) * tensor[intent_lane][domain_lane_index];
        }
    }

    scores = clampVector(scores, 0.0, 1.0);
    var result: SemanticResult = .{
        .intent = intent,
        .domain = domain,
        .target_scores = scores,
        .confidence = confidenceFor(intent, domain),
        .confidence_band = .yellow_heuristic,
        .sparse_or_unknown_domain = domainIsSparseOrUnknown(domain),
    };
    result.confidence_band = if (result.confidence >= 0.72) .green_verified else .yellow_heuristic;
    collectTargets(&result);
    return result;
}

pub fn resolveIntentDomain(intent: Intent, domain: inference.PhysicalDomain) SemanticResult {
    return resolve(intentVector(intent), domainVector(domain));
}

pub fn resolveIntentDomainSet(intent: Intent, domains: inference.DomainSet) SemanticResult {
    return resolve(intentVector(intent), domainVectorFromSet(domains));
}

fn collectTargets(result: *SemanticResult) void {
    var lane_index: usize = 0;
    while (lane_index < TARGET_LANES) : (lane_index += 1) {
        const score = result.target_scores[lane_index];
        if (score < TARGET_EMIT_FLOOR) continue;
        result.targets[result.target_len] = .{
            .target = @enumFromInt(lane_index),
            .score = score,
        };
        result.target_len += 1;
    }
    sortTargets(result.targets[0..result.target_len]);
}

fn sortTargets(targets: []ResolvedTarget) void {
    var i: usize = 1;
    while (i < targets.len) : (i += 1) {
        var j = i;
        while (j > 0 and targetLessThan(targets[j], targets[j - 1])) : (j -= 1) {
            const tmp = targets[j - 1];
            targets[j - 1] = targets[j];
            targets[j] = tmp;
        }
    }
}

fn targetLessThan(lhs: ResolvedTarget, rhs: ResolvedTarget) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    return @intFromEnum(lhs.target) < @intFromEnum(rhs.target);
}

fn confidenceFor(intent: IntentVector, domain: DomainVector) f32 {
    const intent_mass = vectorSum(intent);
    const known_domain_mass = knownDomainMass(domain);
    const unknown_mass = @max(domain[unknown_domain_lane], 0.0);
    const total_domain_mass = known_domain_mass + unknown_mass;

    if (intent_mass <= 0.0 or total_domain_mass <= 0.0) return 0.05;
    if (known_domain_mass <= 0.0) return 0.12;

    const density = known_domain_mass / @as(f32, @floatFromInt(known_domain_lane_count));
    const specificity = known_domain_mass / total_domain_mass;
    const intent_focus = @min(intent_mass, 1.0);
    const sparse_floor: f32 = if (density < 0.20) 0.84 else 0.94;
    const decayed = sparse_floor * specificity * intent_focus * (1.0 - @min(unknown_mass, 1.0) * 0.70);
    return clampScalar(decayed, 0.05, 0.98);
}

fn domainIsSparseOrUnknown(domain: DomainVector) bool {
    return knownDomainMass(domain) <= 0.0 or domain[unknown_domain_lane] > 0.0;
}

fn knownDomainMass(domain: DomainVector) f32 {
    var sum: f32 = 0.0;
    inline for (0..known_domain_lane_count) |lane_index| {
        sum += @max(domain[lane_index], 0.0);
    }
    return sum;
}

fn vectorSum(vector: anytype) f32 {
    var sum: f32 = 0.0;
    inline for (0..@typeInfo(@TypeOf(vector)).vector.len) |lane_index| {
        sum += @max(vector[lane_index], 0.0);
    }
    return sum;
}

fn clampVector(vector: TargetVector, min_value: f32, max_value: f32) TargetVector {
    return @min(@max(vector, @as(TargetVector, @splat(min_value))), @as(TargetVector, @splat(max_value)));
}

fn clampScalar(value: f32, min_value: f32, max_value: f32) f32 {
    return @min(@max(value, min_value), max_value);
}

fn domainLane(domain: inference.PhysicalDomain) usize {
    return switch (domain) {
        .database => 0,
        .dsp => 1,
        .graphics => 2,
        .network => 3,
        .filesystem => 4,
        .crypto => 5,
        .ui => 6,
    };
}

const known_domain_lane_count: usize = 7;
const unknown_domain_lane: usize = 7;

const zero_targets: TargetVector = @splat(0.0);

const tensor = [_][DOMAIN_LANES]TargetVector{
    // OPTIMIZE
    .{
        targetVector(.{ .io_wait_reduction = 0.95, .index_traversal = 0.92, .transaction_batching = 0.72, .query_plan_stability = 0.64 }),
        targetVector(.{ .branch_prediction_flattening = 0.96, .heap_allocation_ban = 0.91, .sample_buffer_locality = 0.82, .realtime_thread_budget = 0.74 }),
        targetVector(.{ .shader_batching = 0.94, .branch_prediction_flattening = 0.58, .lock_contention_reduction = 0.48 }),
        targetVector(.{ .socket_backpressure = 0.90, .lock_contention_reduction = 0.66, .io_wait_reduction = 0.52 }),
        targetVector(.{ .io_wait_reduction = 0.88, .lock_contention_reduction = 0.54 }),
        targetVector(.{ .branch_prediction_flattening = 0.55, .secret_zeroization = 0.38, .bounds_checking = 0.32 }),
        targetVector(.{ .api_surface_simplification = 0.55, .state_isolation = 0.42 }),
        zero_targets,
    },
    // SECURE
    .{
        targetVector(.{ .input_validation = 0.84, .query_plan_stability = 0.70, .transaction_batching = 0.34 }),
        targetVector(.{ .heap_allocation_ban = 0.74, .bounds_checking = 0.66, .realtime_thread_budget = 0.48 }),
        targetVector(.{ .bounds_checking = 0.70, .state_isolation = 0.52 }),
        targetVector(.{ .input_validation = 0.86, .socket_backpressure = 0.64, .state_isolation = 0.58 }),
        targetVector(.{ .bounds_checking = 0.80, .input_validation = 0.64 }),
        targetVector(.{ .secret_zeroization = 0.96, .bounds_checking = 0.84, .state_isolation = 0.72 }),
        targetVector(.{ .input_validation = 0.82, .state_isolation = 0.64 }),
        zero_targets,
    },
    // REFACTOR
    .{
        targetVector(.{ .api_surface_simplification = 0.74, .query_plan_stability = 0.68, .state_isolation = 0.52 }),
        targetVector(.{ .state_isolation = 0.72, .heap_allocation_ban = 0.58, .sample_buffer_locality = 0.42 }),
        targetVector(.{ .state_isolation = 0.68, .shader_batching = 0.42 }),
        targetVector(.{ .api_surface_simplification = 0.76, .socket_backpressure = 0.50, .state_isolation = 0.50 }),
        targetVector(.{ .api_surface_simplification = 0.62, .state_isolation = 0.54 }),
        targetVector(.{ .api_surface_simplification = 0.58, .secret_zeroization = 0.42 }),
        targetVector(.{ .api_surface_simplification = 0.82, .state_isolation = 0.58 }),
        zero_targets,
    },
    // STABILIZE
    .{
        targetVector(.{ .query_plan_stability = 0.90, .transaction_batching = 0.60, .index_traversal = 0.42 }),
        targetVector(.{ .realtime_thread_budget = 0.88, .heap_allocation_ban = 0.62, .bounds_checking = 0.42 }),
        targetVector(.{ .shader_batching = 0.64, .state_isolation = 0.50 }),
        targetVector(.{ .socket_backpressure = 0.76, .lock_contention_reduction = 0.58 }),
        targetVector(.{ .io_wait_reduction = 0.62, .bounds_checking = 0.52 }),
        targetVector(.{ .secret_zeroization = 0.70, .bounds_checking = 0.56 }),
        targetVector(.{ .state_isolation = 0.68, .input_validation = 0.42 }),
        zero_targets,
    },
};

fn targetVector(comptime weights: anytype) TargetVector {
    @setEvalBranchQuota(100_000);
    var out: TargetVector = @splat(0.0);
    inline for (std.meta.fields(@TypeOf(weights))) |field| {
        const target = comptime std.meta.stringToEnum(SemanticTarget, field.name) orelse
            @compileError("unknown semantic target: " ++ field.name);
        out[target.lane()] = @field(weights, field.name);
    }
    return out;
}

test "OPTIMIZE resolves to different physical targets for DSP and DATABASE" {
    const dsp = resolveIntentDomain(.optimize, .dsp);
    const database = resolveIntentDomain(.optimize, .database);

    try std.testing.expectEqual(ConfidenceBand.green_verified, dsp.confidence_band);
    try std.testing.expectEqual(ConfidenceBand.green_verified, database.confidence_band);

    try std.testing.expect(dsp.hasTarget(.branch_prediction_flattening));
    try std.testing.expect(dsp.hasTarget(.heap_allocation_ban));
    try std.testing.expect(!dsp.hasTarget(.index_traversal));

    try std.testing.expect(database.hasTarget(.io_wait_reduction));
    try std.testing.expect(database.hasTarget(.index_traversal));
    try std.testing.expect(!database.hasTarget(.heap_allocation_ban));
}

test "unknown or empty domain decays confidence to heuristic warning" {
    const unknown = resolve(intentVector(.optimize), unknownDomainVector());
    try std.testing.expectEqual(ConfidenceBand.yellow_heuristic, unknown.confidence_band);
    try std.testing.expect(unknown.confidence < 0.25);
    try std.testing.expect(unknown.sparse_or_unknown_domain);
    try std.testing.expectEqual(@as(usize, 0), unknown.targetSlice().len);

    const empty_set = resolveIntentDomainSet(.optimize, inference.DomainSet.empty);
    try std.testing.expectEqual(ConfidenceBand.yellow_heuristic, empty_set.confidence_band);
    try std.testing.expect(empty_set.confidence < 0.25);
}
