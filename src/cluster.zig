const std = @import("std");
const sys = @import("sys.zig");
const ghost_state = @import("ghost_state.zig");

// ── Ghost Engine V29: Myelin Sync Cluster Protocol ──
// Lightweight UDP protocol for broadcasting myelinated facts across nodes.
// When a concept reaches the 10,000-count threshold (MSB flip), the node
// broadcasts a compact packet so all peers can immediately harden the same slot.
//
// Design constraints:
//   - Zero-copy: packets are small enough for a single UDP datagram
//   - Lossy-safe: duplicate or dropped packets are harmless (idempotent MSB set)
//   - NAT-friendly: uses broadcast on LAN, configurable for unicast/multicast
//   - Cross-platform: uses Zig's std.net (POSIX + Windows via ws2_32)

pub const CLUSTER_MAGIC: u16 = 0x4748; // "GH" in little-endian
pub const CLUSTER_VERSION: u8 = 1;
pub const DEFAULT_PORT: u16 = 47470; // "GHOST" on a phone keypad = 44678, but we use 47470

// ── Packet Types ──
pub const PacketType = enum(u8) {
    myelin_lock = 0x01, // A slot has been myelinated (MSB set)
    heartbeat = 0x02, // Periodic liveness probe
    lattice_lock = 0x03, // A lattice entry has saturated (MSB set on u16)
    gossip_hash = 0x04, // Rolling checksum gossip to detect desync
};

// ── Saturation Sync Packet (16 bytes, fixed) ──
// Broadcast when a MeaningMatrix accumulator crosses the saturation threshold.
// The receiver flips the MSB on its local copy without needing any data transfer.
pub const MyelinPacket = extern struct {
    magic: u16 = CLUSTER_MAGIC, // [0..1]  Protocol identifier
    version: u8 = CLUSTER_VERSION, // [2]     Version tag
    ptype: u8 = @intFromEnum(PacketType.myelin_lock), // [3] Packet type
    slot_index: u32 = 0, // [4..7]  Which MeaningMatrix slot was locked
    tag_hash: u64 = 0, // [8..15] The FNV-1a tag of the concept that was locked

    pub fn validate(self: *const MyelinPacket) bool {
        return self.magic == CLUSTER_MAGIC and self.version == CLUSTER_VERSION;
    }
};

// ── Gossip Hash Packet (16 bytes, fixed) ──
pub const GossipPacket = extern struct {
    magic: u16 = CLUSTER_MAGIC,
    version: u8 = CLUSTER_VERSION,
    ptype: u8 = @intFromEnum(PacketType.gossip_hash),
    node_id: u32 = 0, // V29.1: Prevents self-echoing
    slot_index: u32 = 0,
    slot_hash: u64 = 0, // slot_hash starts at offset 8, making GossipPacket 16 bytes

    pub fn validate(self: *const GossipPacket) bool {
        return self.magic == CLUSTER_MAGIC and self.version == CLUSTER_VERSION;
    }
};

// ── Heartbeat Packet (16 bytes, fixed) ──
pub const HeartbeatPacket = extern struct {
    magic: u16 = CLUSTER_MAGIC,
    version: u8 = CLUSTER_VERSION,
    ptype: u8 = @intFromEnum(PacketType.heartbeat),
    node_id: u32 = 0, // [4..7]  Random node identifier
    uptime_sec: u32 = 0, // [8..11] Seconds since node boot
    tcp_port: u16 = 0, // [12..13] V29.1: Explicit sync listener port
    _pad: u16 = 0, // [14..15] Alignment padding

    pub fn validate(self: *const HeartbeatPacket) bool {
        return self.magic == CLUSTER_MAGIC and self.version == CLUSTER_VERSION;
    }
};

// ── Lattice Lock Packet (16 bytes, fixed) ──
pub const LatticeLockPacket = extern struct {
    magic: u16 = CLUSTER_MAGIC,
    version: u8 = CLUSTER_VERSION,
    ptype: u8 = @intFromEnum(PacketType.lattice_lock),
    entry_index: u32 = 0, // [4..7]  Which lattice u16 entry was locked
    lock_value: u16 = 0, // [8..9]  The value with MSB set
    _pad: [6]u8 = [_]u8{0} ** 6, // [10..15] Alignment padding

    pub fn validate(self: *const LatticeLockPacket) bool {
        return self.magic == CLUSTER_MAGIC and self.version == CLUSTER_VERSION;
    }
};

// Ensure all packets are exactly 16 bytes
comptime {
    if (@sizeOf(MyelinPacket) != 16) @compileError("MyelinPacket must be 16 bytes");
    if (@sizeOf(HeartbeatPacket) != 16) @compileError("HeartbeatPacket must be 16 bytes");
    if (@sizeOf(LatticeLockPacket) != 16) @compileError("LatticeLockPacket must be 16 bytes");
    if (@sizeOf(GossipPacket) != 16) @compileError("GossipPacket must be 16 bytes");
}

// ── Peer Info ──
pub const PeerInfo = struct {
    node_id: u32,
    address: std.net.Address,
    tcp_port: u16,
    last_seen: u64,
};

// ── Cluster Stats (lockless counters) ──
pub const ClusterStats = struct {
    packets_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    myelin_locks_applied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lattice_locks_applied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    heartbeats_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peers_seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_error: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

// ── Cluster Node ──
// The main clustering engine. Manages a UDP socket, a listener thread,
// and provides broadcast methods for the trainer to call.
pub const ClusterNode = struct {
    // Socket + Networking
    socket: ?std.posix.socket_t = null,
    bind_port: u16,
    broadcast_addr: std.net.Address,
    is_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Listener thread
    listener_thread: ?std.Thread = null,
    gossip_thread: ?std.Thread = null,
    tcp_thread: ?std.Thread = null,
    tcp_server_socket: ?std.posix.socket_t = null,

    // Node identity (random at boot, for heartbeat dedup)
    node_id: u32,

    // Pointers to the trainer's live data structures (set during attach)
    meaning_matrix_data: ?[]u32 = null,
    meaning_matrix_tags: ?[]u64 = null,
    lattice_data: ?[*]u16 = null,
    lattice_entries: u32 = 0,
    matrix_slots: u32 = 0,

    // Peer tracking
    peers: [64]?PeerInfo = [_]?PeerInfo{null} ** 64,
    peer_count: u32 = 0,

    // Stats
    stats: ClusterStats = .{},

    // Boot time for heartbeat uptime calculation
    boot_tick: u64 = 0,

    allocator: std.mem.Allocator,

    /// Initialize the cluster node. Does NOT start the listener yet.
    /// Call `start()` after attaching data pointers.
    pub fn init(allocator: std.mem.Allocator, bind_port: u16, broadcast_ip: []const u8) !ClusterNode {
        // Generate a random node ID using the system tick and address entropy
        const tick = sys.getMilliTick();
        const node_id = @as(u32, @truncate(ghost_state.wyhash(tick, 0xDEADBEEF_CAFEBABE)));

        // Parse the broadcast target address
        const broadcast_addr = try parseAddress(broadcast_ip, bind_port);

        return ClusterNode{
            .bind_port = bind_port,
            .broadcast_addr = broadcast_addr,
            .node_id = node_id,
            .boot_tick = tick,
            .allocator = allocator,
        };
    }

    /// Attach the trainer's live data structures.
    /// MUST be called before start() so the listener can apply incoming locks.
    pub fn attach(
        self: *ClusterNode,
        matrix_data: []u32,
        matrix_tags: ?[]u64,
        lattice_ptr: ?[*]u16,
        lattice_entry_count: u32,
        slot_count: u32,
    ) void {
        self.meaning_matrix_data = matrix_data;
        self.meaning_matrix_tags = matrix_tags;
        self.lattice_data = lattice_ptr;
        self.lattice_entries = lattice_entry_count;
        self.matrix_slots = slot_count;
        sys.print("[CLUSTER] Data attached: {d} matrix slots, {d} lattice entries\n", .{ slot_count, lattice_entry_count });
    }

    /// Start the cluster: bind the UDP socket and spawn the listener thread.
    pub fn start(self: *ClusterNode) !void {
        if (self.is_active.load(.acquire)) return;

        // Create UDP socket
        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        );
        errdefer std.posix.close(sock);

        // Enable broadcast
        const broadcast_enable: u32 = 1;
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&broadcast_enable));

        // Enable address reuse so multiple nodes can run on same machine (testing)
        const reuse_enable: u32 = 1;
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse_enable));

        // Bind to the port on all interfaces
        const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.bind_port);
        try std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

        // Set receive timeout to 500ms so the listener can check the stop flag
        const timeout = std.posix.timeval{
            .sec = 0,
            .usec = 500_000,
        };
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        self.socket = sock;
        self.is_active.store(true, .release);

        sys.print("[CLUSTER] Node {X:0>8} listening on port {d}\n", .{ self.node_id, self.bind_port });
        sys.print("[CLUSTER] Broadcast target: {}\n", .{self.broadcast_addr});

        // Spawn listener thread
        self.listener_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, listenerMain, .{self});

        // ── Start TCP Server for Explicit Sync ──
        const tcp_sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        try std.posix.setsockopt(tcp_sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse_enable));
        try std.posix.bind(tcp_sock, &bind_addr.any, bind_addr.getOsSockLen());
        try std.posix.listen(tcp_sock, 128);
        self.tcp_server_socket = tcp_sock;
        self.tcp_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, tcpServerMain, .{self});

        // ── Start Gossip Thread ──
        self.gossip_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, gossipThreadMain, .{self});

        // Send initial heartbeat to announce presence
        self.broadcastHeartbeat();
    }

    /// Stop the cluster: signal the listener, join the thread, close the socket.
    pub fn stop(self: *ClusterNode) void {
        if (!self.is_active.load(.acquire)) return;

        self.is_active.store(false, .release);

        if (self.tcp_server_socket) |sock| {
            std.posix.close(sock);
            self.tcp_server_socket = null;
        }

        if (self.socket) |sock| {
            std.posix.close(sock);
            self.socket = null;
        }

        if (self.tcp_thread) |t| {
            t.join();
            self.tcp_thread = null;
        }

        if (self.gossip_thread) |t| {
            t.join();
            self.gossip_thread = null;
        }

        if (self.listener_thread) |t| {
            t.join();
            self.listener_thread = null;
        }

        sys.print("[CLUSTER] Node {X:0>8} shut down. Sent: {d} | Received: {d} | Locks applied: {d}\n", .{
            self.node_id,
            self.stats.packets_sent.load(.acquire),
            self.stats.packets_received.load(.acquire),
            self.stats.myelin_locks_applied.load(.acquire) + self.stats.lattice_locks_applied.load(.acquire),
        });
    }

    // ── Broadcast Methods (called by trainer) ──

    /// Broadcast a myelin lock event: slot `slot_index` with tag `tag_hash`
    /// has reached the 10,000 threshold and is now permanently etched.
    pub fn broadcastMyelinLock(self: *ClusterNode, slot_index: u32, tag_hash: u64) void {
        if (!self.is_active.load(.acquire)) return;
        const sock = self.socket orelse return;

        const packet = MyelinPacket{
            .slot_index = slot_index,
            .tag_hash = tag_hash,
        };

        const bytes = std.mem.asBytes(&packet);
        _ = std.posix.sendto(sock, bytes, 0, &self.broadcast_addr.any, self.broadcast_addr.getOsSockLen()) catch {
            _ = self.stats.last_error.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.stats.packets_sent.fetchAdd(1, .monotonic);
    }

    /// Broadcast a lattice lock event.
    pub fn broadcastLatticeLock(self: *ClusterNode, entry_index: u32, lock_value: u16) void {
        if (!self.is_active.load(.acquire)) return;
        const sock = self.socket orelse return;

        const packet = LatticeLockPacket{
            .entry_index = entry_index,
            .lock_value = lock_value,
        };

        const bytes = std.mem.asBytes(&packet);
        _ = std.posix.sendto(sock, bytes, 0, &self.broadcast_addr.any, self.broadcast_addr.getOsSockLen()) catch {
            _ = self.stats.last_error.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.stats.packets_sent.fetchAdd(1, .monotonic);
    }

    /// Broadcast a heartbeat packet.
    pub fn broadcastHeartbeat(self: *ClusterNode) void {
        if (!self.is_active.load(.acquire)) return;
        const sock = self.socket orelse return;

        const now = sys.getMilliTick();
        const uptime_sec = @as(u32, @intCast((now - self.boot_tick) / 1000));

        const packet = HeartbeatPacket{
            .node_id = self.node_id,
            .uptime_sec = uptime_sec,
            .tcp_port = self.bind_port,
        };

        const bytes = std.mem.asBytes(&packet);
        _ = std.posix.sendto(sock, bytes, 0, &self.broadcast_addr.any, self.broadcast_addr.getOsSockLen()) catch {
            _ = self.stats.last_error.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.stats.packets_sent.fetchAdd(1, .monotonic);
    }

    // ── Batch Myelin Scanner ──
    // Called by the trainer after each GPU etch to detect newly myelinated slots.
    // Scans a range of the matrix and broadcasts any slots that have the MSB set
    // but haven't been broadcast yet. Uses a simple bitmap to track sent state.

    /// Scan the meaning matrix for newly saturated counters and broadcast them.
    /// `start_slot` and `end_slot` define the scan window (for chunked operation).
    /// Returns the number of newly detected saturation events.
    pub fn scanAndBroadcastSaturationLocks(self: *ClusterNode, start_slot: u32, end_slot: u32) u32 {
        const data = self.meaning_matrix_data orelse return 0;
        const tags = self.meaning_matrix_tags orelse return 0;
        const max_slot = @min(end_slot, self.matrix_slots);
        var count: u32 = 0;

        var slot: u32 = start_slot;
        while (slot < max_slot) : (slot += 1) {
            const tag = tags[slot];
            if (tag == 0) continue; // Empty slot

            // Check if ANY counter in this slot has MSB set (the 10,000 threshold lock)
            const base = @as(usize, slot) * 1024;
            const end_idx = base + 1024;
            if (end_idx > data.len) break;

            // Sample a few counters per slot for efficiency (full scan is 1024 per slot)
            // We check indices 0, 256, 512, 768 as sentinels
            const sentinels = [_]usize{ 0, 256, 512, 768 };
            var has_myelin = false;
            for (sentinels) |offset| {
                if ((data[base + offset] & 0x80000000) != 0) {
                    has_myelin = true;
                    break;
                }
            }

            if (has_myelin) {
                self.broadcastMyelinLock(slot, tag);
                count += 1;
            }
        }

        return count;
    }

    // ── Listener Thread ──

    fn listenerMain(self: *ClusterNode) void {
        var recv_buf: [64]u8 = undefined;
        var heartbeat_timer: u64 = sys.getMilliTick();

        while (self.is_active.load(.acquire)) {
            const sock = self.socket orelse break;

            // Try to receive a packet (non-blocking with timeout)
            var src_addr: std.posix.sockaddr = undefined;
            var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const recv_result = std.posix.recvfrom(sock, &recv_buf, 0, &src_addr, &src_len);
            if (recv_result) |n| {
                if (n >= 4) {
                    self.handlePacket(recv_buf[0..n], src_addr);
                }
            } else |_| {
                // Timeout or error — that's fine, just continue the loop
            }

            // Send periodic heartbeats every 10 seconds
            const now = sys.getMilliTick();
            if (now - heartbeat_timer >= 10_000) {
                self.broadcastHeartbeat();
                heartbeat_timer = now;
            }
        }
    }

    fn handlePacket(self: *ClusterNode, raw: []const u8, src_addr: std.posix.sockaddr) void {
        if (raw.len < 4) return;

        // Validate magic
        const magic = std.mem.readInt(u16, raw[0..2], .little);
        if (magic != CLUSTER_MAGIC) return;

        const version = raw[2];
        if (version != CLUSTER_VERSION) return;

        _ = self.stats.packets_received.fetchAdd(1, .monotonic);

        const ptype = raw[3];
        switch (ptype) {
            @intFromEnum(PacketType.myelin_lock) => {
                if (raw.len < @sizeOf(MyelinPacket)) return;
                const pkt: *const MyelinPacket = @ptrCast(@alignCast(raw.ptr));
                self.applyMyelinLock(pkt);
            },
            @intFromEnum(PacketType.heartbeat) => {
                if (raw.len < @sizeOf(HeartbeatPacket)) return;
                const pkt: *const HeartbeatPacket = @ptrCast(@alignCast(raw.ptr));
                if (pkt.node_id == self.node_id) return; // V29.1: Skip self
                self.handleHeartbeat(pkt, src_addr);
            },
            @intFromEnum(PacketType.lattice_lock) => {
                if (raw.len < @sizeOf(LatticeLockPacket)) return;
                const pkt: *const LatticeLockPacket = @ptrCast(@alignCast(raw.ptr));
                self.applyLatticeLock(pkt);
            },
            @intFromEnum(PacketType.gossip_hash) => {
                if (raw.len < @sizeOf(GossipPacket)) return;
                const pkt: *const GossipPacket = @ptrCast(@alignCast(raw.ptr));
                if (pkt.node_id == self.node_id) return; // V29.1: Skip self
                self.handleGossipHash(pkt);
            },
            else => {
                // Unknown packet type — ignore silently
            },
        }
    }

    fn tcpServerMain(self: *ClusterNode) void {
        const srv = self.tcp_server_socket orelse return;
        while (self.is_active.load(.acquire)) {
            var client_addr: std.posix.sockaddr = undefined;
            var client_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const client_fd = std.posix.accept(srv, &client_addr, &client_len, 0) catch |err| {
                if (err == error.SocketNotListening or err == error.FileDescriptorBad or err == error.ConnectionAborted) break;
                continue; // Ignore transient errors
            };

            // Handle request inline (simple blocking logic, fine for slow background sync)
            var req_buf: [4]u8 = undefined;
            const n = std.posix.recv(client_fd, &req_buf, 0) catch 0;
            if (n == 4) {
                const slot_index = std.mem.readInt(u32, &req_buf, .little);
                if (self.meaning_matrix_data) |data| {
                    if (slot_index < self.matrix_slots) {
                        const base = @as(usize, slot_index) * 1024;
                        const end = base + 1024;
                        if (end <= data.len) {
                            const bytes = std.mem.sliceAsBytes(data[base..end]);
                            _ = std.posix.send(client_fd, bytes, 0) catch {};
                        }
                    }
                }
            }
            std.posix.close(client_fd);
        }
    }

    fn gossipThreadMain(self: *ClusterNode) void {
        var current_slot: u32 = 0;
        while (self.is_active.load(.acquire)) {
            // V29.1: Increased gossip rate (10ms wait = 100 slots/sec)
            sys.sleep(10);
            const slots = self.matrix_slots;
            if (slots == 0) continue;

            const data = self.meaning_matrix_data orelse continue;

            current_slot = (current_slot + 1) % slots;
            const base = @as(usize, current_slot) * 1024;
            const end = base + 1024;
            if (end > data.len) continue;

            const bytes = std.mem.sliceAsBytes(data[base..end]);
            const hash = ghost_state.wyhash(0, @as(u64, @truncate(std.hash.Wyhash.hash(0, bytes))));

            const packet = GossipPacket{
                .node_id = self.node_id,
                .slot_index = current_slot,
                .slot_hash = hash,
            };
            const pbytes = std.mem.asBytes(&packet);
            const sock = self.socket orelse continue;
            _ = std.posix.sendto(sock, pbytes, 0, &self.broadcast_addr.any, self.broadcast_addr.getOsSockLen()) catch {};
        }
    }

    fn handleGossipHash(self: *ClusterNode, pkt: *const GossipPacket) void {
        if (pkt.slot_index >= self.matrix_slots) return;
        const data = self.meaning_matrix_data orelse return;

        const base = @as(usize, pkt.slot_index) * 1024;
        const end = base + 1024;
        if (end > data.len) return;

        const bytes = std.mem.sliceAsBytes(data[base..end]);
        const local_hash = ghost_state.wyhash(0, @as(u64, @truncate(std.hash.Wyhash.hash(0, bytes))));

        if (local_hash != pkt.slot_hash) {
            // V29.1: Find the peer info to get the correct TCP port
            var peer: ?PeerInfo = null;
            for (self.peers[0..self.peer_count]) |p_opt| {
                if (p_opt) |p| {
                    if (p.node_id == pkt.node_id) {
                        peer = p;
                        break;
                    }
                }
            }

            const p = peer orelse return; // Can't sync if we haven't seen a heartbeat yet

            sys.print("[GOSSIP] Hash mismatch on slot {d} with node {X:0>8}! Syncing via TCP port {d}...\n", .{ pkt.slot_index, p.node_id, p.tcp_port });

            // Connect back via TCP to pull the exact slot
            const tcp_sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return;
            defer std.posix.close(tcp_sock);

            // Connect using the peer's reported TCP port
            var sync_addr = p.address;
            sync_addr.setPort(p.tcp_port);

            // Timeouts for TCP sync
            const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
            _ = std.posix.setsockopt(tcp_sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
            _ = std.posix.setsockopt(tcp_sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

            std.posix.connect(tcp_sock, &sync_addr.any, sync_addr.getOsSockLen()) catch {
                sys.print("[GOSSIP] Failed to connect to peer for sync.\n", .{});
                return;
            };

            var req_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &req_buf, pkt.slot_index, .little);
            _ = std.posix.send(tcp_sock, &req_buf, 0) catch return;

            var received: usize = 0;
            while (received < 4096) {
                const n = std.posix.recv(tcp_sock, bytes[received..], 0) catch 0;
                if (n == 0) break;
                received += n;
            }
            if (received == 4096) {
                sys.print("[GOSSIP] Successfully synced slot {d} via TCP.\n", .{pkt.slot_index});
            } else {
                sys.print("[GOSSIP] Sync failed: received {d}/4096 bytes.\n", .{received});
            }
        }
    }

    fn applyMyelinLock(self: *ClusterNode, pkt: *const MyelinPacket) void {
        const data = self.meaning_matrix_data orelse return;
        const tags = self.meaning_matrix_tags orelse return;

        if (pkt.slot_index >= self.matrix_slots) return;

        // Verify the tag matches (prevents cross-talk from nodes with different data)
        const local_tag = tags[pkt.slot_index];
        if (local_tag != 0 and local_tag != pkt.tag_hash) {
            // Tag mismatch — this node has different data in this slot.
            // Attempt to find the correct slot by tag_hash via double-hashing probe.
            const num_slots = self.matrix_slots;
            const base_idx = @as(u32, @truncate(pkt.tag_hash)) % num_slots;
            const stride = @as(u32, @intCast((pkt.tag_hash >> 32) | 1));
            var p: u32 = 0;
            while (p < 8) : (p += 1) {
                const slot = (base_idx + p *% stride) % num_slots;
                if (tags[slot] == pkt.tag_hash) {
                    // Found it — apply MSB lock to all 1024 counters in this slot
                    self.lockSlot(data, slot);
                    _ = self.stats.myelin_locks_applied.fetchAdd(1, .monotonic);
                    return;
                }
                if (tags[slot] == 0) return; // Tag doesn't exist locally — nothing to lock
            }
            return;
        }

        // Direct slot match — apply MSB lock
        self.lockSlot(data, pkt.slot_index);
        _ = self.stats.myelin_locks_applied.fetchAdd(1, .monotonic);
    }

    fn lockSlot(self: *ClusterNode, data: []u32, slot: u32) void {
        _ = self;
        const base = @as(usize, slot) * 1024;
        const end = base + 1024;
        if (end > data.len) return;

        // Set MSB on all counters in this slot that are above a minimum threshold.
        // We don't blindly lock zero counters — only counters that already have signal.
        for (data[base..end]) |*counter| {
            const val = counter.*;
            if (val >= 100 and (val & 0x80000000) == 0) {
                counter.* = val | 0x80000000;
            }
        }
    }

    fn applyLatticeLock(self: *ClusterNode, pkt: *const LatticeLockPacket) void {
        const lattice = self.lattice_data orelse return;
        if (pkt.entry_index >= self.lattice_entries) return;

        // Apply MSB lock to the lattice entry (u16, MSB = 0x8000)
        const current = lattice[pkt.entry_index];
        if (current < 0x8000 and pkt.lock_value >= 0x8000) {
            lattice[pkt.entry_index] = pkt.lock_value;
            _ = self.stats.lattice_locks_applied.fetchAdd(1, .monotonic);
        }
    }

    fn handleHeartbeat(self: *ClusterNode, pkt: *const HeartbeatPacket, src_addr: std.posix.sockaddr) void {
        _ = self.stats.heartbeats_received.fetchAdd(1, .monotonic);

        var addr = std.net.Address{ .any = src_addr };

        // V29.1: Track or update peer info
        for (0..self.peer_count) |i| {
            if (self.peers[i]) |*p| {
                if (p.node_id == pkt.node_id) {
                    p.last_seen = sys.getMilliTick();
                    p.tcp_port = pkt.tcp_port;
                    p.address = addr;
                    return;
                }
            }
        }

        if (self.peer_count < 64) {
            self.peers[self.peer_count] = PeerInfo{
                .node_id = pkt.node_id,
                .address = addr,
                .tcp_port = pkt.tcp_port,
                .last_seen = sys.getMilliTick(),
            };
            self.peer_count += 1;
            _ = self.stats.peers_seen.store(self.peer_count, .release);
            sys.print("[CLUSTER] New peer detected: {X:0>8} (Uptime: {d}s, TCP Port: {d})\n", .{
                pkt.node_id,
                pkt.uptime_sec,
                pkt.tcp_port,
            });
        }
    }

    // ── Reporting ──

    pub fn printStatus(self: *const ClusterNode) void {
        sys.print("[CLUSTER] Node {X:0>8} | Peers: {d} | Sent: {d} | Recv: {d} | M-Locks: {d} | L-Locks: {d}\n", .{
            self.node_id,
            self.stats.peers_seen.load(.acquire),
            self.stats.packets_sent.load(.acquire),
            self.stats.packets_received.load(.acquire),
            self.stats.myelin_locks_applied.load(.acquire),
            self.stats.lattice_locks_applied.load(.acquire),
        });
    }
};

// ── Address Parsing ──
fn parseAddress(ip: []const u8, port: u16) !std.net.Address {
    // Parse dotted quad like "255.255.255.255" or "192.168.1.255"
    var octets: [4]u8 = .{ 255, 255, 255, 255 }; // Default: broadcast
    var octet_idx: usize = 0;
    var current: u16 = 0;
    var has_digits = false;

    for (ip) |ch| {
        if (ch == '.') {
            if (!has_digits) return error.InvalidAddress;
            if (current > 255) return error.InvalidAddress;
            if (octet_idx >= 4) return error.InvalidAddress;
            octets[octet_idx] = @intCast(current);
            octet_idx += 1;
            current = 0;
            has_digits = false;
        } else if (ch >= '0' and ch <= '9') {
            current = current * 10 + (ch - '0');
            has_digits = true;
        } else {
            return error.InvalidAddress;
        }
    }

    if (has_digits and octet_idx < 4) {
        if (current > 255) return error.InvalidAddress;
        octets[octet_idx] = @intCast(current);
    }

    return std.net.Address.initIp4(octets, port);
}
