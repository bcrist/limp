const std = @import("std");
const assert = std.debug.assert;

pub const SxParser = struct {
    alloc: std.mem.Allocator,
    source: []u8,
    remaining: []const u8,
    state: State,
    quoted: bool,
    next_val: []const u8,
    start_of_token: []const u8,
    start_of_line: []const u8,
    line_number: usize,
    temp: std.ArrayListUnmanaged(u8),

    const State = enum(u8) {
        unknown = 0,
        open = 1,
        close = 2,
        val = 3,
        eof = 4
    };

    pub fn init(source: []const u8, alloc: std.mem.Allocator) !SxParser {
        const source_copy = try alloc.dupe(u8, source);
        return SxParser {
            .alloc = alloc,
            .source = source_copy,
            .remaining = source_copy,
            .state = .unknown,
            .quoted = false,
            .next_val = &[_]u8{},
            .start_of_token = source,
            .start_of_line = source,
            .line_number = 1,
            .temp = std.ArrayListUnmanaged(u8) {},
        };
    }

    pub fn deinit(self: *SxParser) void {
        self.temp.deinit(self.alloc);
        self.alloc.free(self.source);
    }

    fn skip_ws(self: *SxParser) void {
        var remaining = self.remaining;
        for (remaining) |c, i| {
            if (c == '\n') {
                self.line_number += 1;
                self.start_of_line = remaining[i+1..];
            } else if (c > ' ') {
                self.remaining = remaining[i..];
                return;
            }
        }
        self.remaining = remaining[remaining.len..];
    }

    fn read_unquoted_val(self: *SxParser) void {
        var remaining = self.remaining;
        for (remaining) |c, i| {
            if (c <= ' ' or c == '(' or c == ')' or c == '"') {
                self.quoted = false;
                self.next_val = remaining[0..i];
                self.remaining = remaining[i..];
                return;
            }
        }
        self.quoted = false;
        self.next_val = remaining;
        self.remaining = remaining[remaining.len..];
    }

    fn read_quoted_val(self: *SxParser) !void {
        assert(self.remaining[0] == '"');
        var remaining = self.remaining[1..];
        var in_escape = false;
        var use_temp = false;
        var end = remaining.len;
        self.temp.clearRetainingCapacity();
        for (remaining) |c, i| {
            if (in_escape) {
                assert(use_temp);
                var ch = c;
                switch (c) {
                    't' => ch = '\t',
                    'n' => ch = '\n',
                    'r' => ch = '\r',
                    else => {},
                }
                try self.temp.append(self.alloc, ch);
                in_escape = false;
            } else switch (c) {
                '\\' => {
                    if (!use_temp) {
                        try self.temp.appendSlice(self.alloc, remaining[0..i]);
                        use_temp = true;
                    }
                    in_escape = true;
                },
                '"' => {
                    end = i + 1;
                    break;
                },
                else => if (use_temp) {
                    try self.temp.append(self.alloc, c);
                },
            }
        }

        if (use_temp) {
            self.next_val = self.temp.items;
        } else {
            self.next_val = remaining[0..end];
            if (end != remaining.len) {
                self.next_val.len -= 1;
            }
        }

        self.remaining = remaining[end..];
        self.quoted = true;
    }

    fn read(self: *SxParser) !void {
        self.skip_ws();

        var remaining = self.remaining;
        self.start_of_token = remaining;

        if (remaining.len == 0) {
            self.state = .eof;
            return;
        }

        switch (self.remaining[0]) {
            '(' => {
                self.remaining = remaining[1..];
                self.skip_ws();
                if (self.remaining.len > 0 and self.remaining[0] == '"') {
                    try self.read_quoted_val();
                } else {
                    self.read_unquoted_val();
                }
                self.state = .open;
            },
            ')' => {
                self.remaining = remaining[1..];
                self.state = .close;
            },
            '"' => {
                try self.read_quoted_val();
                self.state = .val;
            },
            else => {
                self.read_unquoted_val();
                self.state = .val;
            },
        }
    }

    pub fn open(self: *SxParser) !bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open) {
            if (self.quoted or self.next_val.len > 0) {
                self.state = .val;
            } else {
                self.state = .unknown;
            }
            return true;
        } else {
            return false;
        }
    }

    pub fn close(self: *SxParser) !bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .close) {
            self.state = .unknown;
            return true;
        } else {
            return false;
        }
    }

    pub fn done(self: *SxParser) !bool {
        if (self.state == .unknown) {
            try self.read();
        }

        return self.state == .eof;
    }

    pub fn expression(self: *SxParser, expected: []const u8) !bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open and std.mem.eql(u8, self.next_val, expected)) {
            self.state = .unknown;
            return true;
        } else {
            return false;
        }
    }

    pub fn requireExpression(self: *SxParser, expected: []const u8) !void {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open and std.mem.eql(u8, self.next_val, expected)) {
            self.state = .unknown;
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn anyExpression(self: *SxParser) !?[]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open) {
            self.state = .unknown;
            return self.next_val;
        } else {
            return null;
        }
    }

    pub fn requireAnyExpression(self: *SxParser) ![]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open) {
            self.state = .unknown;
            return self.next_val;
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn string(self: *SxParser, expected: []const u8) !bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val and std.mem.eql(u8, self.next_val, expected)) {
            self.state = .unknown;
            return true;
        } else {
            return false;
        }
    }

    pub fn requireString(self: *SxParser, expected: []const u8) !void {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val and std.mem.eql(u8, self.next_val, expected)) {
            self.state = .unknown;
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn anyString(self: *SxParser) !?[]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val) {
            self.state = .unknown;
            return self.next_val;
        } else {
            return null;
        }
    }

    pub fn requireAnyString(self: *SxParser) ![]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val) {
            self.state = .unknown;
            return self.next_val;
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn anyFloat(self: *SxParser, comptime T: type) !?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        var value = std.fmt.parseFloat(T, self.next_val) catch return null;
        self.state = .unknown;
        return value;
    }
    pub fn requireAnyFloat(self: *SxParser, comptime T: type) !T {
        return self.anyFloat(T) orelse error.SExpressionSyntaxError;
    }

    pub fn anyInt(self: *SxParser, comptime T: type, radix: u8) !?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        var value = std.fmt.parseInt(T, self.next_val, radix) catch return null;
        self.state = .unknown;
        return value;
    }
    pub fn requireAnyInt(self: *SxParser, comptime T: type, radix: u8) !T {
        return self.anyInt(T, radix) orelse error.SExpressionSyntaxError;
    }

    pub fn anyUnsigned(self: *SxParser, comptime T: type, radix: u8) !?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        var value = std.fmt.parseUnsigned(T, self.next_val, radix) catch return null;
        self.state = .unknown;
        return value;
    }
    pub fn requireAnyUnsigned(self: *SxParser, comptime T: type, radix: u8) !T {
        return self.anyUnsigned(T, radix) orelse error.SExpressionSyntaxError;
    }

    // note this consumes the current expression's closing parenthesis
    pub fn ignoreRemainingExpression(self: *SxParser) !void {
        var depth: usize = 1;
        while (self.state != .eof and depth > 0) {
            if (self.state == .unknown) {
                try self.read();
            }
            
            if (self.state == .close) {
                depth -= 1;
            } else if (self.state == .open) {
                depth += 1;
            }
            self.state = .unknown;
        }
    }

    pub fn printParseErrorContext(self: *SxParser) !void {
        var line = self.start_of_line;
        
        for (line) |c, i| {
            if (c == '\n') {
                line = line[0..i];
                break;
            }
        }

        var highlight = try self.alloc.dupe(u8, line);
        defer self.alloc.free(highlight);

        var pad_amount = @ptrToInt(self.start_of_token.ptr) - @ptrToInt(self.start_of_line.ptr);

        std.mem.set(u8, highlight[0..pad_amount], ' ');
        

        var token_length = @ptrToInt(self.remaining.ptr) - @ptrToInt(self.start_of_token.ptr);

        std.mem.set(u8, highlight[pad_amount..pad_amount + token_length], '^');

        var stderr = std.io.getStdErr().writer();
        try stderr.print("{:>4}: {s}\n", .{ self.line_number, line });
        try stderr.print("      {s}\n", .{ highlight });
    }

};


pub fn SxWriter(comptime Writer: type) type {
    return struct {
        inner: Writer,
        indent: []const u8,
        compact_state: std.ArrayList(bool),
        first_in_group: bool,

        const Self = @This();

        pub fn init(writer: Writer, allocator: std.mem.Allocator) Self {
            return .{
                .inner = writer,
                .indent = "   ",
                .compact_state = std.ArrayList(bool).init(allocator),
                .first_in_group = true,
            };
        }

        fn spacing(self: *Self) !void {
            const cs = self.compact_state;
            if (cs.items.len > 0 and cs.items[cs.items.len - 1]) {
                if (self.first_in_group) {
                    self.first_in_group = false;
                } else {
                    try self.inner.writeByte(' ');
                }
            } else {
                if (self.first_in_group) {
                    self.first_in_group = false;
                }
                try self.inner.writeByte('\n');
                for (self.compact_state.items) |_| {
                    _ = try self.inner.write(self.indent);
                }
            }
        }

        pub fn open(self: *Self) !void {
            try self.spacing();
            try self.inner.writeByte('(');
            try self.compact_state.append(true);
            self.first_in_group = true;
        }

        pub fn openExpanded(self: *Self) !void {
            try self.spacing();
            try self.inner.writeByte('(');
            try self.compact_state.append(false);
            self.first_in_group = true;
        }

        pub fn close(self: *Self) !bool {
            if (self.compact_state.items.len > 0) {
                if (!self.compact_state.pop() and !self.first_in_group) {
                    try self.inner.writeByte('\n');
                    for (self.compact_state.items) |_| {
                        _ = try self.inner.write(self.indent);
                    }
                }
                try self.inner.writeByte(')');
                self.first_in_group = false;
                return true;
            } else {
                self.first_in_group = false;
                return false;
            }
        }

        pub fn done(self: *Self) !void {
            while (try self.close()) {}
        }

        pub fn setCompact(self: *Self, compact: bool) void {
            if (self.compact_state.items.len > 0) {
                self.compact_state.items[self.compact_state.items.len - 1] = compact;
            }
        }

        pub fn expression(self: *Self, name: []const u8) !void {
            try self.open();
            try self.string(name);
        }

        pub fn expressionExpanded(self: *Self, name: []const u8) !void {
            try self.open();
            try self.string(name);
            self.setCompact(false);
        }

        fn requiresQuotes(str: []const u8) bool {
            for (str) |c| {
                if (c <= ' ' or c > '~' or c == '(' or c == ')' or c == '"') {
                    return true;
                }
            }
            return false;
        }

        pub fn string(self: *Self, str: []const u8) !void {
            try self.spacing();
            if (requiresQuotes(str)) {
                try self.inner.writeByte('"');
                for (str) |c| {
                    if (c == '"' or c == '\\') {
                        try self.inner.writeByte('\\');
                        try self.inner.writeByte(c);
                    } else if (c < ' ') {
                        if (c == '\n') {
                            _ = try self.inner.write("\\n");
                        } else if (c == '\r') {
                            _ = try self.inner.write("\\r");
                        } else if (c == '\t') {
                            _ = try self.inner.write("\\t");
                        } else {
                            try self.inner.writeByte(c);
                        }
                    } else {
                        // TODO be greedy to reduce number of small fwrite calls
                        try self.inner.writeByte(c);
                    }
                }
                try self.inner.writeByte('"');
            } else {
                _ = try self.inner.write(str);
            }
        }

        pub fn value(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.spacing();
            try self.inner.print(format, args);
        }

    };
}

pub fn sxWriter(writer: anytype, allocator: std.mem.Allocator) SxWriter(@TypeOf(writer)) {
    return SxWriter(@TypeOf(writer)).init(writer, allocator);
}
