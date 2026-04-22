const std = @import("std");
const mc = @import("inference.zig");

pub const COMMAND_NAME = "/task";
pub const MAX_INPUT_BYTES: usize = 512;
pub const MAX_CONSTRAINTS: usize = 8;
pub const MAX_TRACES: usize = 16;

pub const ParseStatus = enum {
    grounded,
    unresolved,
    clarification_required,
};

pub const LanguageHint = enum {
    unknown,
    en,
};

pub const Action = enum {
    none,
    build,
    implement,
    refactor,
    explain,
    verify,
    compare,
    plan,
};

pub const TargetKind = enum {
    none,
    current_context,
    file,
    function,
    module,
    shard,
    concept,
    symbol,
};

pub const OutputMode = enum {
    none,
    patch,
    explanation,
    plan,
    alternatives,
};

pub const ConstraintKind = enum {
    language,
    performance,
    determinism,
    no_new_deps,
    api_stability,
    safety,
    linux_first,
};

pub const FlowKind = enum {
    none,
    code_intel,
    patch_candidates,
};

pub const QueryKind = enum {
    impact,
    breaks_if,
    contradicts,
};

pub const SelectionPolicy = enum {
    none,
    safest,
};

pub const TraceKind = enum {
    action_match,
    target_match,
    constraint_match,
    output_match,
    dispatch_match,
    ambiguity,
    unresolved,
};

pub const TraceField = enum {
    action,
    target,
    other_target,
    constraint,
    output_mode,
    dispatch,
    status,
};

pub const Options = struct {
    context_target: ?[]const u8 = null,
};

pub const Target = struct {
    kind: TargetKind = .none,
    spec: ?[]u8 = null,
    explicit: bool = false,

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        if (self.spec) |spec| allocator.free(spec);
        self.* = .{};
    }

    pub fn clone(self: Target, allocator: std.mem.Allocator) !Target {
        return .{
            .kind = self.kind,
            .spec = if (self.spec) |spec| try allocator.dupe(u8, spec) else null,
            .explicit = self.explicit,
        };
    }
};

pub const Constraint = struct {
    kind: ConstraintKind,
    value: ?[]u8 = null,
    numeric_value: u32 = 0,

    pub fn deinit(self: *Constraint, allocator: std.mem.Allocator) void {
        if (self.value) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn clone(self: Constraint, allocator: std.mem.Allocator) !Constraint {
        return .{
            .kind = self.kind,
            .value = if (self.value) |value| try allocator.dupe(u8, value) else null,
            .numeric_value = self.numeric_value,
        };
    }
};

pub const Dispatch = struct {
    flow: FlowKind = .none,
    query_kind: ?QueryKind = null,
    reasoning_mode: mc.ReasoningMode = .proof,
    requires_target: bool = true,
    executable: bool = false,
};

pub const Trace = struct {
    kind: TraceKind,
    field: TraceField,
    phrase: []u8,
    detail: ?[]u8 = null,

    pub fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        allocator.free(self.phrase);
        if (self.detail) |detail| allocator.free(detail);
        self.* = undefined;
    }

    pub fn clone(self: Trace, allocator: std.mem.Allocator) !Trace {
        return .{
            .kind = self.kind,
            .field = self.field,
            .phrase = try allocator.dupe(u8, self.phrase),
            .detail = if (self.detail) |detail| try allocator.dupe(u8, detail) else null,
        };
    }
};

pub const Task = struct {
    allocator: std.mem.Allocator,
    status: ParseStatus = .unresolved,
    raw_input: []u8,
    normalized_input: []u8,
    language_hint: LanguageHint = .unknown,
    action: Action = .none,
    target: Target = .{},
    other_target: Target = .{},
    output_mode: OutputMode = .none,
    constraints: []Constraint = &.{},
    requested_alternatives: u8 = 0,
    selection_policy: SelectionPolicy = .none,
    dispatch: Dispatch = .{},
    unresolved_detail: ?[]u8 = null,
    traces: []Trace = &.{},

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.raw_input);
        self.allocator.free(self.normalized_input);
        self.target.deinit(self.allocator);
        self.other_target.deinit(self.allocator);
        for (self.constraints) |*constraint| constraint.deinit(self.allocator);
        self.allocator.free(self.constraints);
        if (self.unresolved_detail) |detail| self.allocator.free(detail);
        for (self.traces) |*trace| trace.deinit(self.allocator);
        self.allocator.free(self.traces);
        self.* = undefined;
    }

    pub fn clone(self: *const Task, allocator: std.mem.Allocator) !Task {
        var constraints = try allocator.alloc(Constraint, self.constraints.len);
        errdefer allocator.free(constraints);
        for (self.constraints, 0..) |constraint, idx| {
            constraints[idx] = try constraint.clone(allocator);
        }
        errdefer {
            for (constraints[0..self.constraints.len]) |*constraint| constraint.deinit(allocator);
        }

        var traces = try allocator.alloc(Trace, self.traces.len);
        errdefer allocator.free(traces);
        for (self.traces, 0..) |trace, idx| {
            traces[idx] = try trace.clone(allocator);
        }
        errdefer {
            for (traces[0..self.traces.len]) |*trace| trace.deinit(allocator);
        }

        return .{
            .allocator = allocator,
            .status = self.status,
            .raw_input = try allocator.dupe(u8, self.raw_input),
            .normalized_input = try allocator.dupe(u8, self.normalized_input),
            .language_hint = self.language_hint,
            .action = self.action,
            .target = try self.target.clone(allocator),
            .other_target = try self.other_target.clone(allocator),
            .output_mode = self.output_mode,
            .constraints = constraints,
            .requested_alternatives = self.requested_alternatives,
            .selection_policy = self.selection_policy,
            .dispatch = self.dispatch,
            .unresolved_detail = if (self.unresolved_detail) |detail| try allocator.dupe(u8, detail) else null,
            .traces = traces,
        };
    }
};

const ActionPhrase = struct {
    phrase: []const u8,
    action: Action,
};

const ConstraintPhrase = struct {
    phrase: []const u8,
    kind: ConstraintKind,
    value: ?[]const u8 = null,
};

const TargetPrefix = struct {
    prefix: []const u8,
    kind: TargetKind,
};

const Match = struct {
    index: usize,
    phrase: []const u8,
};

const ACTION_PHRASES = [_]ActionPhrase{
    .{ .phrase = "build", .action = .build },
    .{ .phrase = "implement", .action = .implement },
    .{ .phrase = "refactor", .action = .refactor },
    .{ .phrase = "explain", .action = .explain },
    .{ .phrase = "verify", .action = .verify },
    .{ .phrase = "compare", .action = .compare },
};

const TARGET_PREFIXES = [_]TargetPrefix{
    .{ .prefix = "file ", .kind = .file },
    .{ .prefix = "function ", .kind = .function },
    .{ .prefix = "module ", .kind = .module },
    .{ .prefix = "shard ", .kind = .shard },
    .{ .prefix = "concept ", .kind = .concept },
};

const CONSTRAINT_PHRASES = [_]ConstraintPhrase{
    .{ .phrase = "keep the api stable", .kind = .api_stability },
    .{ .phrase = "api stable", .kind = .api_stability },
    .{ .phrase = "preserve the api", .kind = .api_stability },
    .{ .phrase = "without breaking the api", .kind = .api_stability },
    .{ .phrase = "deterministic", .kind = .determinism },
    .{ .phrase = "no deps", .kind = .no_new_deps },
    .{ .phrase = "no dependencies", .kind = .no_new_deps },
    .{ .phrase = "no new deps", .kind = .no_new_deps },
    .{ .phrase = "no new dependencies", .kind = .no_new_deps },
    .{ .phrase = "performance", .kind = .performance },
    .{ .phrase = "performant", .kind = .performance },
    .{ .phrase = "fast", .kind = .performance },
    .{ .phrase = "safest", .kind = .safety },
    .{ .phrase = "safe", .kind = .safety },
    .{ .phrase = "linux first", .kind = .linux_first },
    .{ .phrase = "linux-first", .kind = .linux_first },
};

pub fn isCommand(script: []const u8) bool {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    return std.mem.startsWith(u8, trimmed, COMMAND_NAME);
}

pub fn parseCommand(allocator: std.mem.Allocator, script: []const u8, options: Options) !Task {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    if (!std.mem.startsWith(u8, trimmed, COMMAND_NAME)) return error.InvalidTaskIntentCommand;
    const body = std.mem.trim(u8, trimmed[COMMAND_NAME.len..], " \r\n\t");
    if (body.len == 0) return error.InvalidTaskIntentCommand;
    return parse(allocator, body, options);
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, options: Options) !Task {
    const trimmed = std.mem.trim(u8, input, " \r\n\t");
    const clipped = if (trimmed.len <= MAX_INPUT_BYTES) trimmed else trimmed[0..MAX_INPUT_BYTES];
    const raw_input = try allocator.dupe(u8, clipped);
    errdefer allocator.free(raw_input);
    const normalized_input = try lowercaseAscii(allocator, clipped);
    errdefer allocator.free(normalized_input);

    var task = Task{
        .allocator = allocator,
        .raw_input = raw_input,
        .normalized_input = normalized_input,
    };
    errdefer task.deinit();

    var traces = std.ArrayList(Trace).init(allocator);
    defer traces.deinit();
    var constraints = std.ArrayList(Constraint).init(allocator);
    defer {
        for (constraints.items) |*constraint| constraint.deinit(allocator);
        constraints.deinit();
    }

    task.language_hint = detectLanguageHint(task.normalized_input);
    const action_state = detectAction(task.raw_input, task.normalized_input);
    if (action_state.ambiguous) {
        try appendTrace(allocator, &traces, .ambiguity, .action, action_state.phrase orelse "action", "multiple action phrases matched the request");
    } else if (action_state.action != .none) {
        task.action = action_state.action;
        if (action_state.phrase) |phrase| try appendTrace(allocator, &traces, .action_match, .action, phrase, null);
    }

    const output_state = detectOutputMode(task.normalized_input, task.action);
    task.output_mode = output_state.mode;
    task.requested_alternatives = output_state.requested_alternatives;
    task.selection_policy = output_state.selection_policy;
    if (output_state.phrase) |phrase| try appendTrace(allocator, &traces, .output_match, .output_mode, phrase, null);

    try detectConstraints(allocator, &constraints, &traces, task.normalized_input);

    if (task.action == .compare or containsBoundedPhrase(task.normalized_input, " vs ") != null) {
        const pair = extractCompareTargets(allocator, task.raw_input, task.normalized_input);
        task.target = pair.left;
        task.other_target = pair.right;
        if (task.target.kind != .none) try appendTrace(allocator, &traces, .target_match, .target, task.target.spec.?, null);
        if (task.other_target.kind != .none) try appendTrace(allocator, &traces, .target_match, .other_target, task.other_target.spec.?, null);
    } else {
        task.target = try detectPrimaryTarget(allocator, task.raw_input, task.normalized_input, options.context_target);
        if (task.target.kind != .none and task.target.spec != null) {
            try appendTrace(allocator, &traces, .target_match, .target, task.target.spec.?, null);
        }
    }

    task.constraints = try constraints.toOwnedSlice();
    constraints = std.ArrayList(Constraint).init(allocator);

    task.dispatch = determineDispatch(task);
    if (task.dispatch.flow != .none) {
        const detail = std.fmt.allocPrint(
            allocator,
            "{s}:{s}:{s}",
            .{
                flowKindName(task.dispatch.flow),
                if (task.dispatch.query_kind) |query_kind| queryKindName(query_kind) else "none",
                mc.reasoningModeName(task.dispatch.reasoning_mode),
            },
        ) catch null;
        defer if (detail) |owned| allocator.free(owned);
        try appendTrace(
            allocator,
            &traces,
            .dispatch_match,
            .dispatch,
            flowKindName(task.dispatch.flow),
            detail,
        );
    }

    task.traces = try traces.toOwnedSlice();
    traces = std.ArrayList(Trace).init(allocator);

    finalizeTask(allocator, &task, action_state.ambiguous, options.context_target == null);
    return task;
}

pub fn renderJson(allocator: std.mem.Allocator, task: *const Task) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", parseStatusName(task.status), true);
    try writeJsonFieldString(writer, "rawInput", task.raw_input, false);
    try writeJsonFieldString(writer, "normalizedInput", task.normalized_input, false);
    try writeJsonFieldString(writer, "languageHint", languageHintName(task.language_hint), false);
    try writeJsonFieldString(writer, "action", actionName(task.action), false);
    try writer.writeAll(",\"target\":");
    try writeTargetJson(writer, task.target);
    try writer.writeAll(",\"otherTarget\":");
    try writeTargetJson(writer, task.other_target);
    try writeJsonFieldString(writer, "outputMode", outputModeName(task.output_mode), false);
    try writer.print(",\"requestedAlternatives\":{d}", .{task.requested_alternatives});
    try writeJsonFieldString(writer, "selectionPolicy", selectionPolicyName(task.selection_policy), false);
    try writer.writeAll(",\"constraints\":");
    try writeConstraintArray(writer, task.constraints);
    try writer.writeAll(",\"dispatch\":{");
    try writeJsonFieldString(writer, "flow", flowKindName(task.dispatch.flow), true);
    try writeOptionalStringField(writer, "queryKind", if (task.dispatch.query_kind) |query_kind| queryKindName(query_kind) else "none");
    try writeJsonFieldString(writer, "reasoningMode", mc.reasoningModeName(task.dispatch.reasoning_mode), false);
    try writer.print(",\"requiresTarget\":{s}", .{if (task.dispatch.requires_target) "true" else "false"});
    try writer.print(",\"executable\":{s}", .{if (task.dispatch.executable) "true" else "false"});
    try writer.writeAll("}");
    if (task.unresolved_detail) |detail| try writeOptionalStringField(writer, "detail", detail);
    try writer.writeAll(",\"trace\":");
    try writeTraceArray(writer, task.traces);
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

pub fn parseStatusName(status: ParseStatus) []const u8 {
    return @tagName(status);
}

pub fn actionName(action: Action) []const u8 {
    return @tagName(action);
}

pub fn targetKindName(kind: TargetKind) []const u8 {
    return @tagName(kind);
}

pub fn outputModeName(mode: OutputMode) []const u8 {
    return @tagName(mode);
}

pub fn constraintKindName(kind: ConstraintKind) []const u8 {
    return @tagName(kind);
}

pub fn flowKindName(kind: FlowKind) []const u8 {
    return @tagName(kind);
}

pub fn queryKindName(kind: QueryKind) []const u8 {
    return switch (kind) {
        .impact => "impact",
        .breaks_if => "breaks-if",
        .contradicts => "contradicts",
    };
}

pub fn selectionPolicyName(policy: SelectionPolicy) []const u8 {
    return @tagName(policy);
}

pub fn languageHintName(hint: LanguageHint) []const u8 {
    return @tagName(hint);
}

fn finalizeTask(allocator: std.mem.Allocator, task: *Task, action_ambiguous: bool, missing_context_binding: bool) void {
    if (action_ambiguous) {
        setUnresolvedDetail(allocator, task, .clarification_required, "multiple action phrases matched; restate the task with one action");
        return;
    }
    if (task.action == .none) {
        setUnresolvedDetail(allocator, task, .clarification_required, "no deterministic task action was matched");
        return;
    }
    if (task.output_mode == .none) {
        setUnresolvedDetail(allocator, task, .clarification_required, "no deterministic output mode was matched");
        return;
    }
    if (task.target.kind == .none) {
        setUnresolvedDetail(allocator, task, .clarification_required, "task target is missing; name a file, function, module, shard, or concept");
        return;
    }
    if (task.target.kind == .current_context and missing_context_binding) {
        setUnresolvedDetail(allocator, task, .clarification_required, "deictic target requires an explicit binding; replace 'this' with a concrete file or symbol");
        return;
    }
    if (task.action == .compare and task.other_target.kind == .none) {
        setUnresolvedDetail(allocator, task, .clarification_required, "compare requires two explicit targets");
        return;
    }
    if (task.dispatch.flow == .none or task.dispatch.query_kind == null) {
        setUnresolvedDetail(allocator, task, .unresolved, "grounded intent did not map to a supported reasoning flow");
        return;
    }
    task.status = .grounded;
}

fn setUnresolvedDetail(allocator: std.mem.Allocator, task: *Task, status: ParseStatus, detail: []const u8) void {
    if (task.unresolved_detail) |existing| allocator.free(existing);
    task.unresolved_detail = allocator.dupe(u8, detail) catch null;
    task.status = status;
}

fn determineDispatch(task: Task) Dispatch {
    var dispatch = Dispatch{};
    // Intent grounding stays narrow on purpose. If the request does not map to
    // one of the shipped flows below, the caller should stay unresolved rather
    // than guessing a broader behavior.
    const alternatives_requested = task.output_mode == .alternatives or task.requested_alternatives > 1;
    dispatch.reasoning_mode = if (alternatives_requested) .exploratory else .proof;

    switch (task.action) {
        .compare => {
            dispatch.flow = .code_intel;
            dispatch.query_kind = .contradicts;
            dispatch.executable = task.target.kind != .none and task.other_target.kind != .none and task.target.kind != .current_context and task.other_target.kind != .current_context;
        },
        .explain, .verify => {
            dispatch.flow = .code_intel;
            dispatch.query_kind = if (containsBreakageSignal(task.normalized_input) or hasConstraint(task.constraints, .api_stability))
                .breaks_if
            else
                .impact;
            dispatch.executable = task.target.kind != .none and task.target.kind != .current_context;
        },
        .build, .implement, .refactor, .plan => {
            dispatch.flow = .patch_candidates;
            dispatch.query_kind = if (containsBreakageSignal(task.normalized_input) or hasConstraint(task.constraints, .api_stability))
                .breaks_if
            else
                .impact;
            dispatch.executable = task.target.kind != .none and task.target.kind != .current_context;
        },
        else => {},
    }
    return dispatch;
}

fn hasConstraint(constraints: []const Constraint, kind: ConstraintKind) bool {
    for (constraints) |constraint| {
        if (constraint.kind == kind) return true;
    }
    return false;
}

fn containsBreakageSignal(normalized: []const u8) bool {
    return containsBoundedPhrase(normalized, "breaks") != null or
        containsBoundedPhrase(normalized, "break") != null or
        containsBoundedPhrase(normalized, "broken") != null;
}

fn detectLanguageHint(normalized: []const u8) LanguageHint {
    for (normalized) |byte| {
        if (byte >= 'a' and byte <= 'z') return .en;
    }
    return .unknown;
}

fn detectAction(raw: []const u8, normalized: []const u8) struct { action: Action, ambiguous: bool, phrase: ?[]const u8 } {
    _ = raw;
    var found_action: Action = .none;
    var found_index: usize = std.math.maxInt(usize);
    var found_phrase: ?[]const u8 = null;
    var ambiguous = false;

    for (ACTION_PHRASES) |entry| {
        if (containsBoundedPhrase(normalized, entry.phrase)) |idx| {
            if (found_action == .none or idx < found_index) {
                found_action = entry.action;
                found_index = idx;
                found_phrase = entry.phrase;
            } else if (entry.action != found_action) {
                ambiguous = true;
            }
        }
    }

    if (found_action == .none and (containsBoundedPhrase(normalized, "ideas") != null or containsBoundedPhrase(normalized, "alternatives") != null or containsBoundedPhrase(normalized, "options") != null)) {
        return .{ .action = .plan, .ambiguous = false, .phrase = "ideas" };
    }

    return .{ .action = found_action, .ambiguous = ambiguous, .phrase = found_phrase };
}

fn detectOutputMode(normalized: []const u8, action: Action) struct {
    mode: OutputMode,
    requested_alternatives: u8,
    selection_policy: SelectionPolicy,
    phrase: ?[]const u8,
} {
    if (containsBoundedPhrase(normalized, "ideas") != null or
        containsBoundedPhrase(normalized, "alternatives") != null or
        containsBoundedPhrase(normalized, "options") != null)
    {
        return .{
            .mode = .alternatives,
            .requested_alternatives = parseIdeaCount(normalized),
            .selection_policy = if (containsBoundedPhrase(normalized, "safest") != null) .safest else .none,
            .phrase = if (containsBoundedPhrase(normalized, "ideas") != null) "ideas" else if (containsBoundedPhrase(normalized, "alternatives") != null) "alternatives" else "options",
        };
    }
    if (action == .explain or containsBoundedPhrase(normalized, "why ") != null) {
        return .{ .mode = .explanation, .requested_alternatives = 0, .selection_policy = .none, .phrase = "explain" };
    }
    if (containsBoundedPhrase(normalized, "plan") != null or action == .plan) {
        return .{ .mode = .plan, .requested_alternatives = 0, .selection_policy = .none, .phrase = "plan" };
    }
    if (action == .build or action == .implement or action == .refactor) {
        return .{ .mode = .patch, .requested_alternatives = 0, .selection_policy = .none, .phrase = actionName(action) };
    }
    if (action == .verify or action == .compare) {
        return .{ .mode = .explanation, .requested_alternatives = 0, .selection_policy = .none, .phrase = actionName(action) };
    }
    return .{ .mode = .none, .requested_alternatives = 0, .selection_policy = .none, .phrase = null };
}

fn parseIdeaCount(normalized: []const u8) u8 {
    var previous: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, normalized, " \r\n\t,.:;!?()[]{}");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "ideas") or std.mem.eql(u8, token, "alternatives") or std.mem.eql(u8, token, "options")) {
            if (previous) |candidate| {
                if (std.fmt.parseUnsigned(u8, candidate, 10)) |count| return count else |_| {}
                if (std.mem.eql(u8, candidate, "one")) return 1;
                if (std.mem.eql(u8, candidate, "two")) return 2;
                if (std.mem.eql(u8, candidate, "three")) return 3;
                if (std.mem.eql(u8, candidate, "four")) return 4;
            }
        }
        previous = token;
    }
    return 0;
}

fn detectConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    traces: *std.ArrayList(Trace),
    normalized: []const u8,
) !void {
    for (CONSTRAINT_PHRASES) |entry| {
        if (constraints.items.len >= MAX_CONSTRAINTS) break;
        if (containsBoundedPhrase(normalized, entry.phrase) == null) continue;
        if (constraintAlreadyPresent(constraints.items, entry.kind, entry.value)) continue;
        try constraints.append(.{
            .kind = entry.kind,
            .value = if (entry.value) |value| try allocator.dupe(u8, value) else null,
        });
        try appendTrace(allocator, traces, .constraint_match, .constraint, entry.phrase, null);
    }

    if (findLanguageConstraint(normalized)) |language| {
        if (!constraintAlreadyPresent(constraints.items, .language, language)) {
            if (constraints.items.len < MAX_CONSTRAINTS) {
                try constraints.append(.{
                    .kind = .language,
                    .value = try allocator.dupe(u8, language),
                });
                try appendTrace(allocator, traces, .constraint_match, .constraint, language, "language constraint");
            }
        }
    }
}

fn findLanguageConstraint(normalized: []const u8) ?[]const u8 {
    const known = [_][]const u8{ "zig", "rust", "c", "c++", "cpp" };
    for (known) |language| {
        var phrase_buf: [16]u8 = undefined;
        const phrase = std.fmt.bufPrint(&phrase_buf, "in {s}", .{language}) catch continue;
        if (containsBoundedPhrase(normalized, phrase) != null) return language;
    }
    return null;
}

fn constraintAlreadyPresent(items: []const Constraint, kind: ConstraintKind, value: ?[]const u8) bool {
    for (items) |item| {
        if (item.kind != kind) continue;
        if (item.value == null and value == null) return true;
        if (item.value != null and value != null and std.mem.eql(u8, item.value.?, value.?)) return true;
    }
    return false;
}

fn detectPrimaryTarget(allocator: std.mem.Allocator, raw: []const u8, normalized: []const u8, context_target: ?[]const u8) !Target {
    for (TARGET_PREFIXES) |entry| {
        if (findPrefixedTarget(allocator, raw, normalized, entry.prefix, entry.kind)) |target| {
            return target;
        }
    }
    if (findQuotedTarget(allocator, raw)) |target| return target;
    if (findPathLikeTarget(allocator, raw)) |target| return target;
    if (findDeicticTarget(allocator, normalized)) |matched_target| {
        var target = matched_target;
        if (context_target) |bound| {
            target.deinit(allocator);
            return .{
                .kind = inferTargetKind(bound),
                .spec = try allocator.dupe(u8, bound),
                .explicit = true,
            };
        }
        return target;
    }
    return .{};
}

fn extractCompareTargets(allocator: std.mem.Allocator, raw: []const u8, normalized: []const u8) struct { left: Target, right: Target } {
    const compare_prefix = containsBoundedPhrase(normalized, "compare ");
    const start = if (compare_prefix) |idx| idx + "compare ".len else 0;
    const rest_raw = std.mem.trim(u8, raw[start..], " \r\n\t");
    const rest_norm = std.mem.trim(u8, normalized[start..], " \r\n\t");
    const split_idx = containsBoundedPhrase(rest_norm, " vs ") orelse containsBoundedPhrase(rest_norm, " and ");
    if (split_idx == null) return .{ .left = .{}, .right = .{} };

    const delimiter_len: usize = if (containsBoundedPhrase(rest_norm, " vs ")) |idx| if (idx == split_idx.?) 4 else 5 else 5;
    const left_spec = std.mem.trim(u8, rest_raw[0..split_idx.?], " \r\n\t,.");
    const right_spec = std.mem.trim(u8, rest_raw[split_idx.? + delimiter_len ..], " \r\n\t,.");
    return .{
        .left = makeExplicitTarget(allocator, left_spec) catch .{},
        .right = makeExplicitTarget(allocator, right_spec) catch .{},
    };
}

fn findPrefixedTarget(allocator: std.mem.Allocator, raw: []const u8, normalized: []const u8, prefix: []const u8, kind: TargetKind) ?Target {
    const idx = containsBoundedPhrase(normalized, prefix) orelse return null;
    const start = idx + prefix.len;
    const end = targetStopIndex(normalized, start);
    const spec = std.mem.trim(u8, raw[start..end], " \r\n\t,.");
    if (spec.len == 0) return null;
    return Target{
        .kind = kind,
        .spec = allocator.dupe(u8, spec) catch return null,
        .explicit = true,
    };
}

fn findQuotedTarget(allocator: std.mem.Allocator, raw: []const u8) ?Target {
    const quotes = [_]u8{ '"', '\'' };
    for (quotes) |quote| {
        const start = std.mem.indexOfScalar(u8, raw, quote) orelse continue;
        const end = std.mem.indexOfScalarPos(u8, raw, start + 1, quote) orelse continue;
        const spec = std.mem.trim(u8, raw[start + 1 .. end], " \r\n\t");
        if (spec.len == 0) continue;
        return makeExplicitTarget(allocator, spec) catch null;
    }
    return null;
}

fn findPathLikeTarget(allocator: std.mem.Allocator, raw: []const u8) ?Target {
    var it = std.mem.tokenizeAny(u8, raw, " \r\n\t");
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, ",.()[]{}");
        if (token.len == 0) continue;
        if (looksLikeTargetSpec(token)) {
            return makeExplicitTarget(allocator, token) catch null;
        }
    }
    return null;
}

fn findDeicticTarget(allocator: std.mem.Allocator, normalized: []const u8) ?Target {
    const phrases = [_][]const u8{ "this", "that", "it" };
    for (phrases) |phrase| {
        if (containsBoundedPhrase(normalized, phrase) != null) {
            return .{
                .kind = .current_context,
                .spec = allocator.dupe(u8, phrase) catch return null,
                .explicit = false,
            };
        }
    }
    return null;
}

fn targetStopIndex(normalized: []const u8, start: usize) usize {
    const stops = [_][]const u8{
        " but ",
        " with ",
        " while ",
        " then ",
        " because ",
        " why ",
        " in ",
    };
    var best = normalized.len;
    for (stops) |stop| {
        if (std.mem.indexOfPos(u8, normalized, start, stop)) |idx| {
            if (idx < best) best = idx;
        }
    }
    return best;
}

fn makeExplicitTarget(allocator: std.mem.Allocator, spec: []const u8) !Target {
    const trimmed = std.mem.trim(u8, spec, " \r\n\t,.");
    if (trimmed.len == 0) return .{};
    return .{
        .kind = inferTargetKind(trimmed),
        .spec = try allocator.dupe(u8, trimmed),
        .explicit = true,
    };
}

fn inferTargetKind(spec: []const u8) TargetKind {
    if (std.mem.indexOfScalar(u8, spec, ':')) |_| return .symbol;
    if (std.mem.indexOfScalar(u8, spec, '/')) |_| return .file;
    if (std.mem.endsWith(u8, spec, ".zig") or std.mem.endsWith(u8, spec, ".md") or std.mem.endsWith(u8, spec, ".txt")) return .file;
    return .concept;
}

fn looksLikeTargetSpec(token: []const u8) bool {
    return std.mem.indexOfScalar(u8, token, '/') != null or
        std.mem.indexOfScalar(u8, token, ':') != null or
        std.mem.endsWith(u8, token, ".zig") or
        std.mem.endsWith(u8, token, ".md") or
        std.mem.endsWith(u8, token, ".txt") or
        std.mem.endsWith(u8, token, ".cpp") or
        std.mem.endsWith(u8, token, ".h");
}

fn appendTrace(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(Trace),
    kind: TraceKind,
    field: TraceField,
    phrase: []const u8,
    detail: ?[]const u8,
) !void {
    if (traces.items.len >= MAX_TRACES) return;
    try traces.append(.{
        .kind = kind,
        .field = field,
        .phrase = try allocator.dupe(u8, phrase),
        .detail = if (detail) |value| try allocator.dupe(u8, value) else null,
    });
}

fn containsBoundedPhrase(text: []const u8, phrase: []const u8) ?usize {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, phrase)) |idx| {
        const before_ok = idx == 0 or !isWordByte(text[idx - 1]);
        const end = idx + phrase.len;
        const after_ok = end >= text.len or !isWordByte(text[end]);
        if (before_ok and after_ok) return idx;
        search_start = idx + 1;
    }
    return null;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '/' or byte == '.' or byte == ':';
}

fn lowercaseAscii(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

fn writeTargetJson(writer: anytype, target: Target) !void {
    try writer.writeAll("{");
    try writeJsonFieldString(writer, "kind", targetKindName(target.kind), true);
    if (target.spec) |spec| try writeOptionalStringField(writer, "spec", spec);
    try writer.print(",\"explicit\":{s}", .{if (target.explicit) "true" else "false"});
    try writer.writeAll("}");
}

fn writeConstraintArray(writer: anytype, constraints: []const Constraint) !void {
    try writer.writeAll("[");
    for (constraints, 0..) |constraint, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "kind", constraintKindName(constraint.kind), true);
        if (constraint.value) |value| try writeOptionalStringField(writer, "value", value);
        if (constraint.numeric_value != 0) try writer.print(",\"numericValue\":{d}", .{constraint.numeric_value});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeTraceArray(writer: anytype, traces: []const Trace) !void {
    try writer.writeAll("[");
    for (traces, 0..) |trace, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "kind", @tagName(trace.kind), true);
        try writeJsonFieldString(writer, "field", @tagName(trace.field), false);
        try writeJsonFieldString(writer, "phrase", trace.phrase, false);
        if (trace.detail) |detail| try writeOptionalStringField(writer, "detail", detail);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeJsonFieldString(writer: anytype, field: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeOptionalStringField(writer: anytype, field: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}
