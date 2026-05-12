const std = @import("std");

pub const SourceType = enum {
    AST_ANCHOR,
    WASM_ADAPTER,
    Z3_PROOF,
    HEURISTIC,
};

pub const ConfidenceTier = enum {
    PROVEN,
    HEURISTIC,
    UNVERIFIED,
};

pub const RetrievedFact = struct {
    data: []const u8,
    source: SourceType,
    confidence: ConfidenceTier,
};

pub const SynthesisError = error{
    UnverifiedDataBlocked,
};

pub const ProofSession = struct {
    allocator: std.mem.Allocator,
    active_target: []const u8,
    constraints_verified: std.ArrayList([]const u8),
    constraints_pending: std.ArrayList([]const u8),
    cutoff_point: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, active_target: []const u8) ProofSession {
        return .{
            .allocator = allocator,
            .active_target = active_target,
            .constraints_verified = std.ArrayList([]const u8).init(allocator),
            .constraints_pending = std.ArrayList([]const u8).init(allocator),
            .cutoff_point = null,
        };
    }

    pub fn deinit(self: *ProofSession) void {
        self.constraints_verified.deinit();
        self.constraints_pending.deinit();
        self.* = undefined;
    }

    pub fn synthesize(self: *const ProofSession, facts: []const RetrievedFact) ![]u8 {
        for (facts) |fact| {
            if (fact.confidence == .UNVERIFIED) return error.UnverifiedDataBlocked;
        }

        if (self.cutoff_point) |cutoff| {
            return std.fmt.allocPrint(
                self.allocator,
                "[SESSION_STATE: {s} - resume pending constraints]",
                .{cutoff},
            );
        }

        const source = if (facts.len > 0) facts[0].source else SourceType.HEURISTIC;
        return std.fmt.allocPrint(
            self.allocator,
            "[VERIFIED: Constraints satisfied. Source: {s}]",
            .{@tagName(source)},
        );
    }
};

test "synthesize formats proven fact as verified system response" {
    var session = ProofSession.init(std.testing.allocator, "src/main.zig");
    defer session.deinit();

    const facts = [_]RetrievedFact{
        .{
            .data = "lock order graph is acyclic",
            .source = .Z3_PROOF,
            .confidence = .PROVEN,
        },
    };

    const output = try session.synthesize(&facts);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("[VERIFIED: Constraints satisfied. Source: Z3_PROOF]", output);
}

test "synthesize blocks unverified raw text" {
    var session = ProofSession.init(std.testing.allocator, "src/main.zig");
    defer session.deinit();

    const facts = [_]RetrievedFact{
        .{
            .data = "raw adapter text without proof",
            .source = .HEURISTIC,
            .confidence = .UNVERIFIED,
        },
    };

    try std.testing.expectError(error.UnverifiedDataBlocked, session.synthesize(&facts));
}

test "synthesize preserves timeout provenance as session state" {
    var session = ProofSession.init(std.testing.allocator, "src/main.zig");
    defer session.deinit();
    session.cutoff_point = "Z3 timeout at 500ms";

    const facts = [_]RetrievedFact{
        .{
            .data = "bounded proof context",
            .source = .Z3_PROOF,
            .confidence = .PROVEN,
        },
    };

    const output = try session.synthesize(&facts);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("[SESSION_STATE: Z3 timeout at 500ms - resume pending constraints]", output);
}
