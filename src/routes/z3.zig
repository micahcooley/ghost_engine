const std = @import("std");
const z3_bridge = @import("z3_bridge");
const schema = @import("../gip_schema.zig");

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

pub fn renderConversationResult(allocator: std.mem.Allocator, msg: []const u8, proof: z3_bridge.ArithmeticProof) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"conversationTurn\":{\"session_id\":\"z3-arithmetic\",\"response\":{\"summary\":");
    try w.writeByte('"');
    try w.print("{d}", .{proof.result});
    try w.writeByte('"');
    try w.writeAll(",\"state\":\"verified\"},\"intent\":{\"status\":\"grounded\",\"mode\":\"logical_reasoning\"},\"logicalReasoning\":{\"route\":\"z3\",\"z3Status\":\"active\",\"status\":\"verified\",\"expression\":");
    try std.json.stringify(msg, .{}, w);
    try w.writeAll(",\"lhs\":");
    try w.print("{d}", .{proof.lhs});
    try w.writeAll(",\"operator\":");
    try std.json.stringify(&[_]u8{proof.op}, .{}, w);
    try w.writeAll(",\"rhs\":");
    try w.print("{d}", .{proof.rhs});
    try w.writeAll(",\"result\":");
    try w.print("{d}", .{proof.result});
    try w.writeAll(",\"signal\":");
    try std.json.stringify(proof.signal.tag(), .{}, w);
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

pub fn dispatchConversation(allocator: std.mem.Allocator, msg: []const u8, formula: []const u8) !?struct {
    result_state: schema.ResultState,
    result_json: []const u8,
} {
    if (try z3_bridge.proveArithmeticExpression(formula, .{ .timeout_ms = 100 })) |proof| {
        return .{
            .result_state = verifiedState(),
            .result_json = try renderConversationResult(allocator, msg, proof),
        };
    }
    return null;
}
