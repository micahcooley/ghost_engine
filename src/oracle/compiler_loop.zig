const std = @import("std");
const builtin = @import("builtin");

pub const DEFAULT_RAM_LIMIT_BYTES: u64 = 12 * 1024 * 1024 * 1024;
pub const MIN_RAM_LIMIT_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_RAM_LIMIT_BYTES: u64 = 15 * 1024 * 1024 * 1024;

pub const EpistemicState = enum {
    Unverified,
    Verified,
};

pub const RuneRecord = struct {
    id: u64,
    state: EpistemicState = .Unverified,
};

pub const OracleResult = struct {
    term: std.process.Child.Term,
    promoted: bool,
};

pub const EpistemicManager = struct {
    pub fn promoteOnSuccessfulExit(self: *EpistemicManager, rune: *RuneRecord, term: std.process.Child.Term) bool {
        _ = self;
        if (term == .Exited and term.Exited == 0) {
            rune.state = .Verified;
            return true;
        }
        return false;
    }
};

pub const CompilerLoop = struct {
    allocator: std.mem.Allocator,
    ram_limit_bytes: u64 = DEFAULT_RAM_LIMIT_BYTES,

    pub fn init(allocator: std.mem.Allocator, ram_limit_bytes: u64) !CompilerLoop {
        return .{
            .allocator = allocator,
            .ram_limit_bytes = try clampRamLimit(ram_limit_bytes),
        };
    }

    pub fn runZigTest(self: CompilerLoop, cwd: []const u8, test_file: []const u8, rune: *RuneRecord) !OracleResult {
        const argv_storage = try self.makeZigTestArgv(test_file);
        defer self.freeArgv(argv_storage);

        var child = std.process.Child.init(argv_storage, self.allocator);
        child.cwd = cwd;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.request_resource_usage_statistics = true;

        try child.spawn();
        const term = try child.wait();

        var manager = EpistemicManager{};
        const promoted = manager.promoteOnSuccessfulExit(rune, term);
        return .{ .term = term, .promoted = promoted };
    }

    fn makeZigTestArgv(self: CompilerLoop, test_file: []const u8) ![]const []const u8 {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            const limit_kb = self.ram_limit_bytes / 1024;
            const script = try std.fmt.allocPrint(
                self.allocator,
                "ulimit -v {d}; exec zig test \"$1\"",
                .{limit_kb},
            );
            errdefer self.allocator.free(script);
            const argv = try self.allocator.alloc([]const u8, 4);
            argv[0] = "sh";
            argv[1] = "-c";
            argv[2] = script;
            argv[3] = test_file;
            return argv;
        }

        const argv = try self.allocator.alloc([]const u8, 3);
        argv[0] = "zig";
        argv[1] = "test";
        argv[2] = test_file;
        return argv;
    }

    fn freeArgv(self: CompilerLoop, argv: []const []const u8) void {
        if ((builtin.os.tag == .linux or builtin.os.tag == .macos) and argv.len >= 3) {
            self.allocator.free(argv[2]);
        }
        self.allocator.free(argv);
    }
};

pub fn clampRamLimit(bytes: u64) !u64 {
    if (bytes < MIN_RAM_LIMIT_BYTES) return error.RamLimitTooLow;
    if (bytes > MAX_RAM_LIMIT_BYTES) return error.RamLimitTooHigh;
    return bytes;
}

test "epistemic manager promotes only clean compiler exit" {
    var manager = EpistemicManager{};
    var rune = RuneRecord{ .id = 7 };
    try std.testing.expect(manager.promoteOnSuccessfulExit(&rune, .{ .Exited = 0 }));
    try std.testing.expectEqual(EpistemicState.Verified, rune.state);

    rune.state = .Unverified;
    try std.testing.expect(!manager.promoteOnSuccessfulExit(&rune, .{ .Exited = 1 }));
    try std.testing.expectEqual(EpistemicState.Unverified, rune.state);
}

test "ram limit enforces 16GB boundary" {
    try std.testing.expectError(error.RamLimitTooLow, clampRamLimit(128 * 1024 * 1024));
    try std.testing.expectError(error.RamLimitTooHigh, clampRamLimit(16 * 1024 * 1024 * 1024));
    try std.testing.expectEqual(DEFAULT_RAM_LIMIT_BYTES, try clampRamLimit(DEFAULT_RAM_LIMIT_BYTES));
}
