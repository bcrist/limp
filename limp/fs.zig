const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowsPath = std.fs.path.WindowsPath;
const native_os = builtin.target.os.tag;

pub fn replaceExtension(allocator: Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const old_ext = std.fs.path.extension(path);
    const without_ext = path[0..(@ptrToInt(old_ext.ptr) - @ptrToInt(path.ptr))];
    var result: []u8 = undefined;

    if (new_ext.len == 0) {
        result = try allocator.alloc(u8, without_ext.len + new_ext.len);
        std.mem.copy(u8, result, without_ext);
    } else if (new_ext[0] == '.') {
        result = try allocator.alloc(u8, without_ext.len + new_ext.len);
        std.mem.copy(u8, result, without_ext);
        std.mem.copy(u8, result[without_ext.len..], new_ext);
    } else {
        result = try allocator.alloc(u8, without_ext.len + new_ext.len + 1);
        std.mem.copy(u8, result, without_ext);
        result[without_ext.len] = '.';
        std.mem.copy(u8, result[without_ext.len + 1 ..], new_ext);
    }

    return result;
}

pub fn toAbsolute(allocator: Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return composePath(allocator, @as(*const [1][]const u8, &path), 0);
    } else {
        var cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        var parts = [_][]const u8{ cwd, path };
        return composePath(allocator, &parts, 0);
    }
}

/// Like std.fs.path.resolve, except it doesn't convert relative paths to absolute, and
/// it doesn't resolve ".." segments to avoid incorrect behavior in the presence of links.
pub fn composePath(allocator: Allocator, paths: []const []const u8, sep: u8) ![]u8 {
    if (native_os == .windows) {
        return composePathWindows(allocator, paths, sep);
    } else {
        return composePathPosix(allocator, paths, sep);
    }
}

pub fn composePathWindows(allocator: Allocator, paths: []const []const u8, sep: u8) ![]u8 {
    if (paths.len == 0) {
        var result: []u8 = try allocator.alloc(u8, 1);
        result[0] = '.';
        return result;
    }

    const separator = if (sep == 0) '\\' else sep;

    // determine which disk designator we will result with, if any
    var result_drive_buf = "_:".*;
    var result_disk_designator: []const u8 = "";
    var have_drive_kind = WindowsPath.Kind.None;
    var have_abs_path = false;
    var first_index: usize = 0;
    var max_size: usize = 0;
    for (paths) |p, i| {
        const parsed = std.fs.path.windowsParsePath(p);
        if (parsed.is_abs) {
            have_abs_path = true;
            first_index = i;
            max_size = result_disk_designator.len;
        }
        switch (parsed.kind) {
            WindowsPath.Kind.Drive => {
                result_drive_buf[0] = std.ascii.toUpper(parsed.disk_designator[0]);
                result_disk_designator = result_drive_buf[0..];
                have_drive_kind = WindowsPath.Kind.Drive;
            },
            WindowsPath.Kind.NetworkShare => {
                result_disk_designator = parsed.disk_designator;
                have_drive_kind = WindowsPath.Kind.NetworkShare;
            },
            WindowsPath.Kind.None => {},
        }
        max_size += p.len + 1;
    }

    // if we will result with a disk designator, loop again to determine
    // which is the last time the disk designator is absolutely specified, if any
    // and count up the max bytes for paths related to this disk designator
    if (have_drive_kind != WindowsPath.Kind.None) {
        have_abs_path = false;
        first_index = 0;
        max_size = result_disk_designator.len;
        var correct_disk_designator = false;

        for (paths) |p, i| {
            const parsed = std.fs.path.windowsParsePath(p);
            if (parsed.kind != WindowsPath.Kind.None) {
                if (parsed.kind == have_drive_kind) {
                    correct_disk_designator = compareDiskDesignators(have_drive_kind, result_disk_designator, parsed.disk_designator);
                } else {
                    continue;
                }
            }
            if (!correct_disk_designator) {
                continue;
            }
            if (parsed.is_abs) {
                first_index = i;
                max_size = result_disk_designator.len;
                have_abs_path = true;
            }
            max_size += p.len + 1;
        }
    }

    // Allocate result and fill in the disk designator, calling getCwd if we have to.
    var result: []u8 = try allocator.alloc(u8, max_size);
    errdefer allocator.free(result);

    var result_index: usize = 0;

    if (have_abs_path) {
        switch (have_drive_kind) {
            WindowsPath.Kind.Drive => {
                std.mem.copy(u8, result, result_disk_designator);
                result_index += result_disk_designator.len;
            },
            WindowsPath.Kind.NetworkShare => {
                var it = std.mem.tokenize(u8, paths[first_index], "/\\");
                const server_name = it.next().?;
                const other_name = it.next().?;

                result[result_index] = '\\';
                result_index += 1;
                result[result_index] = '\\';
                result_index += 1;
                std.mem.copy(u8, result[result_index..], server_name);
                result_index += server_name.len;
                result[result_index] = '\\';
                result_index += 1;
                std.mem.copy(u8, result[result_index..], other_name);
                result_index += other_name.len;

                result_disk_designator = result[0..result_index];
            },
            WindowsPath.Kind.None => {},
        }
    }

    // Now we know the disk designator to use, if any, and what kind it is. And our result
    // is big enough to append all the paths to.
    var correct_disk_designator = true;
    for (paths[first_index..]) |p| {
        const parsed = std.fs.path.windowsParsePath(p);

        if (parsed.kind != WindowsPath.Kind.None) {
            if (parsed.kind == have_drive_kind) {
                correct_disk_designator = compareDiskDesignators(have_drive_kind, result_disk_designator, parsed.disk_designator);
            } else {
                continue;
            }
        }
        if (!correct_disk_designator) {
            continue;
        }
        var it = std.mem.tokenize(u8, p[parsed.disk_designator.len..], "/\\");
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, ".")) {
                continue;
            } else {
                if (have_abs_path or result_index > 0) {
                    result[result_index] = separator;
                    result_index += 1;
                }
                std.mem.copy(u8, result[result_index..], component);
                result_index += component.len;
            }
        }
    }

    if (have_abs_path and result_index == result_disk_designator.len) {
        result[0] = separator;
        result_index += 1;
    } else if (!have_abs_path and result_index == 0) {
        result[0] = '.';
        result_index += 1;
    }

    return allocator.shrink(result, result_index);
}

pub fn composePathPosix(allocator: Allocator, paths: []const []const u8, sep: u8) ![]u8 {
    if (paths.len == 0) {
        var result: []u8 = try allocator.alloc(u8, 1);
        result[0] = '.';
        return result;
    }

    const separator = if (sep == 0) '/' else sep;

    var first_index: usize = 0;
    var have_abs = false;
    var max_size: usize = 0;
    for (paths) |p, i| {
        if (std.fs.path.isAbsolutePosix(p)) {
            first_index = i;
            have_abs = true;
            max_size = 0;
        }
        max_size += p.len + 1;
    }

    var result: []u8 = undefined;
    var result_index: usize = 0;

    result = try allocator.alloc(u8, max_size);
    errdefer allocator.free(result);

    for (paths[first_index..]) |p| {
        var it = std.mem.tokenize(u8, p, "/");
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, ".")) {
                continue;
            } else {
                if (have_abs or result_index > 0) {
                    result[result_index] = separator;
                    result_index += 1;
                }
                std.mem.copy(u8, result[result_index..], component);
                result_index += component.len;
            }
        }
    }

    if (result_index == 0) {
        if (have_abs) {
            result[0] = separator;
        } else {
            result[0] = '.';
        }
        result_index += 1;
    }

    return allocator.shrink(result, result_index);
}

/// If 'path' is a subpath of 'ancestor', returns the subpath portion.
/// If 'path' and 'ancestor' are the same, returns `.`.
/// Otherwise, returns 'path'.
/// Any `.` segments in either path are ignored (but not `..` segments).
/// On windows, `/` and `\` can be used interchangeably.
/// Note this is only a lexical operation; it doesn't depend on the paths
/// existing or change based on the current working directory.
pub fn pathRelativeToAncestor(path: []const u8, ancestor: []const u8) []const u8 {
    if (native_os == .windows) {
        return pathRelativeToAncestorWindows(path, ancestor);
    } else {
        return pathRelativeToAncestorPosix(path, ancestor);
    }
}

pub inline fn pathRelativeToAncestorWindows(path: []const u8, ancestor: []const u8) []const u8 {
    return pathRelativeToAncestorGeneric(path, ancestor, "/\\");
}

pub inline fn pathRelativeToAncestorPosix(path: []const u8, ancestor: []const u8) []const u8 {
    return pathRelativeToAncestorGeneric(path, ancestor, "/");
}

fn pathRelativeToAncestorGeneric(path: []const u8, ancestor: []const u8, comptime tokens: []const u8) []const u8 {
    var path_it = std.mem.tokenize(u8, path, tokens);
    var ancestor_it = std.mem.tokenize(u8, ancestor, tokens);

    if (prefixMatches(&path_it, &ancestor_it)) {
        var start = path_it.next() orelse return ".";
        while (std.mem.eql(u8, start, ".")) {
            start = path_it.next() orelse return ".";
        }

        return path[(@ptrToInt(start.ptr) - @ptrToInt(path.ptr))..];
    } else {
        return path;
    }
}

fn prefixMatches(path_it: *std.mem.TokenIterator(u8), ancestor_it: *std.mem.TokenIterator(u8)) bool {
    while (true) {
        var ancestor_part = ancestor_it.next() orelse return true;
        while (std.mem.eql(u8, ancestor_part, ".")) {
            ancestor_part = ancestor_it.next() orelse return true;
        }

        var path_part = path_it.next() orelse return false;
        while (std.mem.eql(u8, path_part, ".")) {
            path_part = path_it.next() orelse return false;
        }

        if (!std.mem.eql(u8, path_part, ancestor_part)) {
            return false;
        }
    }
}

fn compareDiskDesignators(kind: WindowsPath.Kind, p1: []const u8, p2: []const u8) bool {
    switch (kind) {
        WindowsPath.Kind.None => {
            assert(p1.len == 0);
            assert(p2.len == 0);
            return true;
        },
        WindowsPath.Kind.Drive => {
            return std.ascii.toUpper(p1[0]) == std.ascii.toUpper(p2[0]);
        },
        WindowsPath.Kind.NetworkShare => {
            const sep1 = p1[0];
            const sep2 = p2[0];

            var it1 = std.mem.tokenize(u8, p1, &[_]u8{sep1});
            var it2 = std.mem.tokenize(u8, p2, &[_]u8{sep2});

            // TODO ASCII is wrong, we actually need full unicode support to compare paths.
            return std.ascii.eqlIgnoreCase(it1.next().?, it2.next().?) and std.ascii.eqlIgnoreCase(it1.next().?, it2.next().?);
        },
    }
}

const CopyTreeError = error {SystemResources} || std.os.CopyFileRangeError || std.os.SendFileError || std.os.RenameError || std.os.OpenError;

pub fn copyTree(source_dir: std.fs.Dir, source_path: []const u8, dest_dir: std.fs.Dir, dest_path: []const u8, options: std.fs.CopyFileOptions) CopyTreeError!void {
    // TODO figure out how to handle symlinks better
    source_dir.copyFile(source_path, dest_dir, dest_path, options) catch |err| switch (err) {
        error.IsDir => {
            var src = try source_dir.openDir(source_path, .{ .iterate = true, .no_follow = true });
            defer src.close();

            var dest = try dest_dir.makeOpenPath(dest_path, .{ .no_follow = true });
            defer dest.close();

            try copyDir(src, dest, options);
        },
        else => return err,
    };
}

fn copyDir(source_dir: std.fs.Dir, dest_dir: std.fs.Dir, options: std.fs.CopyFileOptions) CopyTreeError!void {
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == std.fs.File.Kind.Directory) {
            var src = try source_dir.openDir(entry.name, .{ .iterate = true, .no_follow = true });
            defer src.close();

            var dest = try dest_dir.makeOpenPath(entry.name, .{ .no_follow = true });
            defer dest.close();

            try copyDir(src, dest, options);
        } else {
            try copyTree(source_dir, entry.name, dest_dir, entry.name, options);
        }
    }
}

pub fn errorName(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "Access denied",
        error.BadPathName, error.InvalidUtf8 => "Invalid path",
        error.DeviceBusy => "Device busy",
        error.FileBusy => "File busy",
        error.PipeBusy => "Pipe busy",
        error.FileNotFound => "File not found",
        error.FileTooBig => "File too big",
        error.InputOutput => "I/O error",
        error.IsDir => "Path is a directory",
        error.NotDir => "Path is not a directory",
        error.NameTooLong => "Path too long",
        error.NoDevice => "Device not found",
        error.NoSpaceLeft => "Insufficient space remaining",
        error.PathAlreadyExists => "Path already exists",
        error.ProcessFdQuotaExceeded => "No more process file descriptors",
        error.SystemFdQuotaExceeded => "No more system file descriptors",
        error.SharingViolation => "Sharing violation",
        error.SymLinkLoop => "Symlink loop",
        error.OutOfMemory => "Out of memory",
        else => @errorName(err),
    };
}
