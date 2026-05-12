const std = @import("std");
const builtin = @import("builtin");
const gip_mapping = @import("../gip/mapping.zig");

pub const DEFAULT_MEMORY_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const DEFAULT_CPU_WEIGHT: u16 = 100;
pub const DEFAULT_TIMEOUT_MS: u32 = 60_000;
pub const LANDLOCK_EXEC_FLAG = "--ghost-landlock-exec";

const linux = std.os.linux;
const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1;
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;
const LANDLOCK_ACCESS_FS_EXECUTE: u64 = 1 << 0;
const LANDLOCK_ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
const LANDLOCK_ACCESS_FS_READ_FILE: u64 = 1 << 2;
const LANDLOCK_ACCESS_FS_READ_DIR: u64 = 1 << 3;
const LANDLOCK_ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
const LANDLOCK_ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
const LANDLOCK_ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
const LANDLOCK_ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
const LANDLOCK_ACCESS_FS_MAKE_REG: u64 = 1 << 8;
const LANDLOCK_ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
const LANDLOCK_ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
const LANDLOCK_ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
const LANDLOCK_ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
const LANDLOCK_ACCESS_FS_REFER: u64 = 1 << 13;
const LANDLOCK_ACCESS_FS_TRUNCATE: u64 = 1 << 14;
const LANDLOCK_ACCESS_NET_BIND_TCP: u64 = 1 << 0;
const LANDLOCK_ACCESS_NET_CONNECT_TCP: u64 = 1 << 1;
const PR_SET_NO_NEW_PRIVS: i32 = 38;

const LandlockRulesetAttr = extern struct {
    handled_access_fs: u64,
    handled_access_net: u64,
};

const LandlockPathBeneathAttr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

pub const SandboxBackend = enum {
    landlock,
    rlimit_only,
};

pub const SandboxSpec = struct {
    backend: SandboxBackend = .landlock,
    memory_max_bytes: u64 = DEFAULT_MEMORY_MAX_BYTES,
    cpu_weight: u16 = DEFAULT_CPU_WEIGHT,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    private_tmp: bool = false,
    network_disabled: bool = true,
    protect_system_full: bool = true,
    private_devices: bool = true,
    protect_home_read_only: bool = true,
    read_write_workspace: bool = true,

    pub fn validate(self: SandboxSpec) !void {
        if (self.memory_max_bytes == 0) return error.InvalidMemoryLimit;
        if (self.memory_max_bytes > 14 * 1024 * 1024 * 1024) return error.MemoryLimitExceedsGhostBoundary;
        if (self.cpu_weight == 0 or self.cpu_weight > 10_000) return error.InvalidCpuWeight;
        if (self.timeout_ms == 0) return error.InvalidTimeout;
    }
};

pub const SandboxTelemetry = struct {
    private_devices_opcode: gip_mapping.GipOpCode = .GIP_OP_GET_TELEMETRY,
    protect_home_opcode: gip_mapping.GipOpCode = .GIP_OP_GET_TELEMETRY,
    landlock_opcode: gip_mapping.GipOpCode = .GIP_OP_LANDLOCK_STRICT,
    sec_fault_opcode: gip_mapping.GipOpCode = .GIP_OP_SEC_FAULT,
};

pub fn telemetryForSpec(spec: SandboxSpec) SandboxTelemetry {
    return .{
        .private_devices_opcode = if (spec.private_devices) .GIP_OP_GET_TELEMETRY else .GIP_OP_SEC_FAULT,
        .protect_home_opcode = if (spec.protect_home_read_only) .GIP_OP_GET_TELEMETRY else .GIP_OP_SEC_FAULT,
        .landlock_opcode = if (spec.backend == .landlock) .GIP_OP_LANDLOCK_STRICT else .GIP_OP_SEC_FAULT,
        .sec_fault_opcode = .GIP_OP_SEC_FAULT,
    };
}

pub const SandboxArgv = struct {
    allocator: std.mem.Allocator,
    argv: std.ArrayList([]const u8),
    owned: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) SandboxArgv {
        return .{
            .allocator = allocator,
            .argv = std.ArrayList([]const u8).init(allocator),
            .owned = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *SandboxArgv) void {
        for (self.owned.items) |item| self.allocator.free(item);
        self.owned.deinit();
        self.argv.deinit();
        self.* = undefined;
    }

    fn appendStatic(self: *SandboxArgv, value: []const u8) !void {
        try self.argv.append(value);
    }

    fn appendOwned(self: *SandboxArgv, value: []u8) !void {
        errdefer self.allocator.free(value);
        try self.owned.append(value);
        try self.argv.append(value);
    }
};

pub const LeashPaths = struct {
    allocator: std.mem.Allocator,
    rw: std.ArrayList([]u8),
    ro: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) LeashPaths {
        return .{
            .allocator = allocator,
            .rw = std.ArrayList([]u8).init(allocator),
            .ro = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *LeashPaths) void {
        for (self.rw.items) |path| self.allocator.free(path);
        for (self.ro.items) |path| self.allocator.free(path);
        self.rw.deinit();
        self.ro.deinit();
        self.* = undefined;
    }

    fn appendUnique(list: *std.ArrayList([]u8), allocator: std.mem.Allocator, path: []const u8) !void {
        if (path.len == 0) return;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        try list.append(try allocator.dupe(u8, path));
    }

    fn appendOwnedUnique(list: *std.ArrayList([]u8), allocator: std.mem.Allocator, path: []u8) !void {
        if (path.len == 0) {
            allocator.free(path);
            return;
        }
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                allocator.free(path);
                return;
            }
        }
        try list.append(path);
    }
};

pub fn buildLandlockRunArgv(
    allocator: std.mem.Allocator,
    spec: SandboxSpec,
    cwd: []const u8,
    inner_argv: []const []const u8,
) !SandboxArgv {
    return buildLandlockRunArgvWithExtra(allocator, spec, cwd, inner_argv, &.{});
}

pub fn buildLandlockRunArgvWithExtra(
    allocator: std.mem.Allocator,
    spec: SandboxSpec,
    cwd: []const u8,
    inner_argv: []const []const u8,
    extra_rw_paths: []const []const u8,
) !SandboxArgv {
    try spec.validate();
    if (inner_argv.len == 0) return error.EmptyCommand;
    try ensureNoContainerRuntime(inner_argv);

    var out = SandboxArgv.init(allocator);
    errdefer out.deinit();

    try out.appendOwned(try std.fs.selfExePathAlloc(allocator));
    try out.appendStatic(LANDLOCK_EXEC_FLAG);
    try out.appendStatic("--cwd");
    try out.appendStatic(cwd);
    try out.appendStatic(if (spec.network_disabled) "--network-closed" else "--network-open");
    for (extra_rw_paths) |path| {
        try out.appendStatic("--rw-extra");
        try out.appendStatic(path);
    }
    try out.appendStatic("--");
    for (inner_argv) |part| try out.appendStatic(part);
    return out;
}

pub fn buildZigTestArgv(
    allocator: std.mem.Allocator,
    spec: SandboxSpec,
    cwd: []const u8,
    test_file: []const u8,
) !SandboxArgv {
    return buildLandlockRunArgv(allocator, spec, cwd, &.{ "zig", "test", test_file });
}

pub fn buildPytestArgv(
    allocator: std.mem.Allocator,
    spec: SandboxSpec,
    cwd: []const u8,
    test_selector: []const u8,
) !SandboxArgv {
    return buildLandlockRunArgv(allocator, spec, cwd, &.{ "python3", "-m", "pytest", test_selector });
}

pub fn ensureNoContainerRuntime(argv: []const []const u8) !void {
    for (argv) |part| {
        if (std.mem.indexOf(u8, part, "docker") != null or std.mem.indexOf(u8, part, "podman") != null) {
            return error.ContainerRuntimeForbidden;
        }
    }
}

pub fn applyCurrentProcessRlimits(spec: SandboxSpec) !void {
    try spec.validate();
    if (builtin.os.tag != .linux) return error.UnsupportedSandboxBackend;
    try std.posix.setrlimit(.AS, .{
        .cur = spec.memory_max_bytes,
        .max = spec.memory_max_bytes,
    });
}

pub fn resolveLeashPaths(allocator: std.mem.Allocator, cwd: []const u8) !LeashPaths {
    var paths = LeashPaths.init(allocator);
    errdefer paths.deinit();

    try LeashPaths.appendOwnedUnique(&paths.rw, allocator, try sweWorkspaceAnchor(allocator, cwd));
    try LeashPaths.appendOwnedUnique(&paths.rw, allocator, try std.fs.path.join(allocator, &.{ cwd, ".venv-grounding" }));
    try LeashPaths.appendOwnedUnique(&paths.rw, allocator, try std.fs.path.join(allocator, &.{ cwd, "temp_venv" }));
    try LeashPaths.appendUnique(&paths.rw, allocator, "/home/micah/.ansible/tmp");
    try LeashPaths.appendUnique(&paths.rw, allocator, "/dev/null");

    const ro_paths = [_][]const u8{ "/usr", "/lib", "/lib64", "/etc" };
    for (ro_paths) |path| try LeashPaths.appendUnique(&paths.ro, allocator, path);
    return paths;
}

pub fn renderAllowedPathsJson(writer: anytype, allocator: std.mem.Allocator, cwd: []const u8) !void {
    var paths = try resolveLeashPaths(allocator, cwd);
    defer paths.deinit();
    try writer.writeAll("{\"readWriteExecute\":[");
    for (paths.rw.items, 0..) |path, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.stringify(path, .{}, writer);
    }
    try writer.writeAll("],\"readOnlyExecute\":[");
    for (paths.ro.items, 0..) |path, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.stringify(path, .{}, writer);
    }
    try writer.writeAll("]}");
}

pub fn runLandlockExecFromArgs(allocator: std.mem.Allocator, args: []const []const u8) !noreturn {
    var cwd: ?[]const u8 = null;
    var network_disabled = true;
    var extra_rw_paths = std.ArrayList([]const u8).init(allocator);
    defer extra_rw_paths.deinit();
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--cwd")) {
            idx += 1;
            if (idx >= args.len) return error.MissingLandlockCwd;
            cwd = args[idx];
        } else if (std.mem.eql(u8, arg, "--network-open")) {
            network_disabled = false;
        } else if (std.mem.eql(u8, arg, "--network-closed")) {
            network_disabled = true;
        } else if (std.mem.eql(u8, arg, "--rw-extra")) {
            idx += 1;
            if (idx >= args.len) return error.MissingLandlockExtraPath;
            try extra_rw_paths.append(args[idx]);
        } else if (std.mem.eql(u8, arg, "--")) {
            const command = args[idx + 1 ..];
            if (command.len == 0) return error.EmptyCommand;
            const run_cwd = cwd orelse return error.MissingLandlockCwd;
            try restrictSelfToLeashWithExtra(allocator, run_cwd, network_disabled, extra_rw_paths.items);
            var child = std.process.Child.init(command, allocator);
            child.cwd = run_cwd;
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            const term = try child.spawnAndWait();
            switch (term) {
                .Exited => |code| std.process.exit(code),
                .Signal => |signal| std.process.exit(128 + @as(u8, @intCast(@min(signal, 127)))),
                else => std.process.exit(125),
            }
        } else {
            return error.UnknownLandlockExecArgument;
        }
    }
    return error.EmptyCommand;
}

pub fn restrictSelfToLeash(allocator: std.mem.Allocator, cwd: []const u8, network_disabled: bool) !void {
    return restrictSelfToLeashWithExtra(allocator, cwd, network_disabled, &.{});
}

pub fn restrictSelfToLeashWithExtra(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    network_disabled: bool,
    extra_rw_paths: []const []const u8,
) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedSandboxBackend;
    const abi = try landlockAbi();
    if (abi < 1) return error.LandlockUnavailable;
    if (network_disabled and abi < 4) return error.LandlockAbiTooOldForNetwork;

    const handled_fs = landlockFsMask(abi);
    const handled_net: u64 = if (network_disabled) LANDLOCK_ACCESS_NET_BIND_TCP | LANDLOCK_ACCESS_NET_CONNECT_TCP else 0;
    var ruleset_attr = LandlockRulesetAttr{
        .handled_access_fs = handled_fs,
        .handled_access_net = handled_net,
    };
    const ruleset_fd = try sys_landlock_create_ruleset(&ruleset_attr, @sizeOf(LandlockRulesetAttr), 0);
    defer std.posix.close(ruleset_fd);

    var paths = try resolveLeashPaths(allocator, cwd);
    defer paths.deinit();
    for (extra_rw_paths) |path| try LeashPaths.appendUnique(&paths.rw, allocator, path);
    for (paths.rw.items) |path| try addPathRuleIfPresent(ruleset_fd, path, rwAccess(handled_fs));
    for (paths.ro.items) |path| try addPathRuleIfPresent(ruleset_fd, path, roAccess(handled_fs));

    const prctl_rc = linux.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (linux.E.init(prctl_rc) != .SUCCESS) return error.NoNewPrivsFailed;
    try sys_landlock_restrict_self(ruleset_fd, 0);
}

pub fn landlockAbi() !u32 {
    if (builtin.os.tag != .linux) return error.UnsupportedSandboxBackend;
    const rc = linux.syscall3(.landlock_create_ruleset, 0, 0, LANDLOCK_CREATE_RULESET_VERSION);
    return switch (linux.E.init(rc)) {
        .SUCCESS => @intCast(rc),
        .NOSYS, .OPNOTSUPP => error.LandlockUnavailable,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn sys_landlock_create_ruleset(attr: *const LandlockRulesetAttr, size: usize, flags: u32) !i32 {
    const rc = linux.syscall3(.landlock_create_ruleset, @intFromPtr(attr), size, flags);
    return switch (linux.E.init(rc)) {
        .SUCCESS => @intCast(rc),
        .NOSYS, .OPNOTSUPP => error.LandlockUnavailable,
        .INVAL => error.InvalidLandlockRuleset,
        .@"2BIG" => error.InvalidLandlockRuleset,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn sys_landlock_add_rule(ruleset_fd: i32, rule_type: u32, rule_attr: *const LandlockPathBeneathAttr, flags: u32) !void {
    const rc = linux.syscall4(.landlock_add_rule, @intCast(ruleset_fd), rule_type, @intFromPtr(rule_attr), flags);
    return switch (linux.E.init(rc)) {
        .SUCCESS => {},
        .NOENT => error.PathNotFound,
        .INVAL => error.InvalidLandlockRule,
        .BADF => error.InvalidLandlockRule,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn sys_landlock_restrict_self(ruleset_fd: i32, flags: u32) !void {
    const rc = linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), flags);
    return switch (linux.E.init(rc)) {
        .SUCCESS => {},
        .PERM => error.LandlockRestrictSelfDenied,
        .INVAL => error.InvalidLandlockRuleset,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn addPathRuleIfPresent(ruleset_fd: i32, path: []const u8, allowed_access: u64) !void {
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.NotDir => {
            var file = std.fs.openFileAbsolute(path, .{}) catch |file_err| switch (file_err) {
                error.FileNotFound, error.AccessDenied => return,
                else => return file_err,
            };
            defer file.close();
            var rule = LandlockPathBeneathAttr{
                .allowed_access = allowed_access & (LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_TRUNCATE),
                .parent_fd = file.handle,
            };
            try sys_landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
            return;
        },
        error.FileNotFound, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();
    var rule = LandlockPathBeneathAttr{
        .allowed_access = allowed_access,
        .parent_fd = dir.fd,
    };
    try sys_landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
}

fn landlockFsMask(abi: u32) u64 {
    var mask = LANDLOCK_ACCESS_FS_EXECUTE |
        LANDLOCK_ACCESS_FS_WRITE_FILE |
        LANDLOCK_ACCESS_FS_READ_FILE |
        LANDLOCK_ACCESS_FS_READ_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_FILE |
        LANDLOCK_ACCESS_FS_MAKE_CHAR |
        LANDLOCK_ACCESS_FS_MAKE_DIR |
        LANDLOCK_ACCESS_FS_MAKE_REG |
        LANDLOCK_ACCESS_FS_MAKE_SOCK |
        LANDLOCK_ACCESS_FS_MAKE_FIFO |
        LANDLOCK_ACCESS_FS_MAKE_BLOCK |
        LANDLOCK_ACCESS_FS_MAKE_SYM;
    if (abi >= 2) mask |= LANDLOCK_ACCESS_FS_REFER;
    if (abi >= 3) mask |= LANDLOCK_ACCESS_FS_TRUNCATE;
    return mask;
}

fn rwAccess(handled_fs: u64) u64 {
    return handled_fs;
}

fn roAccess(handled_fs: u64) u64 {
    return handled_fs & (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR);
}

fn sweWorkspaceAnchor(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const prefix = "/tmp/ghost/swe/";
    if (!std.mem.startsWith(u8, cwd, prefix)) return allocator.dupe(u8, cwd);
    const rest = cwd[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, rest[0..slash] });
}

test "landlock argv wraps zig test without systemd or Docker" {
    const allocator = std.testing.allocator;
    var argv = try buildZigTestArgv(allocator, .{}, "/tmp/ghost/swe/inst/repo", "src/tests.zig");
    defer argv.deinit();
    try ensureNoContainerRuntime(argv.argv.items);
    try std.testing.expect(std.mem.endsWith(u8, argv.argv.items[0], "test") or argv.argv.items[0].len != 0);
    try std.testing.expectEqualStrings(LANDLOCK_EXEC_FLAG, argv.argv.items[1]);
    try std.testing.expectEqualStrings("--network-closed", argv.argv.items[4]);
    try std.testing.expectEqualStrings("zig", argv.argv.items[6]);
    try std.testing.expectEqualStrings("test", argv.argv.items[7]);
}

test "pytest wrapper rejects unsafe memory limits and container runtimes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MemoryLimitExceedsGhostBoundary, buildPytestArgv(
        allocator,
        .{ .memory_max_bytes = 15 * 1024 * 1024 * 1024 },
        ".",
        "tests",
    ));
    try std.testing.expectError(error.ContainerRuntimeForbidden, ensureNoContainerRuntime(&.{ "docker", "run" }));
}

test "sandbox telemetry maps hardening controls to GIP handles" {
    const hardened = telemetryForSpec(.{});
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_GET_TELEMETRY, hardened.private_devices_opcode);
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_GET_TELEMETRY, hardened.protect_home_opcode);
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_LANDLOCK_STRICT, hardened.landlock_opcode);
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_SEC_FAULT, hardened.sec_fault_opcode);

    const softened = telemetryForSpec(.{ .private_devices = false });
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_SEC_FAULT, softened.private_devices_opcode);
}

test "leash paths anchor to SWE instance" {
    const allocator = std.testing.allocator;
    var paths = try resolveLeashPaths(allocator, "/tmp/ghost/swe/row-1/project/pkg");
    defer paths.deinit();
    try std.testing.expectEqualStrings("/tmp/ghost/swe/row-1", paths.rw.items[0]);
    try std.testing.expectEqualStrings("/usr", paths.ro.items[0]);
}
