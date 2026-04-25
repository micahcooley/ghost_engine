const std = @import("std");
const verifier_adapter = @import("verifier_adapter.zig");
const hypothesis_core = @import("hypothesis_core.zig");
const compute_budget = @import("compute_budget.zig");

test "verifier candidate lifecycle: proposed -> accepted -> materialized" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-1"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-1"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    try std.testing.expectEqual(verifier_adapter.CandidateStatus.proposed, candidate.status);

    // Accept
    const approval = verifier_adapter.VerifierCandidateApproval{
        .candidate_id = try allocator.dupe(u8, candidate.id),
        .approved_by = try allocator.dupe(u8, "test-user"),
        .approval_kind = .test_fixture,
        .approval_reason = try allocator.dupe(u8, "looks good"),
        .timestamp_ms = 12345,
        .trace = try allocator.dupe(u8, "approved"),
        .scope = try allocator.dupe(u8, "src/"),
    };
    try verifier_adapter.acceptVerifierCandidate(&candidate, approval);
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.accepted, candidate.status);
    try std.testing.expect(candidate.approval != null);

    // Materialize
    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = true,
    });
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.materialized, candidate.status);
    try std.testing.expect(candidate.materialization != null);
}

test "verifier candidate lifecycle: rejected candidate cannot be materialized" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-2"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-2"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    try verifier_adapter.rejectVerifierCandidate(&candidate, "not needed");
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.rejected, candidate.status);

    const err = verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = false,
    });
    try std.testing.expectError(error.InvalidStatus, err);
}

test "verifier candidate lifecycle: unaccepted candidate blocked by policy" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-3"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-3"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
    };
    defer candidate.deinit();

    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = true,
    });
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.blocked, candidate.status);
    try std.testing.expectEqual(verifier_adapter.CandidateBlockedReason.not_approved, candidate.blocked_reason.?);
}

test "verifier candidate lifecycle: authorizing candidate blocked" {
    const allocator = std.testing.allocator;

    var candidate = verifier_adapter.VerifierCandidate{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "cand-4"),
        .hypothesis_id = try allocator.dupe(u8, "hyp-4"),
        .candidate_kind = .regression_test,
        .artifact_scope = try allocator.dupe(u8, "src/main.zig"),
        .target_claim_surface = try allocator.dupe(u8, "main()"),
        .proposed_check = try allocator.dupe(u8, "test main"),
        .provenance = try allocator.dupe(u8, "test"),
        .trace = try allocator.dupe(u8, "proposed"),
        .non_authorizing = false,
    };
    defer candidate.deinit();

    try verifier_adapter.materializeVerifierCandidate(allocator, &candidate, .{
        .require_acceptance = false,
    });
    try std.testing.expectEqual(verifier_adapter.CandidateStatus.blocked, candidate.status);
    try std.testing.expectEqual(verifier_adapter.CandidateBlockedReason.unsafe_materialization, candidate.blocked_reason.?);
}
