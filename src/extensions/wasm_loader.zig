const std = @import("std");
const proof_session = @import("proof_session");

pub const EXECUTE_HEURISTIC_FALLBACK_EXPORT = "execute_heuristic_fallback";
pub const EXECUTION_TIMEOUT_MS: u64 = 200;

pub const WasmWardenError = error{
    AdapterInitFailed,
    AdapterLoadFailed,
    MissingHeuristicFallbackExport,
    AdapterExecutionFailed,
    FallbackTimeout,
    InvalidAdapterOutput,
    OutOfMemory,
};

pub const ExportCall = struct {
    name: []const u8,
    target_ptr: u32,
    target_len: u32,
};

pub const RuntimeDeadline = struct {
    started_ns: i128,
    timeout_ns: i128,

    pub fn start(timeout_ms: u64) RuntimeDeadline {
        return .{
            .started_ns = std.time.nanoTimestamp(),
            .timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms,
        };
    }

    pub fn elapsedNs(self: RuntimeDeadline) i128 {
        return std.time.nanoTimestamp() - self.started_ns;
    }

    pub fn expired(self: RuntimeDeadline) bool {
        return self.elapsedNs() >= self.timeout_ns;
    }

    pub fn remainingNs(self: RuntimeDeadline) i128 {
        const remaining = self.timeout_ns - self.elapsedNs();
        return if (remaining > 0) remaining else 0;
    }
};

pub const MockWasmRuntime = struct {
    exported_name: []const u8 = EXECUTE_HEURISTIC_FALLBACK_EXPORT,
    output: []const u8 = "wasm heuristic fallback accepted target",
    execution_delay_ms: u64 = 0,
    initialized: bool = false,
    loaded: bool = false,
    last_call: ?ExportCall = null,

    pub fn init(self: *MockWasmRuntime, allocator: std.mem.Allocator) WasmWardenError!void {
        _ = allocator;
        self.initialized = true;
    }

    pub fn deinit(self: *MockWasmRuntime) void {
        self.loaded = false;
        self.initialized = false;
    }

    pub fn loadModule(self: *MockWasmRuntime, wasm_bytes: []const u8) WasmWardenError!void {
        if (!self.initialized or wasm_bytes.len == 0) return error.AdapterLoadFailed;
        self.loaded = true;
    }

    pub fn hasExport(self: *const MockWasmRuntime, name: []const u8) bool {
        return self.loaded and std.mem.eql(u8, self.exported_name, name);
    }

    pub fn executeExport(
        self: *MockWasmRuntime,
        name: []const u8,
        target: []const u8,
        deadline: RuntimeDeadline,
    ) WasmWardenError![]const u8 {
        if (!self.hasExport(name)) return error.MissingHeuristicFallbackExport;
        if (target.len > std.math.maxInt(u32)) return error.AdapterExecutionFailed;

        self.last_call = .{
            .name = name,
            .target_ptr = 0,
            .target_len = @intCast(target.len),
        };

        if (deadline.expired()) return error.FallbackTimeout;

        const simulated_ns = @as(i128, self.execution_delay_ms) * std.time.ns_per_ms;
        if (simulated_ns >= deadline.remainingNs()) {
            return error.FallbackTimeout;
        }

        if (simulated_ns > 0) {
            const sleep_ns: u64 = @intCast(simulated_ns);
            std.time.sleep(sleep_ns);
        }

        if (deadline.expired()) return error.FallbackTimeout;
        return self.output;
    }
};

pub fn WasmWarden(comptime Runtime: type) type {
    return struct {
        allocator: std.mem.Allocator,
        runtime: Runtime,
        loaded: bool = false,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, runtime: Runtime) WasmWardenError!Self {
            var self = Self{
                .allocator = allocator,
                .runtime = runtime,
            };
            try self.runtime.init(allocator);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.runtime.deinit();
            self.* = undefined;
        }

        pub fn loadAdapter(self: *Self, wasm_bytes: []const u8) WasmWardenError!void {
            try self.runtime.loadModule(wasm_bytes);
            if (!self.runtime.hasExport(EXECUTE_HEURISTIC_FALLBACK_EXPORT)) {
                return error.MissingHeuristicFallbackExport;
            }
            self.loaded = true;
        }

        pub fn executeHeuristicFallback(
            self: *Self,
            target: []const u8,
        ) WasmWardenError!proof_session.RetrievedFact {
            if (!self.loaded) return error.AdapterLoadFailed;

            const deadline = RuntimeDeadline.start(EXECUTION_TIMEOUT_MS);
            const raw_output = try self.runtime.executeExport(
                EXECUTE_HEURISTIC_FALLBACK_EXPORT,
                target,
                deadline,
            );
            if (deadline.expired()) return error.FallbackTimeout;

            return parseAdapterOutput(self.allocator, raw_output);
        }
    };
}

pub fn parseAdapterOutput(
    allocator: std.mem.Allocator,
    raw_output: []const u8,
) WasmWardenError!proof_session.RetrievedFact {
    const trimmed = std.mem.trim(u8, raw_output, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAdapterOutput;

    return .{
        .data = try allocator.dupe(u8, trimmed),
        .source = .WASM_ADAPTER,
        .confidence = .HEURISTIC,
    };
}

test "fast wasm heuristic fallback returns heuristic wasm fact" {
    const runtime = MockWasmRuntime{
        .output = "  candidate domain fact from wasm adapter  ",
        .execution_delay_ms = 1,
    };
    var warden = try WasmWarden(MockWasmRuntime).init(std.testing.allocator, runtime);
    defer warden.deinit();

    try warden.loadAdapter("mock-wasm-module");
    const fact = try warden.executeHeuristicFallback("non-code domain target");
    defer std.testing.allocator.free(fact.data);

    try std.testing.expectEqual(proof_session.SourceType.WASM_ADAPTER, fact.source);
    try std.testing.expectEqual(proof_session.ConfidenceTier.HEURISTIC, fact.confidence);
    try std.testing.expectEqualStrings("candidate domain fact from wasm adapter", fact.data);

    const call = warden.runtime.last_call orelse return error.AdapterExecutionFailed;
    try std.testing.expectEqualStrings(EXECUTE_HEURISTIC_FALLBACK_EXPORT, call.name);
    try std.testing.expectEqual(@as(u32, 22), call.target_len);
}

test "slow wasm heuristic fallback aborts at 200ms budget" {
    const runtime = MockWasmRuntime{
        .output = "late output must not be trusted",
        .execution_delay_ms = EXECUTION_TIMEOUT_MS + 1,
    };
    var warden = try WasmWarden(MockWasmRuntime).init(std.testing.allocator, runtime);
    defer warden.deinit();

    try warden.loadAdapter("mock-wasm-module");

    const started = std.time.nanoTimestamp();
    try std.testing.expectError(
        error.FallbackTimeout,
        warden.executeHeuristicFallback("target that would otherwise run too long"),
    );
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < EXECUTION_TIMEOUT_MS);
}

test "missing execute_heuristic_fallback export is rejected before execution" {
    const runtime = MockWasmRuntime{ .exported_name = "other_export" };
    var warden = try WasmWarden(MockWasmRuntime).init(std.testing.allocator, runtime);
    defer warden.deinit();

    try std.testing.expectError(
        error.MissingHeuristicFallbackExport,
        warden.loadAdapter("mock-wasm-module"),
    );
}
