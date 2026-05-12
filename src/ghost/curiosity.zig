const std = @import("std");

pub const MAX_CONCURRENT_ZIG_TESTS: u8 = 1;
pub const DEFAULT_MAX_LOAD_AVG: f64 = 1.50;

pub const Concept = struct {
    name: []const u8,
};

pub const GuardState = struct {
    load_average_1m: f64 = 0,
    max_load_average_1m: f64 = DEFAULT_MAX_LOAD_AVG,
    zenith_audio_priority_requested: bool = false,
    oracle_paused_for_ram: bool = false,
    active_zig_tests: u8 = 0,

    pub fn canRun(self: GuardState) bool {
        return self.load_average_1m <= self.max_load_average_1m and
            !self.zenith_audio_priority_requested and
            !self.oracle_paused_for_ram and
            self.active_zig_tests < MAX_CONCURRENT_ZIG_TESTS;
    }
};

pub const InventionCandidate = struct {
    id: []u8,
    summary: []u8,
    source_concepts: []const []const u8,
    oracle_required: bool = true,
    non_authorizing: bool = true,

    fn deinit(self: *InventionCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.summary);
        self.* = undefined;
    }
};

pub const Analysis = struct {
    candidates: std.ArrayList(InventionCandidate),
    cold_zones: std.ArrayList([]u8),

    fn deinit(self: *Analysis) void {
        for (self.candidates.items) |*candidate| candidate.deinit(self.candidates.allocator);
        self.candidates.deinit();
        for (self.cold_zones.items) |zone| self.cold_zones.allocator.free(zone);
        self.cold_zones.deinit();
        self.* = undefined;
    }
};

pub fn analyzeAudioConcepts(allocator: std.mem.Allocator, concepts: []const Concept) !Analysis {
    var analysis = Analysis{
        .candidates = std.ArrayList(InventionCandidate).init(allocator),
        .cold_zones = std.ArrayList([]u8).init(allocator),
    };
    errdefer analysis.deinit();

    const has_low_pass = hasConcept(concepts, "low pass filter") or hasConcept(concepts, "low-pass filter");
    const has_high_pass = hasConcept(concepts, "high pass filter") or hasConcept(concepts, "high-pass filter");
    const has_band_pass = hasConcept(concepts, "band pass filter") or hasConcept(concepts, "band-pass filter");

    if (has_low_pass and has_high_pass and !has_band_pass) {
        try analysis.cold_zones.append(try allocator.dupe(u8, "audio.filter.band_pass"));
        try analysis.candidates.append(.{
            .id = try allocator.dupe(u8, "invent:audio.band_pass_filter"),
            .summary = try allocator.dupe(u8, "Speculative invention candidate: compose high-pass lower bound with low-pass upper bound and submit generated code to the Oracle"),
            .source_concepts = &.{ "low pass filter", "high pass filter" },
        });
    }

    if (analysis.candidates.items.len == 0) {
        try analysis.cold_zones.append(try allocator.dupe(u8, "none_detected_in_bounded_audio_pass"));
    }

    return analysis;
}

pub fn renderStatusJson(
    allocator: std.mem.Allocator,
    guard: GuardState,
    concepts: []const Concept,
) ![]u8 {
    var analysis = try analyzeAudioConcepts(allocator, concepts);
    defer analysis.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"curiosity\":{\"status\":");
    try std.json.stringify(if (guard.canRun()) "idle_ready" else "guarded", .{}, w);
    try w.print(",\"enabledByDefault\":false,\"maxConcurrentZigTests\":{d},\"guard\":{{\"loadAverage1m\":{d:.3},\"maxLoadAverage1m\":{d:.3},\"zenithAudioPriorityRequested\":{s},\"oraclePausedForRam\":{s},\"activeZigTests\":{d},\"canRun\":{s}}}", .{
        MAX_CONCURRENT_ZIG_TESTS,
        guard.load_average_1m,
        guard.max_load_average_1m,
        if (guard.zenith_audio_priority_requested) "true" else "false",
        if (guard.oracle_paused_for_ram) "true" else "false",
        guard.active_zig_tests,
        if (guard.canRun()) "true" else "false",
    });
    try w.writeAll(",\"coldZones\":[");
    for (analysis.cold_zones.items, 0..) |zone, idx| {
        if (idx != 0) try w.writeByte(',');
        try std.json.stringify(zone, .{}, w);
    }
    try w.writeAll("],\"speculativeInventions\":[");
    for (analysis.candidates.items, 0..) |candidate, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try std.json.stringify(candidate.id, .{}, w);
        try w.writeAll(",\"summary\":");
        try std.json.stringify(candidate.summary, .{}, w);
        try w.writeAll(",\"sourceConcepts\":[");
        for (candidate.source_concepts, 0..) |concept, cidx| {
            if (cidx != 0) try w.writeByte(',');
            try std.json.stringify(concept, .{}, w);
        }
        try w.print("],\"oracleRequired\":{s},\"nonAuthorizing\":{s}}}", .{
            if (candidate.oracle_required) "true" else "false",
            if (candidate.non_authorizing) "true" else "false",
        });
    }
    try w.writeAll("],\"mutationFlags\":{\"sourceMutation\":false,\"corpusMutation\":false,\"packMutation\":false,\"negativeKnowledgeMutation\":false,\"commandsExecuted\":false,\"verifiersExecuted\":false},\"authorityFlags\":{\"nonAuthorizing\":true,\"treatedAsProof\":false,\"usedAsEvidence\":false}}}");
    return out.toOwnedSlice();
}

pub fn currentLoadAverage1m() f64 {
    var file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch return 0;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return 0;
    return parseLoadAverage1m(buf[0..n]) catch 0;
}

pub fn parseLoadAverage1m(text: []const u8) !f64 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const first = it.next() orelse return error.MissingLoadAverage;
    return try std.fmt.parseFloat(f64, first);
}

fn hasConcept(concepts: []const Concept, name: []const u8) bool {
    for (concepts) |concept| {
        if (std.ascii.eqlIgnoreCase(concept.name, name)) return true;
    }
    return false;
}

test "guard blocks when zenith audio asks for priority" {
    const guard = GuardState{ .load_average_1m = 0.1, .zenith_audio_priority_requested = true };
    try std.testing.expect(!guard.canRun());
}

test "low pass and high pass imply band pass cold zone" {
    const concepts = [_]Concept{
        .{ .name = "Low Pass Filter" },
        .{ .name = "High Pass Filter" },
    };
    var analysis = try analyzeAudioConcepts(std.testing.allocator, &concepts);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.candidates.items.len);
    try std.testing.expectEqualStrings("invent:audio.band_pass_filter", analysis.candidates.items[0].id);
}

test "load average parser reads first field" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), try parseLoadAverage1m("0.42 0.50 0.60 1/100 1234\n"), 0.001);
}
