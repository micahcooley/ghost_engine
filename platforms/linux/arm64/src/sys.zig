const std = @import("std");
const builtin = @import("builtin");

pub const os_layer = switch (builtin.os.tag) {
    .windows => @import("sys/windows.zig"),
    .linux => @import("sys/linux.zig"),
    else => @import("sys/windows.zig"), // Fallback
};

pub const FileHandle = os_layer.FileHandle;
pub const INVALID_HANDLE = os_layer.INVALID_HANDLE;
pub const MappedFile = os_layer.MappedFile;
pub const SECTOR_SIZE = os_layer.SECTOR_SIZE;

pub const printOut = os_layer.printOut;
pub const readStdin = os_layer.readStdin;
pub const openForRead = os_layer.openForRead;
pub const openForWrite = os_layer.openForWrite;
pub const closeFile = os_layer.closeFile;
pub const getFileSize = os_layer.getFileSize;
pub const readAll = os_layer.readAll;
pub const writeAll = os_layer.writeAll;
pub const createMappedFile = os_layer.createMappedFile;
pub const allocSectorAligned = os_layer.allocSectorAligned;
pub const freeSectorAligned = os_layer.freeSectorAligned;
pub const getMilliTick = os_layer.getMilliTick;
pub const sleep = os_layer.sleep;
pub const exit = os_layer.exit;
pub const getArgs = os_layer.getArgs;
pub const isTrainerActive = os_layer.isTrainerActive;
pub const findPluginFiles = os_layer.findPluginFiles;

// Common utilities
pub fn printInt(val: i64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
    printOut(s);
}
