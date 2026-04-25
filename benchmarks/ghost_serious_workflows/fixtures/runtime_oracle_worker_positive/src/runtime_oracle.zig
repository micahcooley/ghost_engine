const std = @import("std");
const worker = @import("runtime/worker.zig");

pub fn main() !void {
    const has_impl = @hasDecl(worker, "sync__ghost_c1_impl");
    worker.sync();
    try std.io.getStdOut().writer().print(
        "oracle-run\nstate:impl_decl={s}\nstate:call_route=worker\ninvariant:wrapper_active={s}\n",
        .{
            if (has_impl) "true" else "false",
            if (has_impl) "true" else "false",
        },
    );
}
