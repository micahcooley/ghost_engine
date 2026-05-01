const std = @import("std");

pub const DEFAULT_MAX_FACTS: usize = 128;
pub const DEFAULT_MAX_RULES: usize = 64;
pub const DEFAULT_MAX_FIRED_RULES: usize = 32;
pub const DEFAULT_MAX_OUTPUTS: usize = 128;

pub const HARD_MAX_FACTS: usize = 512;
pub const HARD_MAX_RULES: usize = 256;
pub const HARD_MAX_FIRED_RULES: usize = 128;
pub const HARD_MAX_OUTPUTS: usize = 512;

pub const Fact = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    source: []const u8 = "request",
};

pub const Condition = struct {
    subject: []const u8,
    predicate: []const u8,
    object: ?[]const u8 = null,
};

pub const OutputKind = enum {
    risk_candidate,
    check_candidate,
    evidence_expectation,
    unknown,
    follow_up_candidate,
    fact,

    pub fn text(self: OutputKind) []const u8 {
        return @tagName(self);
    }
};

pub const RuleOutput = struct {
    kind: OutputKind,
    id: []const u8,
    summary: []const u8,
    detail: []const u8 = "",
    risk_level: []const u8 = "medium",
};

pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    all: []const Condition = &.{},
    any: []const Condition = &.{},
    outputs: []const RuleOutput = &.{},
};

pub const Limits = struct {
    max_facts: usize = DEFAULT_MAX_FACTS,
    max_rules: usize = DEFAULT_MAX_RULES,
    max_fired_rules: usize = DEFAULT_MAX_FIRED_RULES,
    max_outputs: usize = DEFAULT_MAX_OUTPUTS,

    pub fn capped(self: Limits) Limits {
        return .{
            .max_facts = @min(self.max_facts, HARD_MAX_FACTS),
            .max_rules = @min(self.max_rules, HARD_MAX_RULES),
            .max_fired_rules = @min(self.max_fired_rules, HARD_MAX_FIRED_RULES),
            .max_outputs = @min(self.max_outputs, HARD_MAX_OUTPUTS),
        };
    }
};

pub const SafetyFlags = struct {
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    corpus_mutation: bool = false,
    pack_mutation: bool = false,
    negative_knowledge_mutation: bool = false,
    proof_discharged: bool = false,
    support_granted: bool = false,
};

pub const CapacityTelemetry = struct {
    dropped_runes: usize = 0,
    collision_stalls: usize = 0,
    saturated_slots: usize = 0,
    truncated_inputs: usize = 0,
    truncated_snippets: usize = 0,
    skipped_inputs: usize = 0,
    skipped_files: usize = 0,
    budget_hits: usize = 0,
    max_results_hit: bool = false,
    max_outputs_hit: bool = false,
    max_rules_hit: bool = false,
    max_fired_rules_hit: bool = false,
    max_facts_hit: bool = false,
    rejected_outputs: usize = 0,
    unknowns_created: usize = 0,
    expansion_recommended: bool = false,
    spillover_recommended: bool = false,

    pub fn hasPressure(self: CapacityTelemetry) bool {
        return self.budget_hits != 0 or
            self.max_outputs_hit or
            self.max_rules_hit or
            self.max_fired_rules_hit or
            self.max_facts_hit or
            self.rejected_outputs != 0;
    }
};

pub const FiredRule = struct {
    id: []const u8,
    name: []const u8,
    matched_all: usize,
    matched_any: bool,
};

pub const EmittedOutput = struct {
    kind: OutputKind,
    id: []const u8,
    rule_id: []const u8,
    summary: []const u8,
    detail: []const u8,
    risk_level: []const u8,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    executes_by_default: bool = false,
    status: []const u8 = "pending",
    executed: bool = false,
    treated_as_proof: bool = false,
};

pub const ExplanationTrace = struct {
    rule_id: []const u8,
    rule_name: []const u8,
    fired: bool,
    matched_all: usize,
    required_all: usize,
    matched_any: bool,
    required_any: usize,
    reason: []const u8,
};

pub const EvaluationResult = struct {
    allocator: std.mem.Allocator,
    fired_rules: []FiredRule,
    emitted_candidates: []EmittedOutput,
    emitted_obligations: []EmittedOutput,
    emitted_unknowns: []EmittedOutput,
    explanation_trace: []ExplanationTrace,
    limits: Limits,
    facts_considered: usize,
    rules_considered: usize,
    outputs_emitted: usize,
    budget_exhausted: bool = false,
    non_authorizing: bool = true,
    safety_flags: SafetyFlags = .{},
    capacity_telemetry: CapacityTelemetry = .{},

    pub fn deinit(self: *EvaluationResult) void {
        self.allocator.free(self.fired_rules);
        self.allocator.free(self.emitted_candidates);
        self.allocator.free(self.emitted_obligations);
        self.allocator.free(self.emitted_unknowns);
        self.allocator.free(self.explanation_trace);
        self.* = undefined;
    }
};

pub const Request = struct {
    facts: []const Fact,
    rules: []const Rule,
    limits: Limits = .{},
};

pub const Error = error{
    InvalidRule,
    FactLimitExceeded,
    RuleLimitExceeded,
};

pub fn validateRule(rule: Rule) Error!void {
    if (rule.id.len == 0 or rule.name.len == 0) return error.InvalidRule;
    if (rule.all.len == 0 and rule.any.len == 0) return error.InvalidRule;
    if (rule.outputs.len == 0) return error.InvalidRule;
    for (rule.all) |condition| try validateCondition(condition);
    for (rule.any) |condition| try validateCondition(condition);
    for (rule.outputs) |output| {
        if (output.id.len == 0 or output.summary.len == 0) return error.InvalidRule;
        if (output.kind == .fact) return error.InvalidRule;
    }
}

fn validateCondition(condition: Condition) Error!void {
    if (condition.subject.len == 0 or condition.predicate.len == 0) return error.InvalidRule;
}

pub fn evaluate(allocator: std.mem.Allocator, request: Request) !EvaluationResult {
    const limits = request.limits.capped();
    if (request.facts.len > limits.max_facts) return error.FactLimitExceeded;
    if (request.rules.len > limits.max_rules) return error.RuleLimitExceeded;

    for (request.rules) |rule| try validateRule(rule);

    var fired = std.ArrayList(FiredRule).init(allocator);
    errdefer fired.deinit();
    var candidates = std.ArrayList(EmittedOutput).init(allocator);
    errdefer candidates.deinit();
    var obligations = std.ArrayList(EmittedOutput).init(allocator);
    errdefer obligations.deinit();
    var unknowns = std.ArrayList(EmittedOutput).init(allocator);
    errdefer unknowns.deinit();
    var trace = std.ArrayList(ExplanationTrace).init(allocator);
    errdefer trace.deinit();

    var total_outputs: usize = 0;
    var budget_exhausted = false;
    var telemetry = CapacityTelemetry{};

    for (request.rules) |rule| {
        const all_count = countMatchingConditions(request.facts, rule.all);
        const any_match = anyConditionMatches(request.facts, rule.any);
        const all_match = all_count == rule.all.len;
        const any_ok = rule.any.len == 0 or any_match;
        const did_fire = all_match and any_ok;

        try trace.append(.{
            .rule_id = rule.id,
            .rule_name = rule.name,
            .fired = did_fire,
            .matched_all = all_count,
            .required_all = rule.all.len,
            .matched_any = any_match,
            .required_any = rule.any.len,
            .reason = if (did_fire) "all required conditions matched and optional any condition was satisfied" else "rule conditions were not satisfied",
        });

        if (!did_fire) continue;
        if (fired.items.len >= limits.max_fired_rules) {
            budget_exhausted = true;
            telemetry.max_fired_rules_hit = true;
            telemetry.max_rules_hit = true;
            telemetry.rejected_outputs += rule.outputs.len;
            telemetry.budget_hits += 1;
            break;
        }
        try fired.append(.{
            .id = rule.id,
            .name = rule.name,
            .matched_all = all_count,
            .matched_any = any_match,
        });

        for (rule.outputs, 0..) |output, output_idx| {
            if (total_outputs >= limits.max_outputs) {
                budget_exhausted = true;
                telemetry.max_outputs_hit = true;
                telemetry.rejected_outputs += rule.outputs.len - output_idx;
                telemetry.budget_hits += 1;
                break;
            }
            const emitted = emittedFromOutput(rule.id, output);
            switch (output.kind) {
                .risk_candidate, .check_candidate, .follow_up_candidate => try candidates.append(emitted),
                .evidence_expectation => try obligations.append(emitted),
                .unknown => try unknowns.append(emitted),
                .fact => unreachable,
            }
            total_outputs += 1;
        }
        if (budget_exhausted) break;
    }
    telemetry.unknowns_created = unknowns.items.len;
    telemetry.expansion_recommended = telemetry.hasPressure();

    return .{
        .allocator = allocator,
        .fired_rules = try fired.toOwnedSlice(),
        .emitted_candidates = try candidates.toOwnedSlice(),
        .emitted_obligations = try obligations.toOwnedSlice(),
        .emitted_unknowns = try unknowns.toOwnedSlice(),
        .explanation_trace = try trace.toOwnedSlice(),
        .limits = limits,
        .facts_considered = request.facts.len,
        .rules_considered = request.rules.len,
        .outputs_emitted = total_outputs,
        .budget_exhausted = budget_exhausted,
        .capacity_telemetry = telemetry,
    };
}

fn emittedFromOutput(rule_id: []const u8, output: RuleOutput) EmittedOutput {
    return .{
        .kind = output.kind,
        .id = output.id,
        .rule_id = rule_id,
        .summary = output.summary,
        .detail = output.detail,
        .risk_level = output.risk_level,
        .executes_by_default = false,
        .status = "pending",
        .executed = false,
        .treated_as_proof = false,
    };
}

fn countMatchingConditions(facts: []const Fact, conditions: []const Condition) usize {
    var matched: usize = 0;
    for (conditions) |condition| {
        if (conditionMatchesAnyFact(facts, condition)) matched += 1;
    }
    return matched;
}

fn anyConditionMatches(facts: []const Fact, conditions: []const Condition) bool {
    if (conditions.len == 0) return false;
    for (conditions) |condition| {
        if (conditionMatchesAnyFact(facts, condition)) return true;
    }
    return false;
}

fn conditionMatchesAnyFact(facts: []const Fact, condition: Condition) bool {
    for (facts) |fact| {
        if (!std.mem.eql(u8, fact.subject, condition.subject)) continue;
        if (!std.mem.eql(u8, fact.predicate, condition.predicate)) continue;
        if (condition.object) |object| {
            if (!std.mem.eql(u8, fact.object, object)) continue;
        }
        return true;
    }
    return false;
}

pub fn parseRequest(allocator: std.mem.Allocator, root: std.json.Value) !Request {
    if (root != .object) return error.InvalidRule;
    const obj = root.object;
    const facts_value = obj.get("facts") orelse return error.InvalidRule;
    const rules_value = obj.get("rules") orelse return error.InvalidRule;
    if (facts_value != .array or rules_value != .array) return error.InvalidRule;

    var facts = std.ArrayList(Fact).init(allocator);
    for (facts_value.array.items) |item| {
        const fact_obj = valueObject(item) orelse return error.InvalidRule;
        try facts.append(.{
            .subject = getRequiredString(fact_obj, "subject") orelse return error.InvalidRule,
            .predicate = getRequiredString(fact_obj, "predicate") orelse return error.InvalidRule,
            .object = getStringAliases(fact_obj, &.{ "object", "value" }) orelse return error.InvalidRule,
            .source = getStringAliases(fact_obj, &.{"source"}) orelse "request",
        });
    }

    var rules = std.ArrayList(Rule).init(allocator);
    for (rules_value.array.items) |item| {
        const rule_obj = valueObject(item) orelse return error.InvalidRule;
        const when_obj = if (rule_obj.get("when")) |when| valueObject(when) orelse return error.InvalidRule else null;
        const all_value = if (when_obj) |when| when.get("all") else rule_obj.get("all");
        const any_value = if (when_obj) |when| when.get("any") else rule_obj.get("any");
        const outputs_value = rule_obj.get("emit") orelse rule_obj.get("outputs") orelse return error.InvalidRule;
        if (outputs_value != .array) return error.InvalidRule;
        const parsed_rule = Rule{
            .id = getRequiredString(rule_obj, "id") orelse return error.InvalidRule,
            .name = getRequiredString(rule_obj, "name") orelse return error.InvalidRule,
            .all = try parseConditions(allocator, all_value),
            .any = try parseConditions(allocator, any_value),
            .outputs = try parseOutputs(allocator, outputs_value.array),
        };
        try validateRule(parsed_rule);
        try rules.append(parsed_rule);
    }

    return .{
        .facts = try facts.toOwnedSlice(),
        .rules = try rules.toOwnedSlice(),
        .limits = parseLimits(obj),
    };
}

fn parseConditions(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const Condition {
    const actual = value orelse return &.{};
    if (actual != .array) return error.InvalidRule;
    var out = std.ArrayList(Condition).init(allocator);
    for (actual.array.items) |item| {
        const obj = valueObject(item) orelse return error.InvalidRule;
        try out.append(.{
            .subject = getRequiredString(obj, "subject") orelse return error.InvalidRule,
            .predicate = getRequiredString(obj, "predicate") orelse return error.InvalidRule,
            .object = getStringAliases(obj, &.{ "object", "value" }),
        });
    }
    return try out.toOwnedSlice();
}

fn parseOutputs(allocator: std.mem.Allocator, array: std.json.Array) ![]const RuleOutput {
    var out = std.ArrayList(RuleOutput).init(allocator);
    for (array.items) |item| {
        const obj = valueObject(item) orelse return error.InvalidRule;
        const kind_text = getStringAliases(obj, &.{ "kind", "type" }) orelse return error.InvalidRule;
        try out.append(.{
            .kind = parseOutputKind(kind_text) orelse return error.InvalidRule,
            .id = getRequiredString(obj, "id") orelse return error.InvalidRule,
            .summary = getStringAliases(obj, &.{ "summary", "purpose" }) orelse return error.InvalidRule,
            .detail = getStringAliases(obj, &.{ "detail", "reason" }) orelse "",
            .risk_level = getStringAliases(obj, &.{ "risk_level", "riskLevel" }) orelse "medium",
        });
    }
    return try out.toOwnedSlice();
}

fn parseOutputKind(text: []const u8) ?OutputKind {
    inline for (std.meta.fields(OutputKind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseLimits(obj: std.json.ObjectMap) Limits {
    const value = obj.get("limits") orelse return .{};
    if (value != .object) return .{};
    const limits = value.object;
    return .{
        .max_facts = getUsize(limits, "maxFacts", "max_facts") orelse DEFAULT_MAX_FACTS,
        .max_rules = getUsize(limits, "maxRules", "max_rules") orelse DEFAULT_MAX_RULES,
        .max_fired_rules = getUsize(limits, "maxFiredRules", "max_fired_rules") orelse DEFAULT_MAX_FIRED_RULES,
        .max_outputs = getUsize(limits, "maxOutputs", "max_outputs") orelse DEFAULT_MAX_OUTPUTS,
    };
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn getRequiredString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getStringAliases(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (value == .string) return value.string;
        }
    }
    return null;
}

fn getUsize(obj: std.json.ObjectMap, camel: []const u8, snake: []const u8) ?usize {
    const value = obj.get(camel) orelse obj.get(snake) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const EvaluationResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"ruleEvaluation\":{");
    try w.writeAll("\"nonAuthorizing\":true,\"candidateOnly\":true,\"proofDischarged\":false,\"supportGranted\":false");
    try w.print(",\"factsConsidered\":{d},\"rulesConsidered\":{d},\"outputsEmitted\":{d},\"budgetExhausted\":{s}", .{
        result.facts_considered,
        result.rules_considered,
        result.outputs_emitted,
        if (result.budget_exhausted) "true" else "false",
    });
    try w.writeAll(",\"limits\":{");
    try w.print("\"maxFacts\":{d},\"maxRules\":{d},\"maxFiredRules\":{d},\"maxOutputs\":{d}", .{
        result.limits.max_facts,
        result.limits.max_rules,
        result.limits.max_fired_rules,
        result.limits.max_outputs,
    });
    try w.writeAll("},\"firedRules\":[");
    for (result.fired_rules, 0..) |rule, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, rule.id);
        try w.writeAll("\",\"name\":\"");
        try writeEscaped(w, rule.name);
        try w.print("\",\"matchedAll\":{d},\"matchedAny\":{s}}}", .{
            rule.matched_all,
            if (rule.matched_any) "true" else "false",
        });
    }
    try w.writeAll("],\"emittedCandidates\":");
    try writeOutputs(w, result.emitted_candidates, false);
    try w.writeAll(",\"emittedObligations\":");
    try writeOutputs(w, result.emitted_obligations, true);
    try w.writeAll(",\"emittedUnknowns\":");
    try writeOutputs(w, result.emitted_unknowns, false);
    try w.writeAll(",\"capacityTelemetry\":");
    try writeCapacityTelemetry(w, result.capacity_telemetry);
    try w.writeAll(",\"explanationTrace\":[");
    for (result.explanation_trace, 0..) |trace, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"ruleId\":\"");
        try writeEscaped(w, trace.rule_id);
        try w.writeAll("\",\"ruleName\":\"");
        try writeEscaped(w, trace.rule_name);
        try w.print("\",\"fired\":{s},\"matchedAll\":{d},\"requiredAll\":{d},\"matchedAny\":{s},\"requiredAny\":{d},\"reason\":\"", .{
            if (trace.fired) "true" else "false",
            trace.matched_all,
            trace.required_all,
            if (trace.matched_any) "true" else "false",
            trace.required_any,
        });
        try writeEscaped(w, trace.reason);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"safetyFlags\":{");
    try w.print("\"commandsExecuted\":{s},\"verifiersExecuted\":{s},\"corpusMutation\":{s},\"packMutation\":{s},\"negativeKnowledgeMutation\":{s},\"proofDischarged\":{s},\"supportGranted\":{s}", .{
        if (result.safety_flags.commands_executed) "true" else "false",
        if (result.safety_flags.verifiers_executed) "true" else "false",
        if (result.safety_flags.corpus_mutation) "true" else "false",
        if (result.safety_flags.pack_mutation) "true" else "false",
        if (result.safety_flags.negative_knowledge_mutation) "true" else "false",
        if (result.safety_flags.proof_discharged) "true" else "false",
        if (result.safety_flags.support_granted) "true" else "false",
    });
    try w.writeAll("}}}");
    return try out.toOwnedSlice();
}

fn writeCapacityTelemetry(w: anytype, telemetry: CapacityTelemetry) !void {
    try w.writeAll("{");
    try w.print("\"droppedRunes\":{d},\"collisionStalls\":{d},\"saturatedSlots\":{d}", .{ telemetry.dropped_runes, telemetry.collision_stalls, telemetry.saturated_slots });
    try w.print(",\"truncatedInputs\":{d},\"truncatedSnippets\":{d},\"skippedInputs\":{d},\"skippedFiles\":{d}", .{ telemetry.truncated_inputs, telemetry.truncated_snippets, telemetry.skipped_inputs, telemetry.skipped_files });
    try w.print(",\"budgetHits\":{d},\"maxResultsHit\":{s},\"maxOutputsHit\":{s},\"maxRulesHit\":{s}", .{
        telemetry.budget_hits,
        if (telemetry.max_results_hit) "true" else "false",
        if (telemetry.max_outputs_hit) "true" else "false",
        if (telemetry.max_rules_hit) "true" else "false",
    });
    try w.print(",\"maxFiredRulesHit\":{s},\"maxFactsHit\":{s},\"rejectedOutputs\":{d},\"unknownsCreated\":{d}", .{
        if (telemetry.max_fired_rules_hit) "true" else "false",
        if (telemetry.max_facts_hit) "true" else "false",
        telemetry.rejected_outputs,
        telemetry.unknowns_created,
    });
    try w.writeAll(",\"capacityWarnings\":[");
    var wrote = false;
    try writeWarningIf(w, &wrote, telemetry.max_outputs_hit, "max_outputs_hit");
    try writeWarningIf(w, &wrote, telemetry.max_fired_rules_hit, "max_fired_rules_hit");
    try writeWarningIf(w, &wrote, telemetry.max_rules_hit, "max_rules_hit");
    try writeWarningIf(w, &wrote, telemetry.max_facts_hit, "max_facts_hit");
    try writeWarningIf(w, &wrote, telemetry.rejected_outputs != 0, "outputs_rejected_by_capacity");
    try w.print("],\"expansionRecommended\":{s},\"spilloverRecommended\":{s}", .{
        if (telemetry.expansion_recommended) "true" else "false",
        if (telemetry.spillover_recommended) "true" else "false",
    });
    try w.writeAll("}");
}

fn writeWarningIf(w: anytype, wrote: *bool, condition: bool, warning: []const u8) !void {
    if (!condition) return;
    if (wrote.*) try w.writeByte(',');
    try w.writeByte('"');
    try writeEscaped(w, warning);
    try w.writeByte('"');
    wrote.* = true;
}

fn writeOutputs(w: anytype, outputs: []const EmittedOutput, obligations: bool) !void {
    try w.writeByte('[');
    for (outputs, 0..) |output, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":\"");
        try writeEscaped(w, output.kind.text());
        try w.writeAll("\",\"id\":\"");
        try writeEscaped(w, output.id);
        try w.writeAll("\",\"ruleId\":\"");
        try writeEscaped(w, output.rule_id);
        try w.writeAll("\",\"summary\":\"");
        try writeEscaped(w, output.summary);
        try w.writeAll("\",\"detail\":\"");
        try writeEscaped(w, output.detail);
        try w.writeAll("\",\"riskLevel\":\"");
        try writeEscaped(w, output.risk_level);
        try w.writeAll("\",\"candidateOnly\":true,\"nonAuthorizing\":true,\"executesByDefault\":false");
        if (obligations) {
            try w.writeAll(",\"status\":\"pending\",\"executed\":false,\"treatedAsProof\":false");
        }
        try w.writeAll("}");
    }
    try w.writeByte(']');
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

test "simple rule fires from matching facts" {
    const facts = [_]Fact{.{ .subject = "build", .predicate = "has", .object = "test" }};
    const outputs = [_]RuleOutput{.{ .kind = .check_candidate, .id = "check:test", .summary = "run explicit test verifier" }};
    const rules = [_]Rule{.{ .id = "rule:test", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fired_rules.len);
    try std.testing.expectEqual(@as(usize, 1), result.emitted_candidates.len);
}

test "non-matching rule does not fire" {
    const facts = [_]Fact{.{ .subject = "build", .predicate = "has", .object = "lint" }};
    const outputs = [_]RuleOutput{.{ .kind = .unknown, .id = "unknown:test", .summary = "missing test signal" }};
    const rules = [_]Rule{.{ .id = "rule:test", .name = "test rule", .all = &.{.{ .subject = "build", .predicate = "has", .object = "test" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.fired_rules.len);
    try std.testing.expectEqual(@as(usize, 0), result.emitted_unknowns.len);
}

test "multiple rules fire in deterministic order" {
    const facts = [_]Fact{.{ .subject = "artifact", .predicate = "kind", .object = "zig" }};
    const out_a = [_]RuleOutput{.{ .kind = .follow_up_candidate, .id = "a", .summary = "first" }};
    const out_b = [_]RuleOutput{.{ .kind = .follow_up_candidate, .id = "b", .summary = "second" }};
    const rules = [_]Rule{
        .{ .id = "rule:a", .name = "A", .all = &.{.{ .subject = "artifact", .predicate = "kind", .object = "zig" }}, .outputs = &out_a },
        .{ .id = "rule:b", .name = "B", .all = &.{.{ .subject = "artifact", .predicate = "kind", .object = "zig" }}, .outputs = &out_b },
    };
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqualStrings("rule:a", result.fired_rules[0].id);
    try std.testing.expectEqualStrings("rule:b", result.fired_rules[1].id);
}

test "rule explanation trace includes why it fired" {
    const facts = [_]Fact{.{ .subject = "risk", .predicate = "present", .object = "external_state" }};
    const outputs = [_]RuleOutput{.{ .kind = .risk_candidate, .id = "risk:external", .summary = "external state risk" }};
    const rules = [_]Rule{.{ .id = "rule:risk", .name = "risk rule", .all = &.{.{ .subject = "risk", .predicate = "present", .object = "external_state" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(true, result.explanation_trace[0].fired);
    try std.testing.expect(std.mem.indexOf(u8, result.explanation_trace[0].reason, "matched") != null);
}

test "invalid rule is rejected cleanly" {
    const outputs = [_]RuleOutput{.{ .kind = .unknown, .id = "unknown", .summary = "unknown" }};
    const rules = [_]Rule{.{ .id = "", .name = "invalid", .all = &.{.{ .subject = "a", .predicate = "b" }}, .outputs = &outputs }};
    try std.testing.expectError(error.InvalidRule, evaluate(std.testing.allocator, .{ .facts = &.{}, .rules = &rules }));
}

test "bounded max fired rules and outputs enforced" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const out_a = [_]RuleOutput{
        .{ .kind = .follow_up_candidate, .id = "a1", .summary = "a1" },
        .{ .kind = .follow_up_candidate, .id = "a2", .summary = "a2" },
    };
    const out_b = [_]RuleOutput{.{ .kind = .follow_up_candidate, .id = "b1", .summary = "b1" }};
    const rules = [_]Rule{
        .{ .id = "a", .name = "a", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &out_a },
        .{ .id = "b", .name = "b", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &out_b },
    };
    var result = try evaluate(std.testing.allocator, .{
        .facts = &facts,
        .rules = &rules,
        .limits = .{ .max_fired_rules = 1, .max_outputs = 1 },
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fired_rules.len);
    try std.testing.expectEqual(@as(usize, 1), result.outputs_emitted);
    try std.testing.expectEqual(true, result.budget_exhausted);
    try std.testing.expectEqual(true, result.capacity_telemetry.max_outputs_hit);
    try std.testing.expectEqual(@as(usize, 1), result.capacity_telemetry.budget_hits);
    try std.testing.expectEqual(true, result.capacity_telemetry.expansion_recommended);
}

test "cyclic recursive fact output pattern is rejected" {
    const outputs = [_]RuleOutput{.{ .kind = .fact, .id = "fact:derived", .summary = "derive fact" }};
    const rules = [_]Rule{.{ .id = "recursive", .name = "recursive", .all = &.{.{ .subject = "a", .predicate = "b" }}, .outputs = &outputs }};
    try std.testing.expectError(error.InvalidRule, evaluate(std.testing.allocator, .{ .facts = &.{}, .rules = &rules }));
}

test "emitted check candidate has executes_by_default false" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const outputs = [_]RuleOutput{.{ .kind = .check_candidate, .id = "check", .summary = "check" }};
    const rules = [_]Rule{.{ .id = "r", .name = "r", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(false, result.emitted_candidates[0].executes_by_default);
}

test "emitted obligation is pending unexecuted non-proof" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const outputs = [_]RuleOutput{.{ .kind = .evidence_expectation, .id = "obl", .summary = "collect evidence" }};
    const rules = [_]Rule{.{ .id = "r", .name = "r", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqualStrings("pending", result.emitted_obligations[0].status);
    try std.testing.expectEqual(false, result.emitted_obligations[0].executed);
    try std.testing.expectEqual(false, result.emitted_obligations[0].treated_as_proof);
    try std.testing.expectEqual(true, result.emitted_obligations[0].non_authorizing);
}

test "rule firing does not produce proof support or mutation flags" {
    const facts = [_]Fact{.{ .subject = "s", .predicate = "p", .object = "o" }};
    const outputs = [_]RuleOutput{.{ .kind = .risk_candidate, .id = "risk", .summary = "risk" }};
    const rules = [_]Rule{.{ .id = "r", .name = "r", .all = &.{.{ .subject = "s", .predicate = "p", .object = "o" }}, .outputs = &outputs }};
    var result = try evaluate(std.testing.allocator, .{ .facts = &facts, .rules = &rules });
    defer result.deinit();

    try std.testing.expectEqual(true, result.non_authorizing);
    try std.testing.expectEqual(false, result.safety_flags.commands_executed);
    try std.testing.expectEqual(false, result.safety_flags.verifiers_executed);
    try std.testing.expectEqual(false, result.safety_flags.corpus_mutation);
    try std.testing.expectEqual(false, result.safety_flags.pack_mutation);
    try std.testing.expectEqual(false, result.safety_flags.negative_knowledge_mutation);
    try std.testing.expectEqual(false, result.safety_flags.proof_discharged);
    try std.testing.expectEqual(false, result.safety_flags.support_granted);
}
