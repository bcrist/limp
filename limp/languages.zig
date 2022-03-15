const std = @import("std");
const allocators = @import("allocators.zig");

pub const LangTokens = struct {
    opener: []const u8,
    closer: []const u8,
    line_prefix: []const u8,

    fn init(opener: []const u8, closer: []const u8, line_prefix: []const u8) LangTokens {
        return LangTokens{
            .opener = opener,
            .closer = closer,
            .line_prefix = line_prefix,
        };
    }
};

pub var langs = std.StringHashMap(LangTokens).init(allocators.global_arena.allocator());

pub fn getLimp() LangTokens {
    return langs.get("!!") orelse LangTokens.init("!!", "!!", "");
}

pub fn get(extension: []const u8) LangTokens {
    return langs.get(extension) orelse langs.get("") orelse LangTokens.init("/*", "*/", "");
}

pub fn initDefaults() !void {
    try langs.ensureTotalCapacity(64);

    const c_tokens = LangTokens.init("/*", "*/", "");
    try langs.put("", c_tokens);
    try langs.put("c", c_tokens);
    try langs.put("h", c_tokens);
    try langs.put("cc", c_tokens);
    try langs.put("hh", c_tokens);
    try langs.put("cpp", c_tokens);
    try langs.put("hpp", c_tokens);
    try langs.put("jai", c_tokens);
    try langs.put("java", c_tokens);
    try langs.put("kt", c_tokens);
    try langs.put("cs", c_tokens);

    const sgml_tokens = LangTokens.init("<!--", "-->", "");
    try langs.put("xml", sgml_tokens);
    try langs.put("htm", sgml_tokens);
    try langs.put("html", sgml_tokens);

    try langs.put("zig", LangTokens.init("//[[", "]]", "//"));
    try langs.put("bat", LangTokens.init(":::", ":::", "::"));
    try langs.put("cmd", LangTokens.init(":::", ":::", "::"));
    try langs.put("sh", LangTokens.init("##", "##", "#"));
    try langs.put("ninja", LangTokens.init("##", "##", "#"));
    try langs.put("lua", LangTokens.init("--[==[", "]==]", ""));
    try langs.put("sql", LangTokens.init("---", "---", "--"));

    try langs.put("!!", LangTokens.init("!!", "!!", ""));
}

pub fn add(extension: []const u8, opener: []const u8, closer: []const u8, line_prefix: []const u8) !void {
    if (opener.len == 0 or closer.len == 0) return error.InvalidToken;

    var alloc = allocators.global_arena.allocator();
    var extension_copy = try alloc.dupe(u8, extension);
    var opener_copy = try alloc.dupe(u8, opener);
    var closer_copy = try alloc.dupe(u8, closer);
    var line_prefix_copy = try alloc.dupe(u8, line_prefix);

    try langs.put(extension_copy, .{
        .opener = opener_copy,
        .closer = closer_copy,
        .line_prefix = line_prefix_copy,
    });
}

const Parser = struct {
    allocator: std.mem.Allocator,
    extension: std.ArrayListUnmanaged(u8),
    opener: std.ArrayListUnmanaged(u8),
    closer: std.ArrayListUnmanaged(u8),
    prefix: std.ArrayListUnmanaged(u8),
    line: std.ArrayListUnmanaged(u8),
    state: State = State.extension,
    error_on_line: bool = false,
    verbose: bool = false,
    line_num: u32 = 1,

    fn init(temp_arena: *std.heap.ArenaAllocator, verbose: bool) !Parser {
        var allocator = temp_arena.allocator();
        return Parser{
            .allocator = allocator,
            .extension = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 16),
            .opener = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 16),
            .closer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 16),
            .prefix = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 16),
            .line = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 256),
            .verbose = verbose,
        };
    }

    const State = enum(u8) {
        extension,
        whitespace_before_opener,
        opener,
        whitespace_before_closer,
        closer,
        whitespace_before_prefix,
        prefix,
        whitespace_trailing,
        comment_or_error,
    };

    fn accept(self: *Parser, c: u8) !void {
        if (c == '\n') {
            try self.checkAndAdd();
            self.extension.clearRetainingCapacity();
            self.opener.clearRetainingCapacity();
            self.closer.clearRetainingCapacity();
            self.prefix.clearRetainingCapacity();
            self.line.clearRetainingCapacity();
            self.state = State.extension;
            self.error_on_line = false;
            self.line_num += 1;
        } else {
            try self.line.append(self.allocator, c);
            while (true) {
                switch (self.state) {
                    State.whitespace_before_opener => {
                        if (c <= ' ') break;
                        self.state = State.opener;
                        continue;
                    },
                    State.whitespace_before_closer => {
                        if (c <= ' ') break;
                        self.state = State.closer;
                        continue;
                    },
                    State.whitespace_before_prefix => {
                        if (c <= ' ') break;
                        self.state = State.prefix;
                        continue;
                    },
                    State.whitespace_trailing => {
                        if (c <= ' ') break;
                        self.state = State.comment_or_error;
                        self.error_on_line = true;
                        try std.io.getStdErr().writer().print(".limplangs:{d}: Too many tokens; expected <extension> <opener> <closer>: ", .{self.line_num});
                        break;
                    },
                    State.extension => {
                        if (c <= ' ') {
                            self.state = State.whitespace_before_opener;
                            break;
                        } else if (c == '#' and self.isStartOfLine()) {
                            self.state = State.comment_or_error;
                            break;
                        }
                        try self.extension.append(self.allocator, c);
                        break;
                    },
                    State.opener => {
                        if (c <= ' ') {
                            self.state = State.whitespace_before_closer;
                            break;
                        }
                        try self.opener.append(self.allocator, c);
                        break;
                    },
                    State.closer => {
                        if (c <= ' ') {
                            self.state = State.whitespace_before_prefix;
                            break;
                        }
                        try self.closer.append(self.allocator, c);
                        break;
                    },
                    State.prefix => {
                        if (c <= ' ') {
                            self.state = State.whitespace_trailing;
                            break;
                        }
                        try self.prefix.append(self.allocator, c);
                        break;
                    },
                    State.comment_or_error => {
                        break;
                    },
                }
                unreachable;
            }
        }
    }

    fn checkAndAdd(self: *Parser) !void {
        if (self.isStartOfLine()) {
            return;
        }

        if (!self.error_on_line) {
            if (self.closer.items.len == 0) {
                try std.io.getStdErr().writer().print(".limplangs:{d}: Too few tokens; expected <extension> <opener> <closer> [line-prefix]: ", .{self.line_num});
                self.error_on_line = true;
            }
        }

        if (self.error_on_line) {
            try std.io.getStdErr().writer().print("{s}\n", .{self.line.items});
        } else {
            if (self.verbose) {
                try std.io.getStdOut().writer().print("Loaded language tokens for .{s} files: {s} {s}\n", .{ self.extension.items, self.opener.items, self.closer.items });
            }
            try add(self.extension.items, self.opener.items, self.closer.items, self.prefix.items);
        }
    }

    inline fn isStartOfLine(self: *Parser) bool {
        return self.state == State.extension and self.extension.items.len == 0;
    }
};

pub fn load(verbose: bool) !void {
    var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer temp_arena.deinit();

    const exe_dir_path = try std.fs.selfExeDirPathAlloc(temp_arena.allocator());
    var exe_dir = try std.fs.cwd().openDir(exe_dir_path, .{});
    defer exe_dir.close();

    var limplangs_contents = exe_dir.readFileAlloc(temp_arena.allocator(), ".limplangs", 1 << 30) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var parser = try Parser.init(&temp_arena, verbose);
    for (limplangs_contents) |b| try parser.accept(b);
    try parser.checkAndAdd();
}
