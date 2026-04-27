const std = @import("std");

pub const State = enum {
    draft,
    checked,
    verified,
    unresolved,
    blocked,
    budget_exhausted,
    contradicted,
    correction_recorded,
    negative_knowledge_candidate_proposed,
    negative_knowledge_applied,
    stronger_verifier_required,
    exact_repeat_suppressed,
    routing_warning,
    trust_decay_candidate_proposed,
};

pub const Descriptor = struct {
    tag: []const u8,
    label: []const u8,
    summary: []const u8,
    authority_statement: []const u8,
    non_authorizing: bool,
    suggested_next_action: ?[]const u8 = null,
};

pub const Signals = struct {
    is_draft: bool = false,
    is_supported: bool = false,
    is_deep: bool = false,
    is_budget_exhausted: bool = false,
    is_blocked: bool = false,
    has_missing_obligation: bool = false,
};

pub fn descriptor(state: State) Descriptor {
    return switch (state) {
        .draft => .{
            .tag = "draft",
            .label = "Draft",
            .summary = "Draft: this is not verified yet.",
            .authority_statement = "Draft output is non-authorizing and cannot satisfy support requirements.",
            .non_authorizing = true,
            .suggested_next_action = "Run verification or collect evidence before treating this as supported.",
        },
        .checked => .{
            .tag = "checked",
            .label = "Checked",
            .summary = "Checked: Ghost completed bounded checks, but this is not stronger than the available evidence.",
            .authority_statement = "Checked output is limited to the checks that actually ran.",
            .non_authorizing = false,
        },
        .verified => .{
            .tag = "verified",
            .label = "Verified",
            .summary = "Verified: support requirements were met by the available evidence.",
            .authority_statement = "Only the support/proof gate authorizes this verified state.",
            .non_authorizing = false,
        },
        .unresolved => .{
            .tag = "unresolved",
            .label = "Unresolved",
            .summary = "Unresolved: Ghost needs more evidence or a missing obligation remains.",
            .authority_statement = "Unresolved output is non-authorizing and cannot be promoted to supported.",
            .non_authorizing = true,
            .suggested_next_action = "Provide the missing obligation, resolve ambiguity, or run a stronger verifier.",
        },
        .blocked => .{
            .tag = "blocked",
            .label = "Blocked",
            .summary = "Blocked: Ghost cannot safely continue this path.",
            .authority_statement = "Blocked output is non-authorizing and requires a changed condition before continuing.",
            .non_authorizing = true,
            .suggested_next_action = "Change the request, provide approval, or supply the missing safe execution path.",
        },
        .budget_exhausted => .{
            .tag = "budget_exhausted",
            .label = "Budget exhausted",
            .summary = "Budget exhausted: Ghost stopped because the selected compute budget was reached.",
            .authority_statement = "Budget exhaustion is non-authorizing and must remain explicit.",
            .non_authorizing = true,
            .suggested_next_action = "Increase the reasoning budget or narrow the request.",
        },
        .contradicted => .{
            .tag = "contradicted",
            .label = "Contradicted",
            .summary = "Contradicted: verifier evidence conflicts with the previous hypothesis.",
            .authority_statement = "Contradiction blocks the previous hypothesis from authorizing support.",
            .non_authorizing = true,
            .suggested_next_action = "Replace or revise the contradicted hypothesis before verification continues.",
        },
        .correction_recorded => .{
            .tag = "correction_recorded",
            .label = "Correction recorded",
            .summary = "Correction recorded: Ghost updated the investigation state based on contradicting evidence.",
            .authority_statement = "A correction records changed investigation state; it does not prove the new claim.",
            .non_authorizing = true,
        },
        .negative_knowledge_candidate_proposed => .{
            .tag = "negative_knowledge_candidate_proposed",
            .label = "Negative knowledge candidate proposed",
            .summary = "Negative knowledge candidate proposed: Ghost found a failure pattern that may be useful to remember after review.",
            .authority_statement = "A proposed candidate is not learned permanently and is not proof.",
            .non_authorizing = true,
            .suggested_next_action = "Review the candidate before allowing future influence.",
        },
        .negative_knowledge_applied => .{
            .tag = "negative_knowledge_applied",
            .label = "Negative knowledge applied",
            .summary = "Prior negative knowledge affected this result: Ghost changed triage/routing/verifier requirements based on a reviewed prior failure.",
            .authority_statement = "Reviewed negative knowledge can influence routing and verifier choice, but never proves a claim.",
            .non_authorizing = true,
        },
        .stronger_verifier_required => .{
            .tag = "stronger_verifier_required",
            .label = "Stronger verifier required",
            .summary = "Stronger verifier required: prior failure knowledge prevents trusting the weaker verifier path.",
            .authority_statement = "This requirement constrains verifier selection; it does not authorize support.",
            .non_authorizing = true,
            .suggested_next_action = "Run the stronger verifier path or keep the result unresolved.",
        },
        .exact_repeat_suppressed => .{
            .tag = "exact_repeat_suppressed",
            .label = "Exact repeat suppressed",
            .summary = "Exact repeat suppressed: Ghost avoided a previously failed hypothesis pattern.",
            .authority_statement = "Suppression avoids known failed work; it does not prove any remaining hypothesis.",
            .non_authorizing = true,
        },
        .routing_warning => .{
            .tag = "routing_warning",
            .label = "Routing warning",
            .summary = "Routing warning: prior failure knowledge made this route lower trust in the current scope.",
            .authority_statement = "A routing warning is advisory and non-authorizing.",
            .non_authorizing = true,
        },
        .trust_decay_candidate_proposed => .{
            .tag = "trust_decay_candidate_proposed",
            .label = "Trust decay candidate proposed",
            .summary = "Trust decay candidate proposed: a source or pack signal may be less reliable in this scope.",
            .authority_statement = "A trust-decay candidate requires review and does not mutate pack trust by itself.",
            .non_authorizing = true,
            .suggested_next_action = "Review the trust-decay candidate before changing future trust policy.",
        },
    };
}

pub fn primaryState(signals: Signals) State {
    if (signals.is_draft) return .draft;
    if (signals.is_budget_exhausted) return .budget_exhausted;
    if (signals.is_blocked) return .blocked;
    if (signals.is_supported and signals.is_deep) return .verified;
    if (signals.is_supported) return .checked;
    if (signals.has_missing_obligation) return .unresolved;
    return .unresolved;
}

pub fn isNonAuthorizing(state: State) bool {
    return descriptor(state).non_authorizing;
}

test "draft renders as unverified" {
    const d = descriptor(.draft);
    try std.testing.expectEqualStrings("draft", d.tag);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "not verified yet") != null);
    try std.testing.expect(d.non_authorizing);
}

test "verified renders with support evidence language" {
    const d = descriptor(.verified);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "support requirements were met") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "available evidence") != null);
    try std.testing.expect(!d.non_authorizing);
}

test "unresolved renders missing obligation language" {
    const d = descriptor(.unresolved);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "missing obligation remains") != null);
    try std.testing.expect(d.non_authorizing);
}

test "budget exhaustion remains explicit" {
    const d = descriptor(.budget_exhausted);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "compute budget") != null);
    try std.testing.expect(d.non_authorizing);
}

test "correction event renders correction recorded language" {
    const d = descriptor(.correction_recorded);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "Correction recorded") != null);
    try std.testing.expect(d.non_authorizing);
}

test "negative knowledge candidate is proposed and review needed" {
    const d = descriptor(.negative_knowledge_candidate_proposed);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "candidate proposed") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.authority_statement, "not learned permanently") != null);
    try std.testing.expect(d.non_authorizing);
}

test "accepted negative knowledge renders as prior failure influence" {
    const d = descriptor(.negative_knowledge_applied);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "reviewed prior failure") != null);
    try std.testing.expect(d.non_authorizing);
}

test "stronger verifier requirement renders correctly" {
    const d = descriptor(.stronger_verifier_required);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "weaker verifier path") != null);
    try std.testing.expect(d.non_authorizing);
}

test "exact repeat suppression renders explicitly" {
    const d = descriptor(.exact_repeat_suppressed);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "previously failed hypothesis pattern") != null);
    try std.testing.expect(d.non_authorizing);
}

test "trust decay candidate renders as candidate only" {
    const d = descriptor(.trust_decay_candidate_proposed);
    try std.testing.expect(std.mem.indexOf(u8, d.summary, "candidate proposed") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.authority_statement, "does not mutate pack trust") != null);
    try std.testing.expect(d.non_authorizing);
}

test "correction and negative knowledge states are non-authorizing" {
    try std.testing.expect(isNonAuthorizing(.correction_recorded));
    try std.testing.expect(isNonAuthorizing(.negative_knowledge_candidate_proposed));
    try std.testing.expect(isNonAuthorizing(.negative_knowledge_applied));
}

test "no correction or negative knowledge produces only primary state" {
    const state = primaryState(.{ .is_supported = false, .has_missing_obligation = true });
    try std.testing.expectEqual(State.unresolved, state);
}

test "renderer output deterministic" {
    const a = descriptor(primaryState(.{ .is_supported = true, .is_deep = true }));
    const b = descriptor(primaryState(.{ .is_supported = true, .is_deep = true }));
    try std.testing.expectEqualStrings(a.tag, b.tag);
    try std.testing.expectEqualStrings(a.summary, b.summary);
}

test "checked and verified remain distinct authority labels" {
    try std.testing.expectEqual(State.checked, primaryState(.{ .is_supported = true, .is_deep = false }));
    try std.testing.expectEqual(State.verified, primaryState(.{ .is_supported = true, .is_deep = true }));
}

test "non-code correction uses the same render model" {
    const d = descriptor(.correction_recorded);
    try std.testing.expect(std.mem.indexOf(u8, d.authority_statement, "does not prove") != null);
}
