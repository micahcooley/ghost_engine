const std = @import("std");

pub const MAX_CONSTRAINTS: usize = 16;

pub const Intent = enum {
    OPTIMIZE,
    SECURE,
    VERIFY,
    REFACTOR,
};

pub const GCLCommand = struct {
    intent: Intent,
    target: []const u8,
    constraints: [MAX_CONSTRAINTS][]const u8,
    constraint_count: usize,
};

pub const ParseError = error{
    InvalidSyntax,
    InvalidIntent,
    MissingTarget,
    MissingConstraint,
    TooManyConstraints,
};

const Parser = struct {
    input: []const u8,
    pos: usize = 0,

    fn parseCommand(self: *Parser) ParseError!GCLCommand {
        try self.expectLiteral("GCL: ");
        const intent = try self.parseIntent();
        try self.expectLiteral("(");
        const target = try self.parseTarget();
        try self.expectLiteral(")");

        var command = GCLCommand{
            .intent = intent,
            .target = target,
            .constraints = undefined,
            .constraint_count = 0,
        };

        if (self.atEnd()) return command;

        try self.expectLiteral(" WITH ");
        try self.parseConstraintList(&command);
        if (!self.atEnd()) return error.InvalidSyntax;
        return command;
    }

    fn parseIntent(self: *Parser) ParseError!Intent {
        if (self.consumeLiteral("OPTIMIZE")) return .OPTIMIZE;
        if (self.consumeLiteral("SECURE")) return .SECURE;
        if (self.consumeLiteral("VERIFY")) return .VERIFY;
        if (self.consumeLiteral("REFACTOR")) return .REFACTOR;
        return error.InvalidIntent;
    }

    fn parseTarget(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (!self.atEnd() and self.peek() != ')') : (self.pos += 1) {
            if (!isTargetByte(self.peek())) return error.InvalidSyntax;
        }
        if (self.pos == start) return error.MissingTarget;
        return self.input[start..self.pos];
    }

    fn parseConstraintList(self: *Parser, command: *GCLCommand) ParseError!void {
        try self.parseConstraint(command);
        if (self.atEnd()) return;
        if (self.consumeLiteral(" AND ")) {
            return self.parseConstraintList(command);
        }
    }

    fn parseConstraint(self: *Parser, command: *GCLCommand) ParseError!void {
        if (command.constraint_count == MAX_CONSTRAINTS) return error.TooManyConstraints;

        const start = self.pos;
        while (!self.atEnd() and !self.startsWith(" AND ")) : (self.pos += 1) {
            if (!isConstraintByte(self.peek())) return error.InvalidSyntax;
        }
        if (self.pos == start) return error.MissingConstraint;
        if (std.ascii.isWhitespace(self.input[start]) or std.ascii.isWhitespace(self.input[self.pos - 1])) return error.InvalidSyntax;

        command.constraints[command.constraint_count] = self.input[start..self.pos];
        command.constraint_count += 1;
    }

    fn expectLiteral(self: *Parser, literal: []const u8) ParseError!void {
        if (!self.consumeLiteral(literal)) return error.InvalidSyntax;
    }

    fn consumeLiteral(self: *Parser, literal: []const u8) bool {
        if (!self.startsWith(literal)) return false;
        self.pos += literal.len;
        return true;
    }

    fn startsWith(self: Parser, literal: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], literal);
    }

    fn peek(self: Parser) u8 {
        return self.input[self.pos];
    }

    fn atEnd(self: Parser) bool {
        return self.pos == self.input.len;
    }
};

pub fn parse(input: []const u8) !GCLCommand {
    var parser = Parser{ .input = input };
    return parser.parseCommand();
}

fn isTargetByte(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', '/', '\\', ':', '@' => true,
        else => false,
    };
}

fn isConstraintByte(byte: u8) bool {
    return switch (byte) {
        0...31, 127 => false,
        else => true,
    };
}

test "parse accepts valid command without constraints" {
    const input = "GCL: VERIFY(src/compiler/gip_parser.zig)";
    const command = try parse(input);

    try std.testing.expectEqual(Intent.VERIFY, command.intent);
    try std.testing.expectEqualStrings(input["GCL: VERIFY(".len .. input.len - 1], command.target);
    try std.testing.expectEqual(@as(usize, 0), command.constraint_count);
}

test "parse accepts valid command with constraints" {
    const input = "GCL: SECURE(src/gip_cli.zig) WITH no heap allocation AND deterministic output";
    const command = try parse(input);

    try std.testing.expectEqual(Intent.SECURE, command.intent);
    try std.testing.expectEqualStrings("src/gip_cli.zig", command.target);
    try std.testing.expectEqual(@as(usize, 2), command.constraint_count);
    try std.testing.expectEqualStrings("no heap allocation", command.constraints[0]);
    try std.testing.expectEqualStrings("deterministic output", command.constraints[1]);
}

test "parse returns slices into original input" {
    const input = "GCL: OPTIMIZE(module_name) WITH bounded stack";
    const command = try parse(input);

    try std.testing.expectEqual(input.ptr + "GCL: OPTIMIZE(".len, command.target.ptr);
    try std.testing.expectEqual(input.ptr + "GCL: OPTIMIZE(module_name) WITH ".len, command.constraints[0].ptr);
}

test "parse rejects missing GCL prefix" {
    try std.testing.expectError(error.InvalidSyntax, parse("VERIFY(src/main.zig)"));
}

test "parse rejects invalid intent" {
    try std.testing.expectError(error.InvalidIntent, parse("GCL: PATCH(src/main.zig)"));
}

test "parse rejects missing target" {
    try std.testing.expectError(error.MissingTarget, parse("GCL: VERIFY()"));
}

test "parse rejects malformed separators" {
    try std.testing.expectError(error.InvalidSyntax, parse("GCL: VERIFY(src/main.zig) WITH alpha  AND beta"));
    try std.testing.expectError(error.InvalidSyntax, parse("GCL: VERIFY (src/main.zig)"));
}

test "parse rejects missing constraint" {
    try std.testing.expectError(error.MissingConstraint, parse("GCL: VERIFY(src/main.zig) WITH "));
    try std.testing.expectError(error.MissingConstraint, parse("GCL: VERIFY(src/main.zig) WITH alpha AND "));
}

test "parse accepts exactly sixteen constraints" {
    const input =
        "GCL: REFACTOR(src/main.zig) WITH c01 AND c02 AND c03 AND c04 AND " ++
        "c05 AND c06 AND c07 AND c08 AND c09 AND c10 AND c11 AND c12 AND " ++
        "c13 AND c14 AND c15 AND c16";
    const command = try parse(input);

    try std.testing.expectEqual(@as(usize, MAX_CONSTRAINTS), command.constraint_count);
    try std.testing.expectEqualStrings("c01", command.constraints[0]);
    try std.testing.expectEqualStrings("c16", command.constraints[15]);
}

test "parse rejects seventeenth constraint" {
    const input =
        "GCL: REFACTOR(src/main.zig) WITH c01 AND c02 AND c03 AND c04 AND " ++
        "c05 AND c06 AND c07 AND c08 AND c09 AND c10 AND c11 AND c12 AND " ++
        "c13 AND c14 AND c15 AND c16 AND c17";

    try std.testing.expectError(error.TooManyConstraints, parse(input));
}
