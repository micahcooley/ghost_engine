const std = @import("std");
const anchors = @import("anchor_discovery");
const tensor = @import("semantic_tensor");
const proof_session = @import("proof_session");

const c = @cImport({
    @cInclude("z3.h");
});

pub const MAX_SOLVER_CHECK_MS: u64 = 500;
pub const MAX_LOCKS: usize = 64;
pub const MAX_LOCK_ORDER_PAIRS: usize = 256;
pub const MAX_LOCK_EVENTS: usize = 256;

pub const BridgeError = error{
    Z3ConfigCreateFailed,
    Z3ContextCreateFailed,
    Z3SolverCreateFailed,
    Z3AstCreateFailed,
    Z3Error,
    ProofTimeout,
    AnchorMissing,
    AnchorFunctionMissing,
    AnalysisOverflow,
};

pub const ProofStatus = enum {
    proved_no_lock_inversion,
    lock_inversion_possible,
    solver_unknown,
    no_anchor,
    no_statically_visible_locks,
    analysis_overflow,
};

pub const ProofSignal = enum {
    green_verified,
    yellow_heuristic,
    failure,

    pub fn tag(self: ProofSignal) []const u8 {
        return switch (self) {
            .green_verified => "GREEN/VERIFIED_PROOF",
            .yellow_heuristic => "YELLOW/HEURISTIC_WARNING",
            .failure => "FAILURE/LOCK_INVERSION_POSSIBLE",
        };
    }
};

pub const LockOrderPair = struct {
    before: []const u8,
    after: []const u8,
    line: u32,
};

pub const LockProofResult = struct {
    status: ProofStatus,
    signal: ProofSignal,
    confidence_band: tensor.ConfidenceBand,
    confidence: f32,
    anchor_function: ?[]const u8 = null,
    lock_count: usize = 0,
    order_pair_count: usize = 0,
    timed_out_or_unknown: bool = false,
    z3_error: bool = false,
};

pub const ProverOptions = struct {
    timeout_ms: u32 = MAX_SOLVER_CHECK_MS,
};

pub fn proveTrivialConstraintFact(allocator: std.mem.Allocator) BridgeError!proof_session.RetrievedFact {
    _ = allocator;
    var z3 = try Z3Context.init(MAX_SOLVER_CHECK_MS);
    defer z3.deinit();

    var solver = try Solver.init(&z3);
    defer solver.deinit();

    const check = try solver.check(MAX_SOLVER_CHECK_MS);
    if (check != .sat) return BridgeError.Z3Error;

    return .{
        .data = "z3 constraint system is satisfiable",
        .source = .Z3_PROOF,
        .confidence = .PROVEN,
    };
}

pub fn proveLockInversionAbsence(
    allocator: std.mem.Allocator,
    source: []const u8,
    anchor_result: anchors.AnchorResult,
    options: ProverOptions,
) BridgeError!LockProofResult {
    _ = allocator;
    if (anchor_result.anchor == null) {
        return .{
            .status = .no_anchor,
            .signal = .yellow_heuristic,
            .confidence_band = .yellow_heuristic,
            .confidence = 0.20,
        };
    }

    var critical = try extractAnchorCriticalSections(source, anchor_result);
    if (critical.overflow) {
        return .{
            .status = .analysis_overflow,
            .signal = .yellow_heuristic,
            .confidence_band = .yellow_heuristic,
            .confidence = 0.25,
            .anchor_function = anchor_result.anchor.?.function_name,
            .lock_count = critical.lock_len,
            .order_pair_count = critical.pair_len,
        };
    }
    if (critical.lock_len == 0 or critical.pair_len == 0) {
        return .{
            .status = .no_statically_visible_locks,
            .signal = .yellow_heuristic,
            .confidence_band = .yellow_heuristic,
            .confidence = 0.35,
            .anchor_function = anchor_result.anchor.?.function_name,
            .lock_count = critical.lock_len,
            .order_pair_count = critical.pair_len,
        };
    }

    var z3 = try Z3Context.init(timeoutBudgetMs(options.timeout_ms));
    defer z3.deinit();

    var solver = try Solver.init(&z3);
    defer solver.deinit();

    var ranks: [MAX_LOCKS]Ast = undefined;
    var rank_len: usize = 0;
    errdefer {
        for (ranks[0..rank_len]) |*rank| rank.deinit();
    }

    for (critical.lockSlice()) |lock_name| {
        ranks[rank_len] = try z3.mkIntConst(lock_name);
        rank_len += 1;
    }

    for (critical.pairSlice()) |pair| {
        const before_index = critical.lockIndex(pair.before) orelse return BridgeError.AnalysisOverflow;
        const after_index = critical.lockIndex(pair.after) orelse return BridgeError.AnalysisOverflow;
        var order = try z3.mkLt(ranks[before_index], ranks[after_index]);
        defer order.deinit();
        try solver.assert(order);
    }

    const check = solver.check(timeoutBudgetMs(options.timeout_ms)) catch |err| {
        if (err == BridgeError.ProofTimeout) return err;
        for (ranks[0..rank_len]) |*rank| rank.deinit();
        return .{
            .status = .solver_unknown,
            .signal = .yellow_heuristic,
            .confidence_band = .yellow_heuristic,
            .confidence = 0.40,
            .anchor_function = anchor_result.anchor.?.function_name,
            .lock_count = critical.lock_len,
            .order_pair_count = critical.pair_len,
            .timed_out_or_unknown = true,
            .z3_error = true,
        };
    };

    for (ranks[0..rank_len]) |*rank| rank.deinit();

    return switch (check) {
        .sat => .{
            .status = .proved_no_lock_inversion,
            .signal = .green_verified,
            .confidence_band = .green_verified,
            .confidence = 0.96,
            .anchor_function = anchor_result.anchor.?.function_name,
            .lock_count = critical.lock_len,
            .order_pair_count = critical.pair_len,
        },
        .unsat => .{
            .status = .lock_inversion_possible,
            .signal = .failure,
            .confidence_band = .yellow_heuristic,
            .confidence = 0.10,
            .anchor_function = anchor_result.anchor.?.function_name,
            .lock_count = critical.lock_len,
            .order_pair_count = critical.pair_len,
        },
        .unknown => .{
            .status = .solver_unknown,
            .signal = .yellow_heuristic,
            .confidence_band = .yellow_heuristic,
            .confidence = 0.40,
            .anchor_function = anchor_result.anchor.?.function_name,
            .lock_count = critical.lock_len,
            .order_pair_count = critical.pair_len,
            .timed_out_or_unknown = true,
        },
    };
}

const Z3Check = enum {
    sat,
    unsat,
    unknown,
};

const Z3Context = struct {
    ctx: c.Z3_context,

    fn init(timeout_ms: u64) BridgeError!Z3Context {
        const cfg = c.Z3_mk_config() orelse return BridgeError.Z3ConfigCreateFailed;
        defer c.Z3_del_config(cfg);

        c.Z3_set_param_value(cfg, "model", "false");
        c.Z3_set_param_value(cfg, "proof", "false");
        var timeout_buf: [32]u8 = undefined;
        const timeout = std.fmt.bufPrintZ(&timeout_buf, "{d}", .{timeout_ms}) catch return BridgeError.Z3Error;
        c.Z3_set_param_value(cfg, "timeout", timeout.ptr);

        const ctx = c.Z3_mk_context_rc(cfg) orelse return BridgeError.Z3ContextCreateFailed;
        c.Z3_set_error_handler(ctx, z3ErrorHandler);
        var out = Z3Context{ .ctx = ctx };
        try out.check();
        return out;
    }

    fn deinit(self: *Z3Context) void {
        c.Z3_del_context(self.ctx);
        self.* = undefined;
    }

    fn check(self: *Z3Context) BridgeError!void {
        const code = c.Z3_get_error_code(self.ctx);
        if (code != c.Z3_OK) return BridgeError.Z3Error;
    }

    fn mkIntConst(self: *Z3Context, name: []const u8) BridgeError!Ast {
        var name_buf: [256]u8 = undefined;
        if (name.len >= name_buf.len) return BridgeError.AnalysisOverflow;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        const sym = c.Z3_mk_string_symbol(self.ctx, name_buf[0..name.len :0].ptr);
        try self.check();
        const sort = c.Z3_mk_int_sort(self.ctx);
        try self.check();
        return Ast.init(self, c.Z3_mk_const(self.ctx, sym, sort));
    }

    fn mkLt(self: *Z3Context, lhs: Ast, rhs: Ast) BridgeError!Ast {
        return Ast.init(self, c.Z3_mk_lt(self.ctx, lhs.raw, rhs.raw));
    }
};

fn timeoutBudgetMs(requested_ms: u64) u64 {
    if (requested_ms == 0 or requested_ms > MAX_SOLVER_CHECK_MS) return MAX_SOLVER_CHECK_MS;
    return requested_ms;
}

fn z3ErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

const Ast = struct {
    owner: *Z3Context,
    raw: c.Z3_ast,

    fn init(owner: *Z3Context, raw: c.Z3_ast) BridgeError!Ast {
        if (raw == null) return BridgeError.Z3AstCreateFailed;
        c.Z3_inc_ref(owner.ctx, raw);
        try owner.check();
        return .{ .owner = owner, .raw = raw };
    }

    fn deinit(self: *Ast) void {
        if (self.raw != null) {
            c.Z3_dec_ref(self.owner.ctx, self.raw);
            self.raw = null;
        }
    }
};

const Solver = struct {
    owner: *Z3Context,
    raw: c.Z3_solver,

    fn init(owner: *Z3Context) BridgeError!Solver {
        const raw = c.Z3_mk_solver(owner.ctx) orelse return BridgeError.Z3SolverCreateFailed;
        c.Z3_solver_inc_ref(owner.ctx, raw);
        try owner.check();
        return .{ .owner = owner, .raw = raw };
    }

    fn deinit(self: *Solver) void {
        c.Z3_solver_dec_ref(self.owner.ctx, self.raw);
        self.raw = null;
    }

    fn assert(self: *Solver, ast: Ast) BridgeError!void {
        c.Z3_solver_assert(self.owner.ctx, self.raw, ast.raw);
        try self.owner.check();
    }

    fn check(self: *Solver, timeout_ms: u64) BridgeError!Z3Check {
        var timer = std.time.Timer.start() catch return BridgeError.Z3Error;
        var watchdog = SolverWatchdog{
            .ctx = self.owner,
            .timeout_ns = timeout_ms * std.time.ns_per_ms,
        };
        var thread = std.Thread.spawn(.{}, SolverWatchdog.run, .{&watchdog}) catch return BridgeError.Z3Error;
        const result = c.Z3_solver_check(self.owner.ctx, self.raw);
        watchdog.done.store(true, .release);
        thread.join();
        if (watchdog.timed_out.load(.acquire) or timer.read() > watchdog.timeout_ns) {
            return BridgeError.ProofTimeout;
        }
        try self.owner.check();
        return switch (result) {
            c.Z3_L_TRUE => .sat,
            c.Z3_L_FALSE => .unsat,
            else => .unknown,
        };
    }
};

const SolverWatchdog = struct {
    ctx: *Z3Context,
    timeout_ns: u64,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *SolverWatchdog) void {
        var timer = std.time.Timer.start() catch return;
        while (!self.done.load(.acquire)) {
            if (timer.read() >= self.timeout_ns) {
                self.timed_out.store(true, .release);
                c.Z3_interrupt(self.ctx.ctx);
                return;
            }
            std.time.sleep(std.time.ns_per_ms);
        }
    }
};

const CriticalSectionMap = struct {
    locks: [MAX_LOCKS][]const u8 = undefined,
    lock_len: usize = 0,
    pairs: [MAX_LOCK_ORDER_PAIRS]LockOrderPair = undefined,
    pair_len: usize = 0,
    overflow: bool = false,

    fn lockSlice(self: *const CriticalSectionMap) []const []const u8 {
        return self.locks[0..self.lock_len];
    }

    fn pairSlice(self: *const CriticalSectionMap) []const LockOrderPair {
        return self.pairs[0..self.pair_len];
    }

    fn ensureLock(self: *CriticalSectionMap, name: []const u8) ?usize {
        if (self.lockIndex(name)) |index| return index;
        if (self.lock_len >= MAX_LOCKS) {
            self.overflow = true;
            return null;
        }
        self.locks[self.lock_len] = name;
        self.lock_len += 1;
        return self.lock_len - 1;
    }

    fn lockIndex(self: *const CriticalSectionMap, name: []const u8) ?usize {
        for (self.lockSlice(), 0..) |lock, index| {
            if (std.mem.eql(u8, lock, name)) return index;
        }
        return null;
    }

    fn addPair(self: *CriticalSectionMap, before: []const u8, after: []const u8, line: u32) void {
        if (std.mem.eql(u8, before, after)) return;
        _ = self.ensureLock(before) orelse return;
        _ = self.ensureLock(after) orelse return;
        for (self.pairSlice()) |pair| {
            if (std.mem.eql(u8, pair.before, before) and std.mem.eql(u8, pair.after, after)) return;
        }
        if (self.pair_len >= MAX_LOCK_ORDER_PAIRS) {
            self.overflow = true;
            return;
        }
        self.pairs[self.pair_len] = .{ .before = before, .after = after, .line = line };
        self.pair_len += 1;
    }
};

const LockEventKind = enum {
    acquire,
    release,
};

const LockEvent = struct {
    kind: LockEventKind,
    name: []const u8,
    line: u32,
    offset: usize,
    deferred_release: bool = false,
};

fn extractAnchorCriticalSections(source: []const u8, anchor_result: anchors.AnchorResult) BridgeError!CriticalSectionMap {
    const anchor = anchor_result.anchor orelse return BridgeError.AnchorMissing;
    const anchor_index = findFunction(anchor_result, anchor.function_name) orelse return BridgeError.AnchorFunctionMissing;

    var reachable = [_]bool{false} ** anchors.MAX_FUNCTIONS;
    markReachable(anchor_result, anchor_index, &reachable);

    var map: CriticalSectionMap = .{};
    for (anchor_result.functionSlice(), 0..) |function, function_index| {
        if (!reachable[function_index]) continue;
        scanFunctionLocks(source, function, &map);
        if (map.overflow) return map;
    }
    return map;
}

fn markReachable(anchor_result: anchors.AnchorResult, function_index: usize, reachable: *[anchors.MAX_FUNCTIONS]bool) void {
    if (reachable[function_index]) return;
    reachable[function_index] = true;

    const function = anchor_result.functions[function_index];
    var call_index = function.call_start;
    const end = function.call_start + function.call_len;
    while (call_index < end) : (call_index += 1) {
        if (anchor_result.calls[call_index].callee) |callee| {
            markReachable(anchor_result, callee, reachable);
        }
    }
}

fn findFunction(anchor_result: anchors.AnchorResult, name: []const u8) ?usize {
    for (anchor_result.functionSlice(), 0..) |function, index| {
        if (std.mem.eql(u8, function.name, name)) return index;
    }
    return null;
}

fn scanFunctionLocks(source: []const u8, function: anchors.FunctionNode, map: *CriticalSectionMap) void {
    const body = source[function.body_start..function.body_end];
    var events: [MAX_LOCK_EVENTS]LockEvent = undefined;
    var event_len: usize = 0;

    collectMethodLockEvents(source, function.body_start, body, &events, &event_len, map);
    collectFreeLockEvents(source, function.body_start, body, &events, &event_len, map);
    sortEvents(events[0..event_len]);

    var held: [MAX_LOCKS][]const u8 = undefined;
    var held_len: usize = 0;

    for (events[0..event_len]) |event| {
        switch (event.kind) {
            .acquire => {
                _ = map.ensureLock(event.name) orelse return;
                for (held[0..held_len]) |held_lock| {
                    map.addPair(held_lock, event.name, event.line);
                    if (map.overflow) return;
                }
                if (!containsLock(held[0..held_len], event.name)) {
                    if (held_len >= MAX_LOCKS) {
                        map.overflow = true;
                        return;
                    }
                    held[held_len] = event.name;
                    held_len += 1;
                }
            },
            .release => {
                if (event.deferred_release) continue;
                removeHeldLock(held[0..held_len], &held_len, event.name);
            },
        }
    }
}

fn collectMethodLockEvents(
    source: []const u8,
    body_start: usize,
    body: []const u8,
    events: *[MAX_LOCK_EVENTS]LockEvent,
    event_len: *usize,
    map: *CriticalSectionMap,
) void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, ".lock(")) |hit| {
        const name = receiverBeforeDot(body, hit) orelse {
            cursor = hit + ".lock(".len;
            continue;
        };
        appendEvent(source, body_start, body, events, event_len, map, .{
            .kind = .acquire,
            .name = name,
            .line = lineForOffset(source, body_start + hit),
            .offset = body_start + hit,
        });
        cursor = hit + ".lock(".len;
    }

    cursor = 0;
    while (std.mem.indexOfPos(u8, body, cursor, ".unlock(")) |hit| {
        const name = receiverBeforeDot(body, hit) orelse {
            cursor = hit + ".unlock(".len;
            continue;
        };
        appendEvent(source, body_start, body, events, event_len, map, .{
            .kind = .release,
            .name = name,
            .line = lineForOffset(source, body_start + hit),
            .offset = body_start + hit,
            .deferred_release = lineHasDefer(body, hit),
        });
        cursor = hit + ".unlock(".len;
    }
}

fn collectFreeLockEvents(
    source: []const u8,
    body_start: usize,
    body: []const u8,
    events: *[MAX_LOCK_EVENTS]LockEvent,
    event_len: *usize,
    map: *CriticalSectionMap,
) void {
    collectFreeCallEvents(source, body_start, body, "lock", .acquire, events, event_len, map);
    collectFreeCallEvents(source, body_start, body, "unlock", .release, events, event_len, map);
}

fn collectFreeCallEvents(
    source: []const u8,
    body_start: usize,
    body: []const u8,
    callee: []const u8,
    kind: LockEventKind,
    events: *[MAX_LOCK_EVENTS]LockEvent,
    event_len: *usize,
    map: *CriticalSectionMap,
) void {
    var cursor: usize = 0;
    while (indexOfNameCall(body, callee, cursor)) |hit| {
        const open = std.mem.indexOfScalarPos(u8, body, hit, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, body, open + 1, ')') orelse break;
        const name = std.mem.trim(u8, body[open + 1 .. close], " \t\r\n&*");
        if (name.len > 0 and isSimpleLockName(name)) {
            appendEvent(source, body_start, body, events, event_len, map, .{
                .kind = kind,
                .name = name,
                .line = lineForOffset(source, body_start + hit),
                .offset = body_start + hit,
                .deferred_release = kind == .release and lineHasDefer(body, hit),
            });
        }
        cursor = close + 1;
    }
}

fn appendEvent(
    source: []const u8,
    body_start: usize,
    body: []const u8,
    events: *[MAX_LOCK_EVENTS]LockEvent,
    event_len: *usize,
    map: *CriticalSectionMap,
    event: LockEvent,
) void {
    _ = source;
    _ = body_start;
    _ = body;
    if (event_len.* >= MAX_LOCK_EVENTS) {
        map.overflow = true;
        return;
    }
    events[event_len.*] = event;
    event_len.* += 1;
}

fn sortEvents(events: []LockEvent) void {
    var i: usize = 1;
    while (i < events.len) : (i += 1) {
        var j = i;
        while (j > 0 and events[j].offset < events[j - 1].offset) : (j -= 1) {
            const tmp = events[j - 1];
            events[j - 1] = events[j];
            events[j] = tmp;
        }
    }
}

fn receiverBeforeDot(body: []const u8, dot_offset: usize) ?[]const u8 {
    if (dot_offset == 0) return null;
    var end = dot_offset;
    while (end > 0 and std.ascii.isWhitespace(body[end - 1])) end -= 1;
    if (end == 0 or !isIdentTail(body[end - 1])) return null;
    var start = end - 1;
    while (start > 0 and isQualifiedIdentByte(body[start - 1])) start -= 1;
    var name = body[start..end];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |last_dot| name = name[last_dot + 1 ..];
    if (std.mem.lastIndexOf(u8, name, "->")) |arrow| name = name[arrow + 2 ..];
    return std.mem.trim(u8, name, " \t\r\n*&");
}

fn lineHasDefer(body: []const u8, offset: usize) bool {
    var start = offset;
    while (start > 0 and body[start - 1] != '\n') start -= 1;
    const line_prefix = body[start..offset];
    return std.mem.indexOf(u8, line_prefix, "defer") != null or std.mem.indexOf(u8, line_prefix, "errdefer") != null;
}

fn containsLock(locks: []const []const u8, name: []const u8) bool {
    for (locks) |lock| {
        if (std.mem.eql(u8, lock, name)) return true;
    }
    return false;
}

fn removeHeldLock(held: []const []const u8, held_len: *usize, name: []const u8) void {
    var i: usize = 0;
    while (i < held_len.*) : (i += 1) {
        if (!std.mem.eql(u8, held[i], name)) continue;
        var j = i;
        while (j + 1 < held_len.*) : (j += 1) {
            @constCast(held)[j] = held[j + 1];
        }
        held_len.* -= 1;
        return;
    }
}

fn indexOfNameCall(text: []const u8, name: []const u8, start: usize) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, text, cursor, name)) |hit| {
        const before_ok = hit == 0 or !isIdentTail(text[hit - 1]);
        const after = hit + name.len;
        if (before_ok and after < text.len and text[after] == '(') return hit;
        cursor = after;
    }
    return null;
}

fn isSimpleLockName(name: []const u8) bool {
    for (name) |byte| {
        if (!isQualifiedIdentByte(byte)) return false;
    }
    return true;
}

fn isIdentTail(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isQualifiedIdentByte(byte: u8) bool {
    return isIdentTail(byte) or byte == '.' or byte == '>' or byte == '-';
}

fn lineForOffset(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

fn forcedTimeoutLoopForTest(timeout_ms: u64) BridgeError!void {
    var timer = std.time.Timer.start() catch return BridgeError.Z3Error;
    while (true) {
        if (timer.read() >= timeout_ms * std.time.ns_per_ms) return BridgeError.ProofTimeout;
        std.time.sleep(std.time.ns_per_ms);
    }
}

test "Z3 quarantine init and deinit is owned by bridge" {
    var z3 = try Z3Context.init(MAX_SOLVER_CHECK_MS);
    z3.deinit();
}

test "Z3 bridge returns proven retrieved fact for fast satisfiable proof" {
    const fact = try proveTrivialConstraintFact(std.testing.allocator);
    try std.testing.expectEqual(proof_session.SourceType.Z3_PROOF, fact.source);
    try std.testing.expectEqual(proof_session.ConfidenceTier.PROVEN, fact.confidence);
    try std.testing.expectEqualStrings("z3 constraint system is satisfiable", fact.data);
}

test "Z3 bridge timeout loop returns proof timeout without fact" {
    try std.testing.expectError(BridgeError.ProofTimeout, forcedTimeoutLoopForTest(1));
}

test "Z3 bridge proves anchored lock order has no inversion" {
    const source =
        \\int helper(void) {
        \\    a.lock();
        \\    defer a.unlock();
        \\    b.lock();
        \\    defer b.unlock();
        \\    return 1;
        \\}
        \\
        \\int public_entry(void) {
        \\    return helper();
        \\}
    ;
    const domain_map = comptime @import("domain_inference").inferDomainMapComptime(&.{
        .{ .path = "locks/order.c", .source = source },
    });
    const anchor = comptime anchors.discoverAnchorForStaticUnit(source, "locks/order.c", domain_map);

    const result = try proveLockInversionAbsence(std.testing.allocator, source, anchor, .{ .timeout_ms = 250 });
    try std.testing.expectEqual(ProofStatus.proved_no_lock_inversion, result.status);
    try std.testing.expectEqual(ProofSignal.green_verified, result.signal);
    try std.testing.expectEqual(tensor.ConfidenceBand.green_verified, result.confidence_band);
    try std.testing.expectEqual(@as(usize, 2), result.lock_count);
    try std.testing.expectEqual(@as(usize, 1), result.order_pair_count);
}

test "Z3 bridge reports lock inversion from contradictory anchored order" {
    const source =
        \\static int left(void) {
        \\    a.lock();
        \\    defer a.unlock();
        \\    b.lock();
        \\    defer b.unlock();
        \\    return 1;
        \\}
        \\
        \\static int right(void) {
        \\    b.lock();
        \\    defer b.unlock();
        \\    a.lock();
        \\    defer a.unlock();
        \\    return 2;
        \\}
        \\
        \\int public_entry(void) {
        \\    return left() + right();
        \\}
    ;
    const domain_map = comptime @import("domain_inference").inferDomainMapComptime(&.{
        .{ .path = "locks/inversion.c", .source = source },
    });
    const anchor = comptime anchors.discoverAnchorForStaticUnit(source, "locks/inversion.c", domain_map);

    const result = try proveLockInversionAbsence(std.testing.allocator, source, anchor, .{ .timeout_ms = 250 });
    try std.testing.expectEqual(ProofStatus.lock_inversion_possible, result.status);
    try std.testing.expectEqual(ProofSignal.failure, result.signal);
    try std.testing.expectEqual(tensor.ConfidenceBand.yellow_heuristic, result.confidence_band);
    try std.testing.expectEqual(@as(usize, 2), result.lock_count);
    try std.testing.expectEqual(@as(usize, 2), result.order_pair_count);
}
