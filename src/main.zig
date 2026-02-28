const std = @import("std");
const globals = @import("globals.zig");
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
const global_alloc = globals.arena.allocator();
const temp_alloc = globals.temp_arena.allocator();

pub var stdout: *std.Io.Writer = undefined;
pub var stderr: *std.Io.Writer = undefined;

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
var input_paths = std.array_list.Managed([]const u8).init(global_alloc);
var extensions = std.StringHashMap(void).init(global_alloc);
var eval_strings = std.array_list.Managed([]const u8).init(global_alloc);
var assignments = std.array_list.Managed(Assignment).init(global_alloc);

pub const Assignment = struct {
    key: []const u8,
    value: []const u8,
};

const ExitCode = packed struct (u8) {
    modified_files: u7 = 0,
    err: bool = false,
};
var exit_code = ExitCode{};

pub fn main(init: std.process.Init) !void {
    globals.temp_arena = try .init(1024 * 1024 * 1024);
    globals.io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [64]u8 = undefined;

    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);

    stderr = &stderr_writer.interface;
    stdout = &stdout_writer.interface;

    try run(init.io, init.minimal.args);
    // run() catch {
    //     if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
    //     exit_code.err = true;
    // };

    stderr.flush() catch {};
    stdout.flush() catch {};

    std.process.exit(@bitCast(exit_code));
}

fn run(io: std.Io, args: std.process.Args) !void {
    var args_iter = try args.iterateAllocator(arg_alloc);
    _ = args_iter.next(); // skip path to exe

    while (args_iter.next()) |arg| {
        try processArg(arg, &args_iter);
    }

    arg_arena.deinit();

    if (option_test) {
        return;
    }

    if (!option_show_help and !option_show_version and input_paths.items.len == 0 and eval_strings.items.len == 0) {
        option_show_help = true;
        option_show_version = true;
        exit_code.err = true;
    }

    if (option_show_version) {
        try stdout.print("LIMP {s} Copyright (C) 2011-2026 Benjamin M. Crist\n", .{ @import("zon").version });
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

    try stdout.flush();

    try languages.initDefaults();
    try languages.load(io, option_verbose);

    if (extensions.count() == 0) {
        var it = languages.langs.keyIterator();
        while (it.next()) |ext| {
            if (ext.*.len > 0 and !std.mem.eql(u8, ext.*, "!!")) {
                try extensions.put(ext.*, {});
            }
        }
    }

    var root_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path_bytes = try std.Io.Dir.cwd().realPath(io, &root_path_buf);
    const root_path = root_path_buf[0..root_path_bytes];
    
    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root_dir.close(io);

    for (input_paths.items) |input_path| {
        processInput(io, input_path, root_dir, root_path, true);
        if (shouldStopProcessing()) break;
    }
}

fn processInput(io: std.Io, path: []const u8, parent_dir: std.Io.Dir, parent_path: []const u8, explicitly_requested: bool) void {
    if (!processDir(io, path, parent_dir, parent_path)) processFile(io, path, parent_dir, parent_path, explicitly_requested);
}

fn processDir(io: std.Io, path: []const u8, parent_dir: std.Io.Dir, parent_path: []const u8) bool {
    return processDirInner(io, path, parent_dir, parent_path) catch |err| {
        printUnexpectedPathError("searching directory", path, parent_path, err);
        return true;
    };
}

fn processDirInner(io: std.Io, path: []const u8, parent_dir: std.Io.Dir, parent_path: []const u8) !bool {
    var dir = parent_dir.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return false,
        error.FileNotFound => {
            printPathError("Directory or file not found", path, parent_path);
            return true;
        },
        else => return err,
    };
    defer dir.close(io);

    const dir_path = try std.Io.Dir.path.join(globals.gpa, &.{ parent_path, path });
    defer globals.gpa.free(dir_path);

    if (option_verbose) {
        printPathStatus("Searching for files...", path, parent_path);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                processFile(io, entry.name, dir, dir_path, false);
            },
            .directory => {
                if (option_recursive) {
                    processInput(io, entry.name, dir, dir_path, false);
                }
            },
            .sym_link => {
                var symlink_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                if (dir.readLink(io, entry.name, &symlink_buffer)) |bytes| {
                    const new_path = symlink_buffer[0..bytes];
                    if (option_recursive) {
                        processInput(io, new_path, dir, dir_path, false);
                    } else {
                        processFile(io, new_path, dir, dir_path, false);
                    }
                } else |err| {
                    printUnexpectedPathError("reading link", entry.name, dir_path, err);
                }
            },
            else => {},
        }
        if (shouldStopProcessing()) return true;
    }

    return true;
}

fn processFile(io: std.Io, path: []const u8, parent_dir: std.Io.Dir, parent_path: []const u8, explicitly_requested: bool) void {
    processFileInner(io, path, parent_dir, parent_path, explicitly_requested) catch |err| {
        printUnexpectedPathError("processing file", path, parent_path, err);
    };
}

fn processFileInner(io: std.Io, path: []const u8, parent_dir: std.Io.Dir, parent_path: []const u8, explicitly_requested: bool) !void {
    var ext_lower_buf: [128]u8 = undefined;
    var extension = std.Io.Dir.path.extension(path);
    if (extension.len > 1 and extension[0] == '.') {
        extension = extension[1..];
    }
    if (extension.len <= ext_lower_buf.len) {
        extension = std.ascii.lowerString(&ext_lower_buf, extension);
    }

    if (!explicitly_requested and (extension.len == 0 or !extensions.contains(extension))) {
        if (option_very_verbose) {
            printPathError("Unrecognized extension", path, parent_path);
        }
        return;
    }

    globals.temp_arena.reset(.{});

    var old_file_contents = parent_dir.readFileAlloc(io, path, temp_alloc, .limited(1 << 30)) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (explicitly_requested or option_very_verbose) {
                    printPathError("Not a file or directory", path, parent_path);
                }
                return;
            },
            else => {
                printUnexpectedPathError("loading file", path, parent_path, err);
                return;
            },
        }
    };

    var old_file_stat = try parent_dir.statFile(io, path, .{ .follow_symlinks = true });

    if (!option_quiet and old_file_contents.len >= 2) {
        if (std.mem.eql(u8, old_file_contents[0..2], "\xFF\xFE") or std.mem.eql(u8, old_file_contents[0..2], "\xFE\xFF")) {
            printPathError("File is UTF-16 encoded; LIMP only supports UTF-8 files", path, parent_path);
            return;
        } else for (old_file_contents[0..@min(40, old_file_contents.len - 1)]) |c| {
            if (c == 0) {
                printPathError("File might be UTF-16 encoded; LIMP only supports UTF-8 files", path, parent_path);
                break;
            }
        }
    }

    const real_path = parent_dir.realPathFileAlloc(io, path, temp_alloc) catch path;

    var proc = processor.Processor.init(languages.get(extension), languages.getLimp());
    try proc.parse(real_path, old_file_contents);

    if (proc.isProcessable()) {
        try std.process.setCurrentDir(io, parent_dir);
        switch (try proc.process(assignments.items, eval_strings.items)) {
            .ignore => {
                if (option_verbose) {
                    printPathStatus("Ignoring", path, parent_path);
                }
                exit_code.err = true;
            },
            .modified => {
                if (option_dry_run) {
                    printPathStatus("Out of date", path, parent_path);
                } else {
                    if (!option_quiet) {
                        printPathStatus("Rewriting", path, parent_path);
                    }

                    var af = try parent_dir.createFileAtomic(io, path, .{
                        .permissions = old_file_stat.permissions,
                        .replace = true,
                    });
                    defer af.deinit(io);

                    var buf: [4096]u8 = undefined;
                    var writer = af.file.writer(io, &buf);

                    try proc.write(&writer.interface);
                    try writer.interface.flush();
                    try af.replace(io);

                    exit_code.modified_files += 1;
                }
            },
            .up_to_date => {
                if (!option_quiet) {
                    printPathStatus("Up to date", path, parent_path);
                }
            },
        }

        // for (proc.parsed_sections.items) |section| {
        //     try section.debug();
        // }
    } else if (explicitly_requested or option_very_verbose) {
        printPathStatus("Nothing to process", path, parent_path);
    }
}

fn printPathStatus(detail: []const u8, path: []const u8, parent_dir: []const u8) void {
    const joined = std.Io.Dir.path.join(globals.gpa, &.{ parent_dir, path }) catch return;
    defer globals.gpa.free(joined);
    stderr.print("{s}: {s}\n", .{ joined, detail }) catch {};
    stderr.flush() catch {};
}

fn printPathError(detail: []const u8, path: []const u8, parent_dir: []const u8) void {
    exit_code.err = true;
    const joined = std.Io.Dir.path.join(globals.gpa, &.{ parent_dir, path }) catch return;
    defer globals.gpa.free(joined);
    stderr.print("{s}: {s}\n", .{ joined, detail }) catch {};
    stderr.flush() catch {};
}

fn printUnexpectedPathError(where: []const u8, path: []const u8, parent_dir: []const u8, err: anyerror) void {
    exit_code.err = true;
    const joined = std.Io.Dir.path.join(globals.gpa, &.{ parent_dir, path }) catch return;
    defer globals.gpa.free(joined);
    stderr.print("{s}: Unexpected error {s}: {}\n", .{ joined, where, err }) catch {};
    stderr.flush() catch {};
}

fn shouldStopProcessing() bool {
    return option_break_on_fail and exit_code.err;
}

var check_option_args = true;

fn processArg(arg: []const u8, args: *std.process.Args.Iterator) !void {
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

fn processLongOption(arg: []const u8, args: *std.process.Args.Iterator) !void {
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
            try stderr.writeAll("Expected extension list after --extensions\n");
            exit_code.err = true;
        }
    } else if (std.mem.startsWith(u8, arg, "--extensions=")) {
        try processExtensionList(arg["--extensions=".len..]);
    } else if (std.mem.eql(u8, arg, "--depfile")) {
        if (args.next()) |path| {
            depfile_path = try global_alloc.dupe(u8, path);
        } else {
            try stderr.writeAll("Expected input directory path after --depfile\n");
            exit_code.err = true;
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
                try stderr.writeAll("Expected value after --set <key>\n");
                exit_code.err = true;
            }
        } else {
            try stderr.writeAll("Expected global key after --set\n");
            exit_code.err = true;
        }
    } else if (std.mem.eql(u8, arg, "--eval")) {
        if (args.next()) |str| {
            const dupe_str = try global_alloc.dupe(u8, str);
            try eval_strings.append(dupe_str);
        } else {
            try stderr.writeAll("Expected string to evaluate after --eval\n");
            exit_code.err = true;
        }
    } else {
        try stderr.print("Unrecognized option: {s}\n", .{arg});
        exit_code.err = true;
    }
    try stderr.flush();
}

fn processShortOption(c: u8, args: *std.process.Args.Iterator) !void {
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
                try stderr.writeAll("Expected extension list after -x\n");
                try stderr.flush();
                exit_code.err = true;
            }
        },
        else => {
            const option = [_]u8{c};
            try stderr.print("Unrecognized option: -{s}\n", .{option});
            try stderr.flush();
            exit_code.err = true;
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
