const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const engine_logic = @import("engine.zig");
const sync = @import("sync.zig");

pub const SovereignSurveillance = struct {
    allocator: std.mem.Allocator,
    soul: *ghost_state.GhostSoul,
    meaning: *vsa.MeaningMatrix,
    lattice: *ghost_state.UnifiedLattice,
    queue: *sync.StateQueue,

    pub fn init(allocator: std.mem.Allocator, soul: *ghost_state.GhostSoul, meaning: *vsa.MeaningMatrix, lattice: *ghost_state.UnifiedLattice, queue: *sync.StateQueue) SovereignSurveillance {
        return .{
            .allocator = allocator,
            .soul = soul,
            .meaning = meaning,
            .lattice = lattice,
            .queue = queue,
        };
    }

    pub fn startBridge(self: *SovereignSurveillance) !void {
        if (sys.createNamedPipe) |createPipe| {
            const pipe_name = "\\\\.\\pipe\\ghost_koryphaios";
            const hPipe = try createPipe(pipe_name);
            sys.print("[BRIDGE] Koryphaios Bridge online at {s}\n", .{pipe_name});

            while (true) {
                if (sys.connectNamedPipe) |connectPipe| {
                    try connectPipe(hPipe);
                    self.handleClient(hPipe) catch |err| {
                        sys.print("[BRIDGE] Client disconnected or error: {any}\n", .{err});
                    };
                    if (sys.disconnectNamedPipe) |disconnectPipe| {
                        disconnectPipe(hPipe);
                    }
                } else break;
            }
        }
    }

    fn handleClient(self: *SovereignSurveillance, hPipe: sys.FileHandle) !void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const read = try sys.os_layer.readAll(hPipe, &buf);
            if (read == 0) break;

            const cmd = std.mem.trim(u8, buf[0..read], " \r\n");
            if (std.mem.startsWith(u8, cmd, "QUERY")) {
                // Command format: QUERY <lex_rotor_hex> <sem_rotor_hex>
                var iter = std.mem.splitSequence(u8, cmd, " ");
                _ = iter.next(); // "QUERY"
                const lex_hex = iter.next() orelse continue;
                const sem_hex = iter.next() orelse continue;
                
                const lex = std.fmt.parseInt(u64, lex_hex, 16) catch 0;
                const sem = std.fmt.parseInt(u64, sem_hex, 16) catch 0;

                const target_lex = self.meaning.collapseToBinary(lex);
                const target_sem = self.meaning.collapseToBinary(sem);

                var best_cp: u32 = ' ';
                var best_energy: u32 = 0;

                for (0..0x1_0000) |cp_usize| {
                    const cp: u32 = @intCast(cp_usize);
                    if (!engine_logic.isAllowed(cp)) continue;
                    const v = vsa.generate(cp);
                    const e_lex = vsa.calculateResonance(target_lex, v);
                    const e_sem = vsa.calculateResonance(target_sem, v);
                    const energy = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem;
                    if (energy > best_energy) {
                        best_energy = energy;
                        best_cp = cp;
                    }
                }

                var resp_buf: [128]u8 = undefined;
                const resp = try std.fmt.bufPrint(&resp_buf, "RESONANCE {x} {d}\n", .{best_cp, best_energy});
                _ = try sys.os_layer.writeAll(hPipe, resp);
            } else if (std.mem.startsWith(u8, cmd, "ETCH")) {
                const content = cmd[5..];
                for (content) |b| {
                    _ = self.queue.push(@intCast(b), vsa.generate(b));
                }
                _ = try sys.os_layer.writeAll(hPipe, "OK\n");
            }
        }
    }

};
