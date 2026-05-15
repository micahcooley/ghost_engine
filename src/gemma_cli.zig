const gemma_cli = @import("gemma/weights_inventory_cli.zig");

pub fn main() !void {
    try gemma_cli.main();
}
