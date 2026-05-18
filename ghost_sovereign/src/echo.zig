const std = @import("std");

pub const EchoManager = struct {
    storage_path: []const u8 = "state/ghost_hyper_echo.bin",
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EchoManager {
        return .{ .allocator = allocator };
    }

    pub fn persist(self: *const EchoManager, field: anytype) !void {
        var file = try std.fs.cwd().createFile(self.storage_path, .{});
        defer file.close();
        var writer = file.writer();
        
        try writer.writeInt(u64, field.kernel, .little);
        try writer.writeInt(u64, @as(u64, @intCast(field.points.count())), .little);
        
        var it = field.points.iterator();
        while (it.next()) |entry| {
            try writer.writeInt(u64, entry.key_ptr.*, .little);
            try writer.writeInt(i128, entry.value_ptr.*, .little);
        }
    }
};
