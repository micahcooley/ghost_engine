const std = @import("std");
const service = @import("api/service.zig");

pub fn main() !void {
    const has_impl = @hasDecl(service, "compute__ghost_c1_impl");
    service.run();
    try std.io.getStdOut().writer().print(
        "oracle-run\nstate:impl_decl={s}\nstate:call_route=service\ninvariant:wrapper_active={s}\n",
        .{
            if (has_impl) "true" else "false",
            if (has_impl) "true" else "false",
        },
    );
}
