const std = @import("std");

test {
    std.testing.refAllDecls(@import("codec/gutf.zig"));
    std.testing.refAllDecls(@import("codec/distiller.zig"));
    std.testing.refAllDecls(@import("gip/mapping.zig"));
    std.testing.refAllDecls(@import("ingest/bench_loader.zig"));
    std.testing.refAllDecls(@import("ingest/bootstrap.zig"));
    std.testing.refAllDecls(@import("ingest/swe_harness.zig"));
    std.testing.refAllDecls(@import("oracle/sandbox.zig"));
    std.testing.refAllDecls(@import("net/search_client.zig"));
    std.testing.refAllDecls(@import("ghost/world_model.zig"));
}
