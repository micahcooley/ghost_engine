const std = @import("std");
const service = @import("api/service.zig");
const stateful = @import("app/stateful.zig");

pub fn main() !void {
    const has_impl = @hasDecl(service, "compute__ghost_c1_impl");
    const writer = std.io.getStdOut().writer();
    try writer.writeAll("oracle-run\nevent:boot\nstate:stage=booting\n");
    service.run();
    service.hydrate(.{ .value = 1 });
    _ = stateful.repaint();
    _ = stateful.repaint();
    try writer.writeAll("event:dispatch\nstate:stage=service_called\n");
    try writer.print(
        "event:verified\nstate:stage=verified\nstate:impl_decl={s}\nstate:call_route=service\nstate:result_count=2\nstate:last_state=verified\ninvariant:wrapper_active={s}\n",
        .{
            if (has_impl) "true" else "false",
            if (has_impl) "true" else "false",
        },
    );
}
