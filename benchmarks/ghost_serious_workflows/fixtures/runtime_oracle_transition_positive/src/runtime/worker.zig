const service = @import("../api/service.zig");

pub fn sync() void {
    service.compute();
}
