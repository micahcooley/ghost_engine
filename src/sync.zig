const std = @import("std");
const vsa = @import("vsa_core.zig");
const builtin = @import("builtin");

/// Sovereign Portable Mutex: Zero-CPU wait through OS-native interrupts.
/// Direct implementation of the WaitOnAddress (Windows) / futex (Linux)
/// abstraction to ensure absolute portability across the Sovereign Fleet.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            switch (builtin.os.tag) {
                .windows => {
                    const windows = std.os.windows;
                    _ = windows.ntdll.RtlWaitOnAddress(&self.state.raw, &@as(u32, 1), 4, null);
                },
                .linux => {
                    const linux = std.os.linux;
                    _ = linux.futex_4arg(&self.state.raw, .{ .cmd = .WAIT, .private = true }, 1, null);
                },
                else => std.Thread.yield() catch {},
            }
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
        switch (builtin.os.tag) {
            .windows => {
                const windows = std.os.windows;
                windows.ntdll.RtlWakeAddressSingle(&self.state.raw);
            },
            .linux => {
                const linux = std.os.linux;
                _ = linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
            },
            else => {},
        }
    }
};

/// Sovereign Portable Condition Variable.
pub const Condition = struct {
    state: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const current = self.state.load(.monotonic);
        mutex.unlock();
        switch (builtin.os.tag) {
            .windows => {
                const windows = std.os.windows;
                _ = windows.ntdll.RtlWaitOnAddress(&self.state.raw, &current, 4, null);
            },
            .linux => {
                const linux = std.os.linux;
                _ = linux.futex_4arg(&self.state.raw, .{ .cmd = .WAIT, .private = true }, current, null);
            },
            else => std.Thread.yield() catch {},
        }
        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        _ = self.state.fetchAdd(1, .release);
        switch (builtin.os.tag) {
            .windows => {
                const windows = std.os.windows;
                windows.ntdll.RtlWakeAddressSingle(&self.state.raw);
            },
            .linux => {
                const linux = std.os.linux;
                _ = linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
            },
            else => {},
        }
    }

    pub fn broadcast(self: *Condition) void {
        _ = self.state.fetchAdd(1, .release);
        switch (builtin.os.tag) {
            .windows => {
                const windows = std.os.windows;
                windows.ntdll.RtlWakeAddressAll(&self.state.raw);
            },
            .linux => {
                const linux = std.os.linux;
                _ = linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
            },
            else => {},
        }
    }
};

/// Bounded multi-producer, single-consumer queue backed by a contiguous
/// compile-time ring buffer. We intentionally do not use a linked list here:
/// pointer chasing destroys locality, introduces allocator pressure, and is a
/// bad fit for the Ghost shell's hot path.
pub fn LockFreeQueue(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity < 2) @compileError("LockFreeQueue capacity must be at least 2");
        if (!std.math.isPowerOfTwo(capacity)) {
            @compileError("LockFreeQueue capacity must be a power of two");
        }
    }

    return struct {
        const Self = @This();
        const cache_line_size = 64;
        const mask = capacity - 1;

        const Slot = struct {
            sequence: std.atomic.Value(usize),
            value: T,
        };

        slots: [capacity]Slot = initSlots(),
        // Producers hammer `head`; keep it off the consumer's cache line.
        head: std.atomic.Value(usize) align(cache_line_size) = std.atomic.Value(usize).init(0),
        _head_padding: [cache_line_size - @sizeOf(std.atomic.Value(usize))]u8 =
            [_]u8{0} ** (cache_line_size - @sizeOf(std.atomic.Value(usize))),
        // The single consumer owns `tail`; isolate it to avoid false sharing.
        tail: std.atomic.Value(usize) align(cache_line_size) = std.atomic.Value(usize).init(0),
        shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub const PushError = error{ QueueFull, QueueStopped };

        fn initSlots() [capacity]Slot {
            var slots: [capacity]Slot = undefined;
            inline for (0..capacity) |i| {
                slots[i] = .{
                    .sequence = std.atomic.Value(usize).init(i),
                    .value = undefined,
                };
            }
            return slots;
        }

        fn signedDistance(a: usize, b: usize) isize {
            return @as(isize, @bitCast(a -% b));
        }

        pub fn push(self: *Self, item: T) PushError!void {
            if (self.shutting_down.load(.acquire)) return error.QueueStopped;

            var head = self.head.load(.monotonic);
            var slot: *Slot = undefined;

            while (true) {
                slot = &self.slots[head & mask];
                const sequence = slot.sequence.load(.acquire);
                const distance = signedDistance(sequence, head);

                if (distance == 0) {
                    if (self.head.cmpxchgWeak(head, head +% 1, .monotonic, .monotonic)) |observed| {
                        head = observed;
                        std.atomic.spinLoopHint();
                        continue;
                    }
                    break;
                }

                if (distance < 0) return error.QueueFull;

                head = self.head.load(.monotonic);
                std.atomic.spinLoopHint();
            }

            slot.value = item;
            // Publish the fully written slot to the consumer.
            slot.sequence.store(head +% 1, .release);
        }

        pub fn pop(self: *Self) ?T {
            var tail = self.tail.load(.monotonic);

            while (true) {
                const slot = &self.slots[tail & mask];
                const sequence = slot.sequence.load(.acquire);
                const distance = signedDistance(sequence, tail +% 1);

                if (distance == 0) {
                    const item = slot.value;
                    self.tail.store(tail +% 1, .release);
                    // Release the slot back to producers for the next wrap.
                    slot.sequence.store(tail +% capacity, .release);
                    return item;
                }

                if (distance < 0) return null;

                tail = self.tail.load(.monotonic);
                std.atomic.spinLoopHint();
            }
        }

        pub fn shutdown(self: *Self) void {
            self.shutting_down.store(true, .release);
        }

        pub fn isShutdown(self: *const Self) bool {
            return self.shutting_down.load(.acquire);
        }
    };
}

/// Multi-Producer Single-Consumer (MPSC) Lock-Free State Queue
/// Uses a Power-of-Two Ring Buffer with bitwise masking for high-performance
/// non-blocking state updates from background threads.
pub const StateQueue = struct {
    const Slot = struct {
        rune: u32,
        vector: vsa.HyperVector,
        /// Sentinel to ensure the consumer doesn't read a partially written slot
        written: std.atomic.Value(bool),
    };

    buffer: []Slot,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    mask: usize,
    mutex: Mutex = .{},
    cond: Condition = .{},

    pub fn init(allocator: std.mem.Allocator, requested_cap: usize) !StateQueue {
        // Force capacity to the next power of two for bitwise masking
        const cap = std.math.ceilPowerOfTwo(usize, @max(requested_cap, 2)) catch return error.CapacityTooLarge;
        const buf = try allocator.alloc(Slot, cap);

        for (buf) |*slot| {
            slot.written = std.atomic.Value(bool).init(false);
        }

        return .{
            .buffer = buf,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .mask = cap - 1,
        };
    }

    pub fn deinit(self: *StateQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    /// Producer: Push a state diff (Rune + HyperVector)
    /// Returns false if the queue is full.
    pub fn push(self: *StateQueue, rune: u32, vector: vsa.HyperVector) bool {
        var t = self.tail.load(.monotonic);
        while (true) {
            const h = self.head.load(.acquire);

            // Full check: If tail has wrapped around and caught up to head
            if (t -% h > self.mask) return false;

            // Atomically claim the slot
            t = self.tail.cmpxchgWeak(t, t +% 1, .monotonic, .monotonic) orelse break;
        }

        const idx = t & self.mask;
        const slot = &self.buffer[idx];

        // V33: Wait on the condition if the consumer is still reading this specific slot.
        // This is extremely rare in MPSC but prevents CPU spin on saturation.
        if (slot.written.load(.acquire)) {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (slot.written.load(.acquire)) {
                self.cond.wait(&self.mutex);
            }
        }

        slot.rune = rune;
        slot.vector = vector;

        // Signal that the data is ready for consumption
        slot.written.store(true, .release);
        self.cond.signal();

        return true;
    }

    pub const PopResult = struct { rune: u32, vector: vsa.HyperVector };

    /// Consumer: Pop a state diff
    /// Returns null if the queue is empty.
    pub fn pop(self: *StateQueue) ?PopResult {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);

        if (h == t) return null; // Empty

        const idx = h & self.mask;
        const slot = &self.buffer[idx];

        // Ensure producer has finished writing via the 'written' sentinel.
        // V33: Non-blocking check. If not ready, return null so the main loop
        // can continue its other tasks.
        if (!slot.written.load(.acquire)) return null;

        const res = PopResult{ .rune = slot.rune, .vector = slot.vector };

        // Mark slot as empty before advancing head
        slot.written.store(false, .release);
        _ = self.head.fetchAdd(1, .release);
        self.cond.broadcast(); // Wake any producers waiting on slot space

        return res;
    }
};

test "LockFreeQueue rejects full queues and wraps cleanly" {
    const Queue = LockFreeQueue(u32, 4);
    var queue = Queue{};

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    try queue.push(4);
    try std.testing.expectError(error.QueueFull, queue.push(5));

    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());

    try queue.push(5);
    try queue.push(6);

    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, 4), queue.pop());
    try std.testing.expectEqual(@as(?u32, 5), queue.pop());
    try std.testing.expectEqual(@as(?u32, 6), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "LockFreeQueue supports concurrent producers" {
    const Queue = LockFreeQueue(u32, 64);
    const Producer = struct {
        queue: *Queue,
        base: u32,

        fn run(self: *@This()) void {
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                while (true) {
                    self.queue.push(self.base + i) catch |err| switch (err) {
                        error.QueueFull => {
                            std.atomic.spinLoopHint();
                            std.Thread.yield() catch {};
                            continue;
                        },
                        error.QueueStopped => unreachable,
                    };
                    break;
                }
            }
        }
    };

    var queue = Queue{};
    var producers = [_]Producer{
        .{ .queue = &queue, .base = 0 },
        .{ .queue = &queue, .base = 16 },
        .{ .queue = &queue, .base = 32 },
        .{ .queue = &queue, .base = 48 },
    };
    var threads: [producers.len]std.Thread = undefined;
    for (&threads, &producers) |*thread, *producer| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
    }

    var seen = [_]bool{false} ** 64;
    var received: usize = 0;
    while (received < seen.len) {
        if (queue.pop()) |value| {
            try std.testing.expect(!seen[value]);
            seen[value] = true;
            received += 1;
            continue;
        }

        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }

    for (threads) |thread| thread.join();
}
