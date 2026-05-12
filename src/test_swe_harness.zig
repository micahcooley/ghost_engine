const std = @import("std");

const bootstrap = @import("ingest/bootstrap.zig");
const sandbox = @import("oracle/sandbox.zig");
const swe_harness = @import("ingest/swe_harness.zig");

test {
    std.testing.refAllDecls(bootstrap);
    std.testing.refAllDecls(sandbox);
    std.testing.refAllDecls(swe_harness);
}
