const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");
const globals = @import("globals.zig");
const temp_alloc = globals.temp_arena.allocator();
const languages = @import("languages.zig");
const lua = @import("lua.zig");

//[[!! quiet() fs.put_file_contents('limp.bc.lua', string.dump(load_file('limp.lua'))) !! 1 ]]
const limp_core = @embedFile("limp.bc.lua");

pub const Section = struct {
    text: []const u8 = &[_]u8{},
    indent: []const u8 = &[_]u8{},
    newline_style: []const u8 = &[_]u8{},
    limp_header: []const u8 = &[_]u8{},
    raw_program: []const u8 = &[_]u8{},
    clean_program: []const u8 = &[_]u8{},
    limp_footer: []const u8 = &[_]u8{},
    limp_output: []const u8 = &[_]u8{},
};

pub const ProcessResult = enum(u8) {
    up_to_date,
    modified,
    ignore,
};

pub const Processor = struct {
    comment_tokens: languages.LangTokens,
    limp_tokens: languages.LangTokens,
    file_path: []const u8,
    file_contents: []const u8,
    parsed_sections: std.ArrayListUnmanaged(Section),
    processed_sections: std.ArrayListUnmanaged(Section),

    pub fn init(comment_tokens: languages.LangTokens, limp_tokens: languages.LangTokens) Processor {
        return Processor{
            .comment_tokens = comment_tokens,
            .limp_tokens = limp_tokens,
            .file_path = &[_]u8{},
            .file_contents = &[_]u8{},
            .parsed_sections = std.ArrayListUnmanaged(Section){},
            .processed_sections = std.ArrayListUnmanaged(Section){},
        };
    }

    fn countNewlines(buf: []const u8) u64 {
        var newline_count: u64 = 0;
        var search_start_loc: usize = 0;

        while (std.mem.indexOfAnyPos(u8, buf, search_start_loc, "\r\n")) |end_of_line| {
            if (std.mem.startsWith(u8, buf[end_of_line..], "\r\n")) {
                search_start_loc = end_of_line + 2;
            } else {
                search_start_loc = end_of_line + 1;
            }
            newline_count += 1;
        }

        return newline_count;
    }

    fn detectFileNewlineStyle(file_contents: []const u8) []const u8 {
        const min_lines_to_examine = 50;

        var search_start_loc: usize = 0;

        var num_cr: usize = 0;
        var num_lf: usize = 0;
        var num_crlf: usize = 0;

        while (true) {
            if (std.mem.indexOfAnyPos(u8, file_contents, search_start_loc, "\r\n")) |end_of_line| {
                if (std.mem.startsWith(u8, file_contents[end_of_line..], "\r\n")) {
                    search_start_loc = end_of_line + 2;
                    num_crlf += 1;
                    if (num_crlf > min_lines_to_examine) {
                        return "\r\n";
                    }
                } else if (file_contents[end_of_line] == '\n') {
                    search_start_loc = end_of_line + 1;
                    num_lf += 1;
                    if (num_lf > min_lines_to_examine) {
                        return "\n";
                    }
                } else {
                    search_start_loc = end_of_line + 1;
                    num_cr += 1;
                    if (num_cr > min_lines_to_examine) {
                        return "\n";
                    }
                }
            } else {
                if (num_lf == 0 and num_cr == 0 and num_crlf == 0) {
                    return if (builtin.os.tag == .windows) "\r\n" else "\n";
                } else if (num_lf >= num_cr) {
                    if (num_lf >= num_crlf) {
                        return "\n";
                    } else {
                        return "\r\n";
                    }
                } else if (num_crlf >= num_cr) {
                    return "\r\n";
                } else {
                    return "\r";
                }
            }
        }
    }

    fn detectNewlineStyleAndIndent(section: *Section, file_newline_style: []const u8) void {
        if (std.mem.lastIndexOfAny(u8, section.text, "\r\n")) |end_of_line| {
            if (section.text[end_of_line] == '\n') {
                if (end_of_line > 0 and section.text[end_of_line - 1] == '\r') {
                    section.newline_style = "\r\n";
                } else {
                    section.newline_style = "\n";
                }
            } else {
                section.newline_style = "\r";
            }
            section.indent = section.text[end_of_line + 1 ..];
        } else {
            section.newline_style = file_newline_style;
            section.indent = section.text;
        }
    }

    fn parseRawProgram(section: *Section, newlines_seen: u64, full_line_prefix: []const u8) !u64 {
        var raw_program = section.raw_program;
        var remaining = try temp_alloc.alloc(u8, raw_program.len + newlines_seen * section.newline_style.len);
        section.clean_program = remaining;

        const newline_style = section.newline_style;

        { // add newlines at the beginning so that lua will report the right line number
            var line: i64 = 0;
            while (line < newlines_seen) {
                @memcpy(remaining.ptr, newline_style);
                remaining = remaining[newline_style.len..];
                line += 1;
            }
        }

        var program_newlines: u64 = 0;

        while (std.mem.indexOfAny(u8, raw_program, "\r\n")) |end_of_line| {
            var start_of_line: usize = undefined;
            if (std.mem.startsWith(u8, raw_program[end_of_line..], "\r\n")) {
                start_of_line = end_of_line + 2;
            } else {
                start_of_line = end_of_line + 1;
            }

            @memcpy(remaining.ptr, raw_program[0..start_of_line]);
            remaining = remaining[start_of_line..];

            program_newlines += 1;

            raw_program = raw_program[start_of_line..];
            if (section.indent.len == 0 or std.mem.startsWith(u8, raw_program, section.indent)) {
                if (std.mem.startsWith(u8, raw_program[section.indent.len..], full_line_prefix)) {
                    raw_program = raw_program[(section.indent.len + full_line_prefix.len)..];
                }
            }
        }

        @memcpy(remaining.ptr, raw_program);
        remaining = remaining[raw_program.len..];

        section.clean_program = section.clean_program[0 .. section.clean_program.len - remaining.len];

        return program_newlines;
    }

    pub fn parse(self: *Processor, file_path: []const u8, file_contents: []const u8) !void {
        self.file_path = file_path;
        self.file_contents = file_contents;

        const file_newline_style = detectFileNewlineStyle(file_contents);

        const comment_opener = self.comment_tokens.opener;
        const comment_closer = self.comment_tokens.closer;
        const comment_line_prefix = self.comment_tokens.line_prefix;

        const limp_opener = self.limp_tokens.opener;
        const limp_closer = self.limp_tokens.closer;
        const limp_line_prefix = self.limp_tokens.line_prefix;

        var limp_header = try temp_alloc.alloc(u8, comment_opener.len + limp_opener.len);
        @memcpy(limp_header.ptr, comment_opener);
        @memcpy(limp_header[comment_opener.len..].ptr, limp_opener);

        var full_line_prefix = try temp_alloc.alloc(u8, comment_line_prefix.len + limp_line_prefix.len);
        @memcpy(full_line_prefix.ptr, comment_line_prefix);
        @memcpy(full_line_prefix[comment_line_prefix.len..].ptr, limp_line_prefix);

        var initial_bytes_of_closers = [2]u8{ limp_closer[0], comment_closer[0] };

        var newlines_seen: u64 = 0;
        var remaining = file_contents;
        while (std.mem.indexOf(u8, remaining, limp_header)) |opener_loc| {
            var section = Section{};
            section.text = remaining[0..opener_loc];
            newlines_seen += countNewlines(section.text);
            detectNewlineStyleAndIndent(&section, file_newline_style);
            section.limp_header = limp_header;

            if (root.option_very_verbose) {
                const offset = @intFromPtr(remaining.ptr) - @intFromPtr(file_contents.ptr) + opener_loc;
                root.stdout.print("{s}:{}: Found LIMP header at offset {}.\n", .{ self.file_path, newlines_seen, offset }) catch {};
                root.stdout.flush() catch {};
            }

            // find the end of the limp program, and parse the number of generated lines (if present)
            var closer_search_loc = opener_loc + limp_header.len;
            while (std.mem.indexOfAnyPos(u8, remaining, closer_search_loc, &initial_bytes_of_closers)) |potential_closer_loc| {
                const potential_closer = remaining[potential_closer_loc..];
                if (std.mem.startsWith(u8, potential_closer, limp_closer)) {
                    // next up should be the number of generated lines
                    const limp_closer_loc = potential_closer_loc;
                    const limp_closer_len = limp_closer.len;
                    section.raw_program = remaining[opener_loc + limp_header.len .. limp_closer_loc];
                    newlines_seen += try parseRawProgram(&section, newlines_seen, full_line_prefix);

                    if (std.mem.indexOfPos(u8, remaining, limp_closer_loc + limp_closer_len, comment_closer)) |closer_loc| {
                        const output_loc = closer_loc + comment_closer.len;
                        const line_count_loc = limp_closer_loc + limp_closer.len;
                        const line_count_str_raw = remaining[line_count_loc..closer_loc];

                        newlines_seen += countNewlines(line_count_str_raw);

                        const line_count_str = std.mem.trim(u8, line_count_str_raw, &std.ascii.whitespace);
                        var lines_remaining = std.fmt.parseUnsigned(u64, line_count_str, 0) catch 0; // TODO error message

                        newlines_seen += lines_remaining;

                        var end_loc = output_loc;
                        while (lines_remaining > 0) : (lines_remaining -= 1) {
                            if (std.mem.indexOfAnyPos(u8, remaining, end_loc, "\r\n")) |end_of_line| {
                                if (std.mem.startsWith(u8, remaining[end_of_line..], "\r\n")) {
                                    end_loc = end_of_line + 2;
                                } else {
                                    end_loc = end_of_line + 1;
                                }
                            }
                            if (end_loc >= remaining.len) break;
                        }

                        section.limp_footer = remaining[limp_closer_loc..output_loc];
                        section.limp_output = remaining[output_loc..end_loc];

                        remaining = remaining[end_loc..];
                    } else {
                        // EOF before closer was found - file truncation or corruption?
                        section.limp_footer = remaining[limp_closer_loc..];
                        remaining = "";
                    }
                    break;
                } else if (std.mem.startsWith(u8, potential_closer, comment_closer)) {
                    // there are no generated lines
                    const closer_loc = potential_closer_loc;
                    const closer_len = comment_closer.len;
                    section.raw_program = remaining[opener_loc + limp_header.len .. closer_loc];
                    newlines_seen += try parseRawProgram(&section, newlines_seen, full_line_prefix);
                    section.limp_footer = remaining[closer_loc .. closer_loc + closer_len];
                    remaining = remaining[closer_loc + closer_len ..];
                    break;
                } else {
                    closer_search_loc = potential_closer_loc + 1;
                }
            } else {
                if (!root.option_quiet) {
                    root.stderr.print("{s}: Found EOF before end of LIMP; possible file truncation?\n", .{ self.file_path, }) catch {};
                    root.stderr.flush() catch {};
                }
                section.raw_program = remaining[opener_loc + limp_header.len ..];
                newlines_seen += try parseRawProgram(&section, newlines_seen, full_line_prefix);
                remaining = "";
            }

            try self.parsed_sections.append(temp_alloc, section);
        }

        if (remaining.len > 0) {
            try self.parsed_sections.append(temp_alloc, .{ .text = remaining });
        }
    }

    pub fn isProcessable(self: *Processor) bool {
        switch (self.parsed_sections.items.len) {
            0 => return false,
            1 => return self.parsed_sections.items[0].limp_header.len > 0,
            else => return true,
        }
    }

    pub fn process(self: *Processor, assignments: []const root.Assignment, eval_strings: []const []const u8) !ProcessResult {
        const l = try lua.State.init();
        defer l.deinit();

        return self.processInner(l, assignments, eval_strings) catch |err| switch (err) {
            error.LuaRuntimeError => {
                const msg = l.getString(1, "(trace not available)");
                root.stderr.print("{s}\n", .{msg}) catch {};
                root.stderr.flush() catch {};
                return .ignore;
            },
            error.LuaSyntaxError => {
                const msg = l.getString(1, "(details not available)");
                root.stderr.print("{s}\n", .{msg}) catch {};
                root.stderr.flush() catch {};
                return .ignore;
            },
            else => return err,
        };
    }

    fn processInner(self: *Processor, l: lua.State, assignments: []const root.Assignment, eval_strings: []const []const u8) !ProcessResult {
        const initializers = [_]lua.c.lua_CFunction{
            lua.registerStdLib,
            lua.fs.registerFsLib,
            lua.util.registerUtilLib,
            lua.sexpr.registerSExprLib,
        };
        try l.callAll(&initializers);

        //   belua::time_module,

        try l.setGlobalString("file_path", self.file_path);
        try l.setGlobalString("file_name", std.Io.Dir.path.basename(self.file_path));
        try l.setGlobalString("file_dir", std.Io.Dir.path.dirname(self.file_path) orelse "");
        //try l.setGlobalString("file_contents", self.file_contents);
        try l.setGlobalString("comment_begin", self.comment_tokens.opener);
        try l.setGlobalString("comment_end", self.comment_tokens.closer);
        try l.setGlobalString("comment_line_prefix", self.comment_tokens.line_prefix);

        try l.execute(limp_core, "@LIMP core");

        for (assignments) |assignment| {
            try l.setGlobalString(assignment.key, assignment.value);
        }

        for (1.., eval_strings) |num, eval_string| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrintZ(&name_buf, "--eval #{d}", .{ num });
            try l.execute(eval_string, name);
        }

        try self.processed_sections.ensureTotalCapacity(temp_alloc, self.parsed_sections.items.len);
        self.processed_sections.items.len = 0;

        var modified = false;

        for (self.parsed_sections.items, 0..) |section, i| {
            if (section.limp_header.len == 0) {
                try self.processed_sections.append(temp_alloc, section);
                continue;
            }

            try l.setGlobalString("last_generated_data", section.limp_output);
            try l.setGlobalString("base_indent", section.indent);
            try l.setGlobalString("nl_style", section.newline_style);

            var limp_name_writer = std.Io.Writer.Allocating.init(temp_alloc);
            try limp_name_writer.writer.print("@{s} LIMP {d}", .{ self.file_path, i });
            try limp_name_writer.writer.writeByte(0);
            const limp_name = limp_name_writer.written();

            try l.execute(section.clean_program, @ptrCast(limp_name[0 .. limp_name.len - 1]));

            try l.pushGlobal("_finish");
            try l.call(0, 1);
            const raw_output = l.getString(-1, "");

            l.setTop(0);

            // make sure output ends with a newline
            var output = try temp_alloc.alloc(u8, raw_output.len + section.newline_style.len);
            @memcpy(output.ptr, raw_output);
            if (std.mem.endsWith(u8, raw_output, section.newline_style)) {
                output.len = raw_output.len;
            } else {
                @memcpy(output[raw_output.len..], section.newline_style);
            }

            var line_count: i32 = 0;
            var search_start_loc: usize = 0;
            while (search_start_loc < output.len) {
                if (std.mem.indexOfAnyPos(u8, output, search_start_loc, "\r\n")) |end_of_line| {
                    line_count += 1;
                    if (std.mem.startsWith(u8, output[end_of_line..], "\r\n")) {
                        search_start_loc = end_of_line + 2;
                    } else {
                        search_start_loc = end_of_line + 1;
                    }
                } else break;
            }

            var footer_writer = std.Io.Writer.Allocating.init(temp_alloc);
            try footer_writer.writer.print("{s} {d} {s}", .{ self.limp_tokens.closer, line_count, self.comment_tokens.closer });

            try self.processed_sections.append(temp_alloc, .{
                .text = section.text,
                .indent = section.indent,
                .newline_style = section.newline_style,
                .limp_header = section.limp_header,
                .raw_program = section.raw_program,
                .clean_program = section.clean_program,
                .limp_footer = footer_writer.written(),
                .limp_output = output,
            });

            if (!modified and !std.mem.eql(u8, section.limp_output, output)) {
                modified = true;
            }
        }

        return if (modified) .modified else .up_to_date;

        // TODO depfile
        //    if (!depfile_path_.empty()) {
        //       SV write_depfile = "if write_depfile then write_depfile() end"sv;
        //       context.execute(write_depfile, "@" + path_.filename().string() + " write depfile");
        //    }
    }

    pub fn write(self: *Processor, writer: *std.Io.Writer) !void {
        for (self.processed_sections.items) |section| {
            try writer.writeAll(section.text);
            try writer.writeAll(section.limp_header);
            try writer.writeAll(section.raw_program);
            try writer.writeAll(section.limp_footer);
            try writer.writeAll(section.limp_output);
        }
    }
};
