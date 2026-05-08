const std = @import("std");

pub const ContextTurn = struct {
    role: []const u8,
    text: []const u8,
};

pub const ContextWindow = struct {
    turns: std.ArrayList(ContextTurn),
    allocator: std.mem.Allocator,
    max_turns: usize = 5,

    pub fn init(allocator: std.mem.Allocator) ContextWindow {
        return .{
            .turns = std.ArrayList(ContextTurn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ContextWindow) void {
        for (self.turns.items) |turn| {
            self.allocator.free(turn.role);
            self.allocator.free(turn.text);
        }
        self.turns.deinit();
    }

    pub fn push(self: *ContextWindow, role: []const u8, text: []const u8) !void {
        if (self.turns.items.len >= self.max_turns) {
            const old = self.turns.orderedRemove(0);
            self.allocator.free(old.role);
            self.allocator.free(old.text);
        }
        try self.turns.append(.{
            .role = try self.allocator.dupe(u8, role),
            .text = try self.allocator.dupe(u8, text),
        });
    }

    pub fn buildBlock(self: *ContextWindow, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        for (self.turns.items) |turn| {
            try out.writer().print("{s}: {s}\n", .{ turn.role, turn.text });
        }
        return out.toOwnedSlice();
    }
};
