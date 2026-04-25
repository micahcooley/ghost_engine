const render = @import("../ui/render.zig");
const worker = @import("../runtime/worker.zig");

pub fn boot() void {
    render.draw();
    worker.sync();
}
