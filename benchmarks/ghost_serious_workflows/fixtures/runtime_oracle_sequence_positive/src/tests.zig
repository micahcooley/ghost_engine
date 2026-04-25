const std = @import("std");
const service = @import("api/service.zig");
const stateful = @import("app/stateful.zig");

test "fixture compute paths stay valid" {
    service.run();
    try std.testing.expectEqual(@as(u32, 1), stateful.repaint());
}
