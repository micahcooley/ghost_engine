const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

pub const DEFAULT_TIMEOUT_MS: u32 = 4_000;
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 64 * 1024;
pub const MAX_TIMEOUT_MS: u32 = 15_000;
pub const MAX_ARG_COUNT: usize = 16;
pub const MAX_ARG_BYTES: usize = 256;
pub const MAX_EVIDENCE_BYTES: usize = 1024;

pub const Kind = enum {
    zig_build,
    zig_run,
    shell,
};

pub const Phase = enum {
    build,
    @"test",
    run,
    invariant,
};

pub const FailureSignal = enum {
    none,
    spawn_failed,
    disallowed_command,
    workspace_violation,
    nonzero_exit,
    timed_out,
    signaled,
    output_limit,
    invariant_failed,
};

pub const Expectation = union(enum) {
    success,
    exit_code: i32,
    stdout_contains: []const u8,
    stderr_contains: []const u8,
    stdout_not_contains: []const u8,
    stderr_not_contains: []const u8,
};

pub const Step = struct {
    label: []const u8,
    kind: Kind,
    phase: Phase,
    argv: []const []const u8,
    expectations: []const Expectation = &.{},
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
};

pub const Options = struct {
    workspace_root: []const u8,
    cwd: ?[]const u8 = null,
    path_override: ?[]const u8 = null,
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,
};

pub const Result = struct {
    label: []u8,
    kind: Kind,
    phase: Phase,
    command: []u8,
    exit_code: ?i32 = null,
    duration_ms: u64 = 0,
    stdout: []u8,
    stderr: []u8,
    failure_signal: FailureSignal = .none,
    invariant_summary: ?[]u8 = null,
    timed_out: bool = false,
    output_limited: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.command);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        if (self.invariant_summary) |summary| allocator.free(summary);
        self.* = undefined;
    }

    pub fn succeeded(self: Result) bool {
        return self.failure_signal == .none and self.exit_code != null and self.exit_code.? == 0;
    }
};

const RunCapture = struct {
    stdout: []u8,
    stderr: []u8,
    term: ?std.process.Child.Term = null,
    timed_out: bool = false,
    output_limited: bool = false,

    fn deinit(self: *RunCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const Validation = struct {
    cwd: []u8,
    argv: [][]u8,

    fn deinit(self: *Validation, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        self.* = undefined;
    }
};

// The verifier is intentionally Linux-first and narrow: it exists to replay
// bounded build/test/runtime workflows, not to expose a general shell.
const ALLOWED_SHELL_TOOLS = [_][]const u8{
    "cat",
    "echo",
    "false",
    "find",
    "grep",
    "head",
    "ls",
    "pwd",
    "rg",
    "sed",
    "stat",
    "tail",
    "test",
    "true",
    "wc",
};

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn phaseName(phase: Phase) []const u8 {
    return @tagName(phase);
}

pub fn failureSignalName(signal: FailureSignal) []const u8 {
    return @tagName(signal);
}

pub fn run(allocator: std.mem.Allocator, options: Options, step: Step) !Result {
    const started = sys.getMilliTick();

    var validated = validateStep(allocator, options, step) catch |err| {
        return blockedResult(allocator, step, started, switch (err) {
            error.DisallowedCommand => .disallowed_command,
            error.WorkspaceEscape => .workspace_violation,
            else => .spawn_failed,
        }, @errorName(err));
    };
    defer validated.deinit(allocator);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (options.path_override) |path_override| {
        const current = env_map.get("PATH") orelse "";
        const combined = if (current.len == 0)
            try allocator.dupe(u8, path_override)
        else
            try std.fmt.allocPrint(allocator, "{s}:{s}", .{ path_override, current });
        defer allocator.free(combined);
        try env_map.put("PATH", combined);
    }

    var capture = runCaptureBounded(
        allocator,
        validated.cwd,
        validated.argv,
        &env_map,
        options.max_output_bytes,
        clampTimeout(step.timeout_ms),
    ) catch |err| {
        return blockedResult(allocator, step, started, .spawn_failed, @errorName(err));
    };
    defer capture.deinit(allocator);

    var result = Result{
        .label = try allocator.dupe(u8, step.label),
        .kind = step.kind,
        .phase = step.phase,
        .command = try joinTokensOwned(allocator, validated.argv),
        .stdout = try allocator.dupe(u8, capture.stdout),
        .stderr = try allocator.dupe(u8, capture.stderr),
        .duration_ms = sys.getMilliTick() - started,
        .timed_out = capture.timed_out,
        .output_limited = capture.output_limited,
    };
    errdefer result.deinit(allocator);

    if (capture.term) |term| {
        result.exit_code = termExitCode(term);
        result.failure_signal = signalFromTerm(term, capture.timed_out, capture.output_limited);
    } else {
        result.failure_signal = if (capture.timed_out) .timed_out else if (capture.output_limited) .output_limit else .spawn_failed;
    }

    if (result.failure_signal == .none and step.expectations.len > 0) {
        if (expectationFailure(allocator, step.expectations, result.stdout, result.stderr, result.exit_code orelse -1)) |summary| {
            result.failure_signal = .invariant_failed;
            result.invariant_summary = summary;
        }
    }

    return result;
}

pub fn buildEvidence(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    const stdout_excerpt = clipBytes(result.stdout, MAX_EVIDENCE_BYTES / 2);
    const stderr_excerpt = clipBytes(result.stderr, MAX_EVIDENCE_BYTES / 2);
    const exit_text = if (result.exit_code) |code|
        try std.fmt.allocPrint(allocator, "{d}", .{code})
    else
        try allocator.dupe(u8, "none");
    defer allocator.free(exit_text);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try writer.print(
        "phase={s}\ncommand={s}\nduration_ms={d}\nexit_code={s}\nfailure_signal={s}\n",
        .{
            phaseName(result.phase),
            result.command,
            result.duration_ms,
            exit_text,
            failureSignalName(result.failure_signal),
        },
    );
    if (result.invariant_summary) |summary| try writer.print("invariant={s}\n", .{summary});
    if (stdout_excerpt.len > 0) try writer.print("stdout:\n{s}\n", .{stdout_excerpt});
    if (stderr_excerpt.len > 0) try writer.print("stderr:\n{s}\n", .{stderr_excerpt});
    return out.toOwnedSlice();
}

fn blockedResult(
    allocator: std.mem.Allocator,
    step: Step,
    started: u64,
    signal: FailureSignal,
    detail: []const u8,
) !Result {
    return .{
        .label = try allocator.dupe(u8, step.label),
        .kind = step.kind,
        .phase = step.phase,
        .command = if (step.argv.len == 0) try allocator.dupe(u8, "") else try joinTokensOwned(allocator, step.argv),
        .stdout = try allocator.alloc(u8, 0),
        .stderr = try allocator.dupe(u8, detail),
        .duration_ms = sys.getMilliTick() - started,
        .failure_signal = signal,
    };
}

fn validateStep(allocator: std.mem.Allocator, options: Options, step: Step) !Validation {
    if (step.argv.len == 0 or step.argv.len > MAX_ARG_COUNT) return error.InvalidExecutionStep;
    const workspace_root = try normalizePath(allocator, options.workspace_root);
    defer allocator.free(workspace_root);
    const cwd = try normalizePath(allocator, options.cwd orelse options.workspace_root);
    errdefer allocator.free(cwd);
    if (!pathWithinRoot(workspace_root, cwd)) return error.WorkspaceEscape;

    var argv = try allocator.alloc([]u8, step.argv.len);
    var built: usize = 0;
    errdefer {
        for (argv[0..built]) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    for (step.argv, 0..) |arg, idx| {
        if (arg.len == 0 or arg.len > MAX_ARG_BYTES) return error.InvalidExecutionStep;
        argv[idx] = try allocator.dupe(u8, arg);
        built += 1;
    }

    switch (step.kind) {
        .zig_build => try validateZigBuild(argv),
        .zig_run => try validateZigRun(allocator, workspace_root, cwd, argv),
        .shell => try validateShell(allocator, workspace_root, cwd, argv),
    }

    if (options.path_override != null and argv.len > 0 and std.mem.eql(u8, argv[0], "zig")) {
        allocator.free(argv[0]);
        argv[0] = try std.fs.path.join(allocator, &.{ options.path_override.?, "zig" });
    }

    return .{
        .cwd = cwd,
        .argv = argv,
    };
}

fn validateZigBuild(argv: [][]u8) !void {
    if (argv.len < 2 or argv.len > 3) return error.InvalidExecutionStep;
    if (!std.mem.eql(u8, argv[0], "zig") or !std.mem.eql(u8, argv[1], "build")) return error.DisallowedCommand;
    if (argv.len == 3 and !isSimpleToken(argv[2])) return error.DisallowedCommand;
}

fn validateZigRun(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    cwd: []const u8,
    argv: [][]u8,
) !void {
    if (argv.len < 3 or argv.len > 8) return error.InvalidExecutionStep;
    if (!std.mem.eql(u8, argv[0], "zig") or !std.mem.eql(u8, argv[1], "run")) return error.DisallowedCommand;
    const source = try resolveCommandPath(allocator, workspace_root, cwd, argv[2]);
    defer allocator.free(source);
    if (!pathWithinRoot(workspace_root, source)) return error.WorkspaceEscape;
    if (!std.mem.endsWith(u8, source, ".zig")) return error.DisallowedCommand;
    if (argv.len > 3 and !std.mem.eql(u8, argv[3], "--")) return error.DisallowedCommand;
    if (argv.len > 4) {
        for (argv[4..]) |arg| if (!isSimpleToken(arg)) return error.DisallowedCommand;
    }
}

fn validateShell(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    cwd: []const u8,
    argv: [][]u8,
) !void {
    if (std.mem.indexOfScalar(u8, argv[0], '/')) |_| {
        const resolved = try resolveCommandPath(allocator, workspace_root, cwd, argv[0]);
        defer allocator.free(resolved);
        if (!pathWithinRoot(workspace_root, resolved)) return error.WorkspaceEscape;
    } else if (!allowlistedShellTool(argv[0])) {
        return error.DisallowedCommand;
    }

    for (argv[1..]) |arg| {
        if (arg.len > MAX_ARG_BYTES) return error.InvalidExecutionStep;
    }
}

fn allowlistedShellTool(name: []const u8) bool {
    for (ALLOWED_SHELL_TOOLS) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

fn clampTimeout(timeout_ms: u32) u32 {
    return @max(@as(u32, 1), @min(timeout_ms, MAX_TIMEOUT_MS));
}

fn runCaptureBounded(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: [][]u8,
    env_map: *const std.process.EnvMap,
    max_output_bytes: usize,
    timeout_ms: u32,
) !RunCapture {
    return switch (builtin.os.tag) {
        .linux, .macos => runCapturePosix(allocator, cwd, argv, env_map, max_output_bytes, timeout_ms),
        else => runCaptureFallback(allocator, cwd, argv, env_map, max_output_bytes),
    };
}

fn runCaptureFallback(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: [][]u8,
    env_map: *const std.process.EnvMap,
    max_output_bytes: usize,
) !RunCapture {
    const child_run = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .env_map = env_map,
        .max_output_bytes = max_output_bytes,
    }) catch return error.ProcessSpawnFailed;
    return .{
        .stdout = child_run.stdout,
        .stderr = child_run.stderr,
        .term = child_run.term,
    };
}

fn runCapturePosix(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: [][]u8,
    env_map: *const std.process.EnvMap,
    max_output_bytes: usize,
    timeout_ms: u32,
) !RunCapture {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    child.env_map = env_map;
    child.pgid = 0;

    try child.spawn();
    errdefer {
        forceKillPosixChild(child.id);
        closeChildStreams(&child);
    }
    try child.waitForSpawn();
    try enableNonBlocking(child.stdout.?.handle);
    try enableNonBlocking(child.stderr.?.handle);

    var stdout = std.ArrayList(u8).init(allocator);
    errdefer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    errdefer stderr.deinit();

    const started = sys.getMilliTick();
    var term: ?std.process.Child.Term = null;
    var timed_out = false;
    var output_limited = false;

    while (term == null or child.stdout != null or child.stderr != null) {
        if (term == null) {
            const wait_result = std.posix.waitpid(child.id, waitNoHang());
            if (wait_result.pid == child.id) term = statusToTerm(wait_result.status);
        }

        if (term == null and sys.getMilliTick() - started >= timeout_ms) {
            timed_out = true;
            forceKillPosixChild(child.id);
            const wait_result = std.posix.waitpid(child.id, 0);
            term = statusToTerm(wait_result.status);
        }

        var poll_fds: [2]std.posix.pollfd = undefined;
        var poll_count: usize = 0;
        if (child.stdout) |out| {
            poll_fds[poll_count] = .{
                .fd = out.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            };
            poll_count += 1;
        }
        if (child.stderr) |err_file| {
            poll_fds[poll_count] = .{
                .fd = err_file.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            };
            poll_count += 1;
        }

        if (poll_count == 0) {
            if (term == null) sys.sleep(5);
        } else {
            const poll_timeout = if (term == null) @as(i32, 25) else @as(i32, 0);
            _ = try std.posix.poll(poll_fds[0..poll_count], poll_timeout);
        }

        if (try drainPipe(&child.stdout, &stdout, max_output_bytes)) output_limited = true;
        if (try drainPipe(&child.stderr, &stderr, max_output_bytes)) output_limited = true;

        if (output_limited and term == null) {
            forceKillPosixChild(child.id);
            const wait_result = std.posix.waitpid(child.id, 0);
            term = statusToTerm(wait_result.status);
        }
    }

    closeChildStreams(&child);
    return .{
        .stdout = try stdout.toOwnedSlice(),
        .stderr = try stderr.toOwnedSlice(),
        .term = term,
        .timed_out = timed_out,
        .output_limited = output_limited,
    };
}

fn waitNoHang() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.W.NOHANG,
        .macos => std.c.W.NOHANG,
        else => 0,
    };
}

fn drainPipe(file: *?std.fs.File, sink: *std.ArrayList(u8), max_output_bytes: usize) !bool {
    const handle = if (file.*) |value| value.handle else return false;
    var buf: [2048]u8 = undefined;
    const read = std.posix.read(handle, &buf) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    if (read == 0) {
        file.*.?.close();
        file.* = null;
        return false;
    }

    const remaining = max_output_bytes -| sink.items.len;
    if (read > remaining) {
        if (remaining > 0) try sink.appendSlice(buf[0..remaining]);
        return true;
    }

    try sink.appendSlice(buf[0..read]);
    return false;
}

fn closeChildStreams(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
    if (child.stdout) |*stdout| {
        stdout.close();
        child.stdout = null;
    }
    if (child.stderr) |*stderr| {
        stderr.close();
        child.stderr = null;
    }
}

fn enableNonBlocking(fd: std.posix.fd_t) !void {
    var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
}

fn forceKillPosixChild(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, std.posix.SIG.TERM) catch {};
    sys.sleep(25);
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
}

fn expectationFailure(
    allocator: std.mem.Allocator,
    expectations: []const Expectation,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
) ?[]u8 {
    for (expectations) |expectation| {
        switch (expectation) {
            .success => if (exit_code != 0) {
                return allocator.dupe(u8, "expected zero exit code") catch null;
            },
            .exit_code => |expected| if (exit_code != expected) {
                return std.fmt.allocPrint(allocator, "expected exit code {d}, got {d}", .{ expected, exit_code }) catch null;
            },
            .stdout_contains => |needle| if (std.mem.indexOf(u8, stdout, needle) == null) {
                return std.fmt.allocPrint(allocator, "expected stdout to contain {s}", .{needle}) catch null;
            },
            .stderr_contains => |needle| if (std.mem.indexOf(u8, stderr, needle) == null) {
                return std.fmt.allocPrint(allocator, "expected stderr to contain {s}", .{needle}) catch null;
            },
            .stdout_not_contains => |needle| if (std.mem.indexOf(u8, stdout, needle) != null) {
                return std.fmt.allocPrint(allocator, "expected stdout to exclude {s}", .{needle}) catch null;
            },
            .stderr_not_contains => |needle| if (std.mem.indexOf(u8, stderr, needle) != null) {
                return std.fmt.allocPrint(allocator, "expected stderr to exclude {s}", .{needle}) catch null;
            },
        }
    }
    return null;
}

fn signalFromTerm(term: std.process.Child.Term, timed_out: bool, output_limited: bool) FailureSignal {
    if (timed_out) return .timed_out;
    if (output_limited) return .output_limit;
    return switch (term) {
        .Exited => |code| if (code == 0) .none else .nonzero_exit,
        .Signal, .Stopped, .Unknown => .signaled,
    };
}

fn termExitCode(term: std.process.Child.Term) ?i32 {
    return switch (term) {
        .Exited => |code| @as(i32, code),
        .Signal => |code| -@as(i32, @intCast(code)),
        .Stopped => |code| -@as(i32, @intCast(code)),
        .Unknown => |code| -@as(i32, @intCast(code)),
    };
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.WorkspaceEscape;
    return std.fs.path.resolve(allocator, &.{path});
}

fn resolveCommandPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    cwd: []const u8,
    arg: []const u8,
) ![]u8 {
    const resolved = if (std.fs.path.isAbsolute(arg))
        try std.fs.path.resolve(allocator, &.{arg})
    else
        try std.fs.path.resolve(allocator, &.{ cwd, arg });
    if (!pathWithinRoot(workspace_root, resolved)) return error.WorkspaceEscape;
    return resolved;
}

fn pathWithinRoot(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    return candidate[root.len] == std.fs.path.sep;
}

fn isSimpleToken(text: []const u8) bool {
    for (text) |byte| {
        if (std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte)) continue;
        switch (byte) {
            '-', '_', '.', '/', ':', '@', '+' => continue,
            else => return false,
        }
    }
    return text.len > 0;
}

fn joinTokensOwned(allocator: std.mem.Allocator, tokens: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (tokens, 0..) |token, idx| {
        if (idx != 0) try out.append(' ');
        try out.appendSlice(token);
    }
    return out.toOwnedSlice();
}

fn clipBytes(bytes: []const u8, max_len: usize) []const u8 {
    const trimmed = std.mem.trim(u8, bytes, " \r\n\t");
    if (trimmed.len <= max_len) return trimmed;
    return trimmed[trimmed.len - max_len ..];
}
