const state = @import("../runtime/state.zig");

pub fn repaint() u32 {
    state.tick();
    return state.counter;
}
