const std = @import("std");
const core = @import("../gip_core.zig");
const schema = @import("../gip_schema.zig");

pub const READY_RESPONSE = "System Ready. Awaiting Command.";

pub fn verifiedState() schema.ResultState {
    var state = schema.draftResultState();
    state.state = .verified;
    state.permission = .supported;
    state.is_draft = false;
    state.verification_state = .verified;
    state.support_minimum_met = true;
    state.stop_reason = .none;
    state.non_authorization_notice = null;
    return state;
}

pub fn renderConversationResult(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"conversationTurn\":{\"session_id\":\"scalar-ready\",\"response\":{\"summary\":");
    try std.json.stringify(response, .{}, w);
    try w.writeAll(",\"state\":\"verified\"},\"intent\":{\"status\":\"grounded\",\"mode\":\"scalar_ready\"}}}");
    return out.toOwnedSlice();
}

pub fn dispatchConversation(allocator: std.mem.Allocator, response: []const u8) !struct {
    result_state: schema.ResultState,
    result_json: []const u8,
} {
    return .{
        .result_state = verifiedState(),
        .result_json = try renderConversationResult(allocator, response),
    };
}

comptime {
    _ = core;
}
