const std = @import("std");

/// This is a fixture for recipe consistency in artifact_autopsy, providing testing of invariants without implementing file-backed execution or touching GIP dispatch.
pub const RecipeConsistencyFixture = struct {
    is_fixture_backed: bool = true,
    is_file_backed: bool = false,
    read_only: bool = true,
    non_authorizing: bool = true,
    proof_granted: bool = false,
    support_granted: bool = false,
    candidate_inconsistency: bool = false,
    unknowns: bool = false,

    pub fn init(has_inconsistency: bool, has_unknowns: bool) RecipeConsistencyFixture {
        return .{
            .candidate_inconsistency = has_inconsistency,
            .unknowns = has_unknowns,
        };
    }
};

test "recipe_consistency fixture is fixture-backed and not file-backed" {
    const fixture = RecipeConsistencyFixture.init(false, false);
    try std.testing.expect(fixture.is_fixture_backed);
    try std.testing.expect(!fixture.is_file_backed);
}

test "recipe_consistency fixture is read-only and non-authorizing" {
    const fixture = RecipeConsistencyFixture.init(false, false);
    try std.testing.expect(fixture.read_only);
    try std.testing.expect(fixture.non_authorizing);
}

test "recipe_consistency fixture grants no proof or support" {
    const fixture = RecipeConsistencyFixture.init(false, false);
    try std.testing.expect(!fixture.proof_granted);
    try std.testing.expect(!fixture.support_granted);
}

test "recipe_consistency fixture has candidate inconsistency/unknowns if current fixture includes them" {
    const fixture_with_issues = RecipeConsistencyFixture.init(true, true);
    try std.testing.expect(fixture_with_issues.candidate_inconsistency);
    try std.testing.expect(fixture_with_issues.unknowns);

    const fixture_clean = RecipeConsistencyFixture.init(false, false);
    try std.testing.expect(!fixture_clean.candidate_inconsistency);
    try std.testing.expect(!fixture_clean.unknowns);
}
