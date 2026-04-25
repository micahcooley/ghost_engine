const std = @import("std");
const worker = @import("runtime/worker.zig");
const state = @import("runtime/state.zig");

pub fn main() !void {
    const has_impl = @hasDecl(worker, "sync__ghost_c1_impl");
    const writer = std.io.getStdOut().writer();
    try writer.writeAll("oracle-run\nevent:warmup\nstate:phase=idle\n");
    worker.sync();
    state.tick();
    try writer.writeAll("event:sync\nstate:phase=syncing\n");
    worker.sync();
    try writer.print(
        "event:settled\nstate:phase=settled\nstate:impl_decl={s}\nstate:call_route=worker\nstate:sync_count=2\nstate:last_phase=settled\ninvariant:wrapper_active={s}\n",
        .{
            if (has_impl) "true" else "false",
            if (has_impl) "true" else "false",
        },
    );
}
