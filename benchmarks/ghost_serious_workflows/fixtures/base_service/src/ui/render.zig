const service = @import("../api/service.zig");

pub fn draw() void {
    service.compute();
}
