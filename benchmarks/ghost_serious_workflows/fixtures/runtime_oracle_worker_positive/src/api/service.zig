const types = @import("../model/types.zig");

pub fn compute() void {}

pub fn run() void {
    compute();
}

pub fn hydrate(widget: types.Widget) void {
    _ = widget;
    compute();
}
