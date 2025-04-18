const std = @import("std");
const config = @import("config");
const allocators = @import("allocators.zig");
const languages = @import("languages.zig");
const processor = @import("processor.zig");
const lua = @import("lua.zig");
const zlib = @import("zlib.zig");

const help_common = @embedFile("help-common.txt");
const help_verbose = @embedFile("help-verbose.txt");
const help_options = @embedFile("help-options.txt");
const help_exitcodes = @embedFile("help-exitcodes.txt");

var arg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const arg_alloc = arg_arena.allocator();
const global_alloc = allocators.global_arena.allocator();
const temp_alloc = allocators.temp_arena.allocator();

pub var option_verbose = false;
pub var option_very_verbose = false;
pub var option_quiet = false;
var option_test = false;
var option_show_version = false;
var option_show_help = false;
var option_verbose_help = false;
var option_recursive = false;
var option_dry_run = false;
var option_break_on_fail = false;

var depfile_path: ?[]const u8 = null;
var input_paths = std.ArrayList([]const u8).init(global_alloc);
var extensions = std.StringHashMap(void).init(global_alloc);
var eval_strings = std.ArrayList([]const u8).init(global_alloc);
var assignments = std.ArrayList(Assignment).init(global_alloc);

pub const Assignment = struct {
    key: []const u8,
    value: []const u8,
};

const ExitCode = packed struct (u8) {
    unknown: bool = false,
    bad_arg: bool = false,
    bad_input: bool = false,
    _: u5 = 0,
};
var exit_code = ExitCode{};

pub fn main() !void {
    allocators.temp_arena = try allocators.Temp_Allocator.init(1024 * 1024 * 1024);

    try run();
    // run() catch {
    //     if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
    //     exit_code.unknown = true;
    // };
    std.process.exit(@bitCast(exit_code));
}

fn run() !void {
    var args = try std.process.argsWithAllocator(arg_alloc);
    _ = args.next(); // skip path to exe

    while (args.next()) |arg| {
        try processArg(arg, &args);
    }

    arg_arena.deinit();

    if (option_test) {
        return;
    }

    if (!option_show_help and !option_show_version and input_paths.items.len == 0 and eval_strings.items.len == 0) {
        option_show_help = true;
        option_show_version = true;
        exit_code.bad_arg = true;
    }

    const stdout = std.io.getStdOut().writer();

    if (option_show_version) {
        try stdout.print("LIMP {s} Copyright (C) 2011-2024 Benjamin M. Crist\n", .{ config.version });
        try stdout.print("{s}\n", .{ lua.c.LUA_COPYRIGHT });
        try stdout.print("zig {s} {s}", .{
            @import("builtin").zig_version_string,
            @tagName(@import("builtin").mode),
        });
    }

    if (option_show_help) {
        if (option_show_version) {
            try stdout.writeAll("\n");
        }

        try stdout.writeAll(help_common);

        if (option_verbose_help) {
            try stdout.writeAll(help_verbose);
        }

        try stdout.writeAll(help_options);

        if (option_verbose_help) {
            try stdout.writeAll(help_exitcodes);
        }
    }

    try languages.initDefaults();
    try languages.load(option_verbose);

    if (extensions.count() == 0) {
        var it = languages.langs.keyIterator();
        while (it.next()) |ext| {
            if (ext.*.len > 0 and !std.mem.eql(u8, ext.*, "!!")) {
                try extensions.put(ext.*, {});
            }
        }
    }

    // TODO running with mutiple input paths results in
    // Unexpected error searching directory: error.Unexpected
    // possibly a bug with std.fs.cwd()?  Maybe you can't store
    // the result if you plan to change the cwd?
    var origin = try std.fs.cwd().openDir(".", .{});
    defer origin.close();
    for (input_paths.items) |input_path| {
        processInput(input_path, origin, true);
        if (shouldStopProcessing()) break;
    }
}

fn processInput(path: []const u8, within_dir: std.fs.Dir, explicitly_requested: bool) void {
    if (!processDir(path, within_dir)) processFile(path, within_dir, explicitly_requested);
}

fn processDir(path: []const u8, within_dir: std.fs.Dir) bool {
    return processDirInner(path, within_dir) catch |err| {
        printUnexpectedPathError("searching directory", path, within_dir, err);
        return true;
    };
}

fn processDirInner(path: []const u8, within_dir: std.fs.Dir) !bool {
    var dir = within_dir.openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return false,
        error.FileNotFound => {
            printPathError("Directory or file not found", path, within_dir);
            return true;
        },
        else => return err,
    };
    defer dir.close();

    if (option_verbose) {
        var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = within_dir.realpath(path, &real_path_buffer) catch path;
        try std.io.getStdOut().writer().print("{s}: Searching for files...\n", .{real_path});
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                processFile(entry.name, dir, false);
            },
            .directory => {
                if (option_recursive) {
                    processInput(entry.name, dir, false);
                }
            },
            .sym_link => {
                var symlink_buffer: [std.fs.max_path_bytes]u8 = undefined;
                if (dir.readLink(entry.name, &symlink_buffer)) |new_path| {
                    if (option_recursive) {
                        processInput(new_path, dir, false);
                    } else {
                        processFile(new_path, dir, false);
                    }
                } else |err| {
                    printUnexpectedPathError("reading link", entry.name, dir, err);
                }
            },
            else => {},
        }
        if (shouldStopProcessing()) return true;
    }

    return true;
}

fn processFile(path: []const u8, within_dir: std.fs.Dir, explicitly_requested: bool) void {
    processFileInner(path, within_dir, explicitly_requested) catch |err| {
        printUnexpectedPathError("processing file", path, within_dir, err);
    };
}

fn processFileInner(path: []const u8, within_dir: std.fs.Dir, explicitly_requested: bool) !void {
    var ext_lower_buf: [128]u8 = undefined;
    var extension = std.fs.path.extension(path);
    if (extension.len > 1 and extension[0] == '.') {
        extension = extension[1..];
    }
    if (extension.len <= ext_lower_buf.len) {
        extension = std.ascii.lowerString(&ext_lower_buf, extension);
    }

    if (!explicitly_requested and (extension.len == 0 or !extensions.contains(extension))) {
        if (option_very_verbose) {
            printPathError("Unrecognized extension", path, within_dir);
        }
        return;
    }

    allocators.temp_arena.reset(.{});

    var old_file_contents = within_dir.readFileAlloc(temp_alloc, path, 1 << 30) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (explicitly_requested or option_very_verbose) {
                    printPathError("Not a file or directory", path, within_dir);
                }
                return;
            },
            else => {
                printUnexpectedPathError("loading file", path, within_dir, err);
                return;
            },
        }
    };

    if (!option_quiet and old_file_contents.len >= 2) {
        if (std.mem.eql(u8, old_file_contents[0..2], "\xFF\xFE") or std.mem.eql(u8, old_file_contents[0..2], "\xFE\xFF")) {
            printPathError("File is UTF-16 encoded; LIMP only supports UTF-8 files", path, within_dir);
            return;
        } else for (old_file_contents[0..@min(40, old_file_contents.len - 1)]) |c| {
            if (c == 0) {
                printPathError("File might be UTF-16 encoded; LIMP only supports UTF-8 files", path, within_dir);
                break;
            }
        }
    }

    const real_path = within_dir.realpathAlloc(temp_alloc, path) catch path;

    var proc = processor.Processor.init(languages.get(extension), languages.getLimp());
    try proc.parse(real_path, old_file_contents);

    if (proc.isProcessable()) {
        if (std.fs.path.dirname(real_path)) |dir| {
            try std.posix.chdir(dir);
        }
        switch (try proc.process(assignments.items, eval_strings.items)) {
            .ignore => {
                if (option_verbose) {
                    printPathStatus("Ignoring", path, within_dir);
                }
                exit_code.bad_input = true;
            },
            .modified => {
                if (option_dry_run) {
                    printPathStatus("Out of date", path, within_dir);
                } else {
                    if (!option_quiet) {
                        printPathStatus("Rewriting", path, within_dir);
                    }
                    var af = try within_dir.atomicFile(path, .{});
                    defer af.deinit();
                    try proc.write(af.file.writer());
                    try af.finish();
                }
            },
            .up_to_date => {
                if (!option_quiet) {
                    printPathStatus("Up to date", path, within_dir);
                }
            },
        }

        // for (proc.parsed_sections.items) |section| {
        //     try section.debug();
        // }
    } else if (explicitly_requested or option_very_verbose) {
        printPathStatus("Nothing to process", path, within_dir);
    }
}

fn printPathStatus(detail: []const u8, path: []const u8, within_dir: std.fs.Dir) void {
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = within_dir.realpath(path, &real_path_buffer) catch path;
    std.io.getStdOut().writer().print("{s}: {s}\n", .{ real_path, detail }) catch {};
}

fn printPathError(detail: []const u8, path: []const u8, within_dir: std.fs.Dir) void {
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = within_dir.realpath(path, &real_path_buffer) catch path;
    std.io.getStdErr().writer().print("{s}: {s}\n", .{ real_path, detail }) catch {};
    exit_code.unknown = true;
}

fn printUnexpectedPathError(where: []const u8, path: []const u8, within_dir: std.fs.Dir, err: anyerror) void {
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = within_dir.realpath(path, &real_path_buffer) catch path;
    std.io.getStdErr().writer().print("{s}: Unexpected error {s}: {}\n", .{ real_path, where, err }) catch {};
    exit_code.unknown = true;
}

fn shouldStopProcessing() bool {
    return option_break_on_fail and (exit_code.unknown or exit_code.bad_input);
}

var check_option_args = true;

fn processArg(arg: []const u8, args: *std.process.ArgIterator) !void {
    if (check_option_args and arg.len > 0 and arg[0] == '-') {
        if (arg.len > 1) {
            if (arg[1] == '-') {
                try processLongOption(arg, args);
            } else {
                for (arg[1..]) |c| try processShortOption(c, args);
            }
            return;
        }
    }

    const path = try global_alloc.dupe(u8, arg);
    try input_paths.append(path);
}

fn processLongOption(arg: []const u8, args: *std.process.ArgIterator) !void {
    if (arg.len == 2) {
        check_option_args = false;
    } else if (std.mem.eql(u8, arg, "--dry-run")) {
        option_dry_run = true;
    } else if (std.mem.eql(u8, arg, "--break-on-fail")) {
        option_break_on_fail = true;
    } else if (std.mem.eql(u8, arg, "--recursive")) {
        option_recursive = true;
    } else if (std.mem.eql(u8, arg, "--help")) {
        option_show_help = true;
        option_verbose_help = true;
    } else if (std.mem.eql(u8, arg, "--version")) {
        option_show_version = true;
    } else if (std.mem.eql(u8, arg, "--test")) {
        option_test = true;
    } else if (std.mem.eql(u8, arg, "--verbose")) {
        if (option_verbose) {
            option_very_verbose = true;
        } else {
            option_verbose = true;
        }
    } else if (std.mem.eql(u8, arg, "--quiet")) {
        option_quiet = true;
    } else if (std.mem.eql(u8, arg, "--extensions")) {
        if (args.next()) |list| {
            try processExtensionList(list);
        } else {
            try std.io.getStdErr().writer().writeAll("Expected extension list after --extensions\n");
            exit_code.bad_arg = true;
        }
    } else if (std.mem.startsWith(u8, arg, "--extensions=")) {
        try processExtensionList(arg["--extensions=".len..]);
    } else if (std.mem.eql(u8, arg, "--depfile")) {
        if (args.next()) |path| {
            depfile_path = try global_alloc.dupe(u8, path);
        } else {
            try std.io.getStdErr().writer().writeAll("Expected input directory path after --depfile\n");
            exit_code.bad_arg = true;
        }
    } else if (std.mem.startsWith(u8, arg, "--depfile=")) {
        depfile_path = try global_alloc.dupe(u8, arg["--depfile=".len..]);
    } else if (std.mem.eql(u8, arg, "--set")) {
        if (args.next()) |key| {
            const dupe_key = try global_alloc.dupe(u8, key);
            if (args.next()) |value| {
                const dupe_value = try global_alloc.dupe(u8, value);
                try assignments.append(.{
                    .key = dupe_key,
                    .value = dupe_value,
                });
            } else {
                try std.io.getStdErr().writer().writeAll("Expected value after --set <key>\n");
                exit_code.bad_arg = true;
            }
        } else {
            try std.io.getStdErr().writer().writeAll("Expected global key after --set\n");
            exit_code.bad_arg = true;
        }
    } else if (std.mem.eql(u8, arg, "--eval")) {
        if (args.next()) |str| {
            const dupe_str = try global_alloc.dupe(u8, str);
            try eval_strings.append(dupe_str);
        } else {
            try std.io.getStdErr().writer().writeAll("Expected string to evaluate after --eval\n");
            exit_code.bad_arg = true;
        }
    } else {
        try std.io.getStdErr().writer().print("Unrecognized option: {s}\n", .{arg});
        exit_code.bad_arg = true;
    }
}

fn processShortOption(c: u8, args: *std.process.ArgIterator) !void {
    switch (c) {
        'R' => option_recursive = true,
        'n' => option_dry_run = true,
        'b' => option_break_on_fail = true,
        'v' => {
            if (option_verbose) {
                option_very_verbose = true;
            } else {
                option_verbose = true;
            }
        },
        'q' => option_quiet = true,
        'V' => option_show_version = true,
        '?' => option_show_help = true,
        'x' => {
            if (args.next()) |list| {
                try processExtensionList(list);
            } else {
                try std.io.getStdErr().writer().writeAll("Expected extension list after -x\n");
                exit_code.bad_arg = true;
            }
        },
        else => {
            const option = [_]u8{c};
            try std.io.getStdErr().writer().print("Unrecognized option: -{s}\n", .{option});
            exit_code.bad_arg = true;
        },
    }
}

fn processExtensionList(list: []const u8) !void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw_ext| {
        const ext = try if (raw_ext.len <= 128) std.ascii.allocLowerString(global_alloc, raw_ext) else global_alloc.dupe(u8, raw_ext);
        try extensions.put(ext, {});
    }
}
