const std = @import("std");
const abstractions = @import("abstractions.zig");
const shards = @import("shards.zig");

const FEEDBACK_DIR = "feedback";
const EVENTS_FILE = "events.gfb.jsonl";
const MAX_REINFORCEMENT_EVENTS = 8;
const MAX_REINFORCEMENT_RECORDS = 4;

pub const Source = enum {
    user,
    verifier,
    system,
};

pub const Type = enum {
    success,
    failure,
    correction,
    preference,
};

pub const Event = struct {
    id: []const u8,
    source: Source,
    type: Type,
    related_artifact: []const u8,
    related_intent: []const u8,
    related_candidate: []const u8,
    outcome: []const u8,
    timestamp: []const u8,
    provenance: []const u8,
};

pub const UserFeedbackRequest = struct {
    text: []const u8,
    related_artifact: []const u8 = "",
    related_intent: []const u8 = "",
    related_candidate: []const u8 = "",
    timestamp: []const u8 = "deterministic:0",
    provenance: []const u8 = "user_explicit_feedback",
};

pub fn eventFromUserText(allocator: std.mem.Allocator, request: UserFeedbackRequest) !Event {
    const feedback_type: Type = if (containsIgnoreCase(request.text, "this worked"))
        .success
    else if (containsIgnoreCase(request.text, "this is wrong"))
        .failure
    else if (containsIgnoreCase(request.text, "i meant") or containsIgnoreCase(request.text, "not"))
        .correction
    else
        .preference;

    const id = try eventId(allocator, .user, feedback_type, request.related_artifact, request.related_intent, request.related_candidate, request.text);
    errdefer allocator.free(id);
    return .{
        .id = id,
        .source = .user,
        .type = feedback_type,
        .related_artifact = request.related_artifact,
        .related_intent = request.related_intent,
        .related_candidate = request.related_candidate,
        .outcome = request.text,
        .timestamp = request.timestamp,
        .provenance = request.provenance,
    };
}

pub fn recordUserFeedback(allocator: std.mem.Allocator, paths: *const shards.Paths, request: UserFeedbackRequest) !usize {
    const event = try eventFromUserText(allocator, request);
    defer allocator.free(event.id);
    return recordAndApply(allocator, paths, event);
}

pub fn recordAndApply(allocator: std.mem.Allocator, paths: *const shards.Paths, event: Event) !usize {
    try appendEvent(allocator, paths, event);
    var reinforcements = std.ArrayList(abstractions.ReinforcementEvent).init(allocator);
    defer {
        for (reinforcements.items) |item| deinitFeedbackReinforcement(allocator, item);
        reinforcements.deinit();
    }
    try appendReinforcementEvents(allocator, &reinforcements, event);
    return abstractions.applyReinforcementEvents(allocator, paths, reinforcements.items, .{
        .max_events = MAX_REINFORCEMENT_EVENTS,
        .max_new_records = MAX_REINFORCEMENT_RECORDS,
    });
}

pub fn replayIntoReinforcement(allocator: std.mem.Allocator, paths: *const shards.Paths) !usize {
    const events = try loadEvents(allocator, paths);
    defer {
        for (events) |event| deinitLoadedEvent(allocator, event);
        allocator.free(events);
    }
    var reinforcements = std.ArrayList(abstractions.ReinforcementEvent).init(allocator);
    defer {
        for (reinforcements.items) |item| deinitFeedbackReinforcement(allocator, item);
        reinforcements.deinit();
    }
    for (events) |event| try appendReinforcementEvents(allocator, &reinforcements, event);
    return abstractions.applyReinforcementEvents(allocator, paths, reinforcements.items, .{
        .max_events = reinforcements.items.len,
        .max_new_records = reinforcements.items.len,
    });
}

pub fn countEvents(allocator: std.mem.Allocator, paths: *const shards.Paths) !usize {
    const events = try loadEvents(allocator, paths);
    defer {
        for (events) |event| deinitLoadedEvent(allocator, event);
        allocator.free(events);
    }
    return events.len;
}

pub fn appendEvent(allocator: std.mem.Allocator, paths: *const shards.Paths, event: Event) !void {
    const dir = try std.fs.path.join(allocator, &.{ paths.root_abs_path, FEEDBACK_DIR });
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(paths.root_abs_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const file_path = try std.fs.path.join(allocator, &.{ dir, EVENTS_FILE });
    defer allocator.free(file_path);
    var file = try std.fs.createFileAbsolute(file_path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try std.json.stringify(event, .{}, file.writer());
    try file.writer().writeByte('\n');
}

fn loadEvents(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]Event {
    const file_path = try std.fs.path.join(allocator, &.{ paths.root_abs_path, FEEDBACK_DIR, EVENTS_FILE });
    defer allocator.free(file_path);
    var file = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer file.close();
    const body = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(body);

    var out = std.ArrayList(Event).init(allocator);
    errdefer {
        for (out.items) |event| deinitLoadedEvent(allocator, event);
        out.deinit();
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        var parsed = try std.json.parseFromSlice(Event, allocator, line, .{});
        defer parsed.deinit();
        try out.append(try cloneEvent(allocator, parsed.value));
    }
    return out.toOwnedSlice();
}

fn appendReinforcementEvents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(abstractions.ReinforcementEvent),
    event: Event,
) !void {
    const outcome = reinforcementOutcome(event) orelse return;
    if (event.related_intent.len > 0) {
        try out.append(.{
            .family = .intent_interpretation,
            .key = event.related_intent,
            .case_id = event.id,
            .tier = .pattern,
            .category = .interface,
            .outcome = outcome,
            .source_specs = try sourceSlice(allocator, event.related_artifact),
            .patterns = try patternSlice(allocator, &.{
                .{ .prefix = "artifact:", .value = event.related_artifact },
                .{ .prefix = "candidate:", .value = event.related_candidate },
                .{ .prefix = "feedback:", .value = @tagName(event.type) },
            }),
            .detail = event.provenance,
        });
    }
    if (event.related_candidate.len > 0) {
        try out.append(.{
            .family = .action_surface,
            .key = event.related_candidate,
            .case_id = event.id,
            .tier = .pattern,
            .category = .control_flow,
            .outcome = outcome,
            .source_specs = try sourceSlice(allocator, event.related_artifact),
            .patterns = try patternSlice(allocator, &.{
                .{ .prefix = "intent:", .value = event.related_intent },
                .{ .prefix = "outcome:", .value = event.outcome },
                .{ .prefix = "feedback:", .value = @tagName(event.type) },
            }),
            .detail = event.provenance,
        });
    }
    if (event.source == .verifier and event.outcome.len > 0) {
        try out.append(.{
            .family = .verifier_pattern,
            .key = event.outcome,
            .case_id = event.id,
            .tier = .pattern,
            .category = .invariant,
            .outcome = outcome,
            .source_specs = try sourceSlice(allocator, event.related_artifact),
            .patterns = try patternSlice(allocator, &.{
                .{ .prefix = "artifact:", .value = event.related_artifact },
                .{ .prefix = "candidate:", .value = event.related_candidate },
                .{ .prefix = "intent:", .value = event.related_intent },
            }),
            .detail = event.provenance,
        });
    }
}

fn reinforcementOutcome(event: Event) ?abstractions.ReinforcementOutcome {
    return switch (event.type) {
        .success => .success,
        .failure => .failure,
        .correction => .success,
        .preference => null,
    };
}

fn eventId(
    allocator: std.mem.Allocator,
    source: Source,
    event_type: Type,
    artifact: []const u8,
    intent: []const u8,
    candidate: []const u8,
    outcome: []const u8,
) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, outcome) ^ std.hash.Wyhash.hash(1, artifact) ^ std.hash.Wyhash.hash(2, intent) ^ std.hash.Wyhash.hash(3, candidate);
    return std.fmt.allocPrint(allocator, "{s}:{s}:{x}", .{ @tagName(source), @tagName(event_type), hash });
}

fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, if (value.len > 0) value else "<none>" });
}

const PatternPart = struct {
    prefix: []const u8,
    value: []const u8,
};

fn patternSlice(allocator: std.mem.Allocator, parts: []const PatternPart) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, parts.len);
    errdefer allocator.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |item| allocator.free(item);
    for (parts, 0..) |part, idx| {
        out[idx] = try prefixed(allocator, part.prefix, part.value);
        built += 1;
    }
    return out;
}

fn sourceSlice(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    if (source.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, 1);
    out[0] = source;
    return out;
}

fn deinitFeedbackReinforcement(allocator: std.mem.Allocator, event: abstractions.ReinforcementEvent) void {
    if (event.source_specs.len > 0) allocator.free(@constCast(event.source_specs));
    for (event.patterns) |item| allocator.free(item);
    if (event.patterns.len > 0) allocator.free(@constCast(event.patterns));
}

fn cloneEvent(allocator: std.mem.Allocator, event: Event) !Event {
    return .{
        .id = try allocator.dupe(u8, event.id),
        .source = event.source,
        .type = event.type,
        .related_artifact = try allocator.dupe(u8, event.related_artifact),
        .related_intent = try allocator.dupe(u8, event.related_intent),
        .related_candidate = try allocator.dupe(u8, event.related_candidate),
        .outcome = try allocator.dupe(u8, event.outcome),
        .timestamp = try allocator.dupe(u8, event.timestamp),
        .provenance = try allocator.dupe(u8, event.provenance),
    };
}

fn deinitLoadedEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.id);
    allocator.free(event.related_artifact);
    allocator.free(event.related_intent);
    allocator.free(event.related_candidate);
    allocator.free(event.outcome);
    allocator.free(event.timestamp);
    allocator.free(event.provenance);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

test "user correction reinforces intent mapping without proof authority" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "feedback-user-correction-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    _ = try recordUserFeedback(allocator, &paths, .{
        .text = "I meant refactor, not explain",
        .related_artifact = "draft:1",
        .related_intent = "refactor",
        .related_candidate = "candidate:local_guard",
    });

    const refs = try abstractions.lookupFamilyConcepts(allocator, &paths, .{
        .family = .intent_interpretation,
        .patterns = &.{"feedback:correction"},
        .max_items = 4,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "verified success reinforcement becomes reusable after independent cases" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "feedback-success-reuse-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    _ = try recordAndApply(allocator, &paths, .{
        .id = "verifier:success:case-a",
        .source = .verifier,
        .type = .success,
        .related_artifact = "deep_path:a",
        .related_intent = "refactor",
        .related_candidate = "candidate:local_guard",
        .outcome = "supported",
        .timestamp = "deterministic:1",
        .provenance = "test",
    });
    _ = try recordAndApply(allocator, &paths, .{
        .id = "verifier:success:case-b",
        .source = .verifier,
        .type = .success,
        .related_artifact = "deep_path:b",
        .related_intent = "refactor",
        .related_candidate = "candidate:local_guard",
        .outcome = "supported",
        .timestamp = "deterministic:2",
        .provenance = "test",
    });

    const refs = try abstractions.lookupFamilyConcepts(allocator, &paths, .{
        .family = .action_surface,
        .patterns = &.{"feedback:success"},
        .max_items = 4,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);
    try std.testing.expect(refs.len > 0);
}

test "verified failure reinforcement blocks otherwise successful pattern reuse" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "feedback-failure-block-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    const events = [_]Event{
        .{ .id = "verifier:success:case-a", .source = .verifier, .type = .success, .related_artifact = "deep_path:a", .related_intent = "refactor", .related_candidate = "candidate:local_guard", .outcome = "supported", .timestamp = "deterministic:1", .provenance = "test" },
        .{ .id = "verifier:success:case-b", .source = .verifier, .type = .success, .related_artifact = "deep_path:b", .related_intent = "refactor", .related_candidate = "candidate:local_guard", .outcome = "supported", .timestamp = "deterministic:2", .provenance = "test" },
        .{ .id = "verifier:failure:case-c", .source = .verifier, .type = .failure, .related_artifact = "deep_path:c", .related_intent = "refactor", .related_candidate = "candidate:local_guard", .outcome = "test_failed", .timestamp = "deterministic:3", .provenance = "test" },
    };
    for (events) |event| _ = try recordAndApply(allocator, &paths, event);

    const refs = try abstractions.lookupFamilyConcepts(allocator, &paths, .{
        .family = .action_surface,
        .patterns = &.{"feedback:success"},
        .max_items = 4,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "unresolved preference feedback records no reinforcement" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "feedback-unresolved-no-reinforce-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    _ = try recordAndApply(allocator, &paths, .{
        .id = "system:preference:unresolved",
        .source = .system,
        .type = .preference,
        .related_artifact = "draft:unresolved",
        .related_intent = "explain",
        .related_candidate = "candidate:none",
        .outcome = "unresolved",
        .timestamp = "deterministic:1",
        .provenance = "test",
    });

    const refs = try abstractions.lookupFamilyConcepts(allocator, &paths, .{
        .family = .intent_interpretation,
        .patterns = &.{"feedback:preference"},
        .max_items = 4,
    });
    defer abstractions.deinitSupportReferences(allocator, refs);
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "feedback replay is deterministic" {
    const allocator = std.testing.allocator;
    var metadata = try shards.resolveProjectMetadata(allocator, "feedback-replay-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    const event = Event{
        .id = "verifier:success:case-a",
        .source = .verifier,
        .type = .success,
        .related_artifact = "deep_path:case-a",
        .related_intent = "refactor",
        .related_candidate = "candidate:local_guard",
        .outcome = "supported",
        .timestamp = "deterministic:1",
        .provenance = "test",
    };
    _ = try recordAndApply(allocator, &paths, event);
    const first = try replayIntoReinforcement(allocator, &paths);
    const second = try replayIntoReinforcement(allocator, &paths);
    try std.testing.expectEqual(first, second);
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
