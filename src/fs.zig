const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowsPath = std.Io.Dir.path.WindowsPath;
const native_os = builtin.target.os.tag;

pub fn replaceExtension(allocator: Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const old_ext = std.Io.Dir.path.extension(path);
    const without_ext = path[0..(@intFromPtr(old_ext.ptr) - @intFromPtr(path.ptr))];
    var result: []u8 = undefined;

    if (new_ext.len == 0) {
        result = try allocator.dupe(u8, without_ext);
    } else if (new_ext[0] == '.') {
        result = try allocator.alloc(u8, without_ext.len + new_ext.len);
        @memcpy(result.ptr, without_ext);
        @memcpy(result[without_ext.len..], new_ext);
    } else {
        result = try allocator.alloc(u8, without_ext.len + new_ext.len + 1);
        @memcpy(result.ptr, without_ext);
        result[without_ext.len] = '.';
        @memcpy(result[without_ext.len + 1 ..], new_ext);
    }

    return result;
}

pub fn toAbsolute(io: std.Io, allocator: Allocator, path: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(path)) {
        return composePath(allocator, @as(*const [1][]const u8, &path), 0);
    } else {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        return composePath(allocator, &.{ cwd, path }, 0);
    }
}

/// Like std.Io.Dir.path.resolve, except it doesn't convert relative paths to absolute, and
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
    for (paths, 0..) |p, i| {
        const parsed = std.Io.Dir.path.windowsParsePath(p);
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

        for (paths, 0..) |p, i| {
            const parsed = std.Io.Dir.path.windowsParsePath(p);
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
                @memcpy(result.ptr, result_disk_designator);
                result_index += result_disk_designator.len;
            },
            WindowsPath.Kind.NetworkShare => {
                var it = std.mem.tokenizeAny(u8, paths[first_index], "/\\");
                const server_name = it.next().?;
                const other_name = it.next().?;

                result[result_index] = '\\';
                result_index += 1;
                result[result_index] = '\\';
                result_index += 1;
                @memcpy(result[result_index..].ptr, server_name);
                result_index += server_name.len;
                result[result_index] = '\\';
                result_index += 1;
                @memcpy(result[result_index..].ptr, other_name);
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
        const parsed = std.Io.Dir.path.windowsParsePath(p);

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
        var it = std.mem.tokenizeAny(u8, p[parsed.disk_designator.len..], "/\\");
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, ".")) {
                continue;
            } else {
                if (have_abs_path or result_index > 0) {
                    result[result_index] = separator;
                    result_index += 1;
                }
                @memcpy(result[result_index..].ptr, component);
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

    if (allocator.resize(result, result_index)) {
        return result[0..result_index];
    } else {
        const new_result = try allocator.dupe(u8, result[0..result_index]);
        allocator.free(result);
        return new_result;
    }
}

pub fn composePathPosix(allocator: Allocator, paths: []const []const u8, sep: u8) std.mem.Allocator.Error![]u8 {
    if (paths.len == 0) {
        return allocator.dupe(u8, ".");
    }

    const separator = if (sep == 0) '/' else sep;

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var is_abs = false;

    for (paths) |p| {
        if (std.Io.Dir.path.isAbsolutePosix(p)) {
            is_abs = true;
            result.clearRetainingCapacity();
        }
        var it = std.mem.tokenizeScalar(u8, p, '/');
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, ".")) {
                continue;
            } else if (result.items.len > 0 or is_abs) {
                try result.ensureUnusedCapacity(allocator, 1 + component.len);
                result.appendAssumeCapacity(separator);
                result.appendSliceAssumeCapacity(component);
            } else {
                try result.appendSlice(allocator, component);
            }
        }
    }

    if (result.items.len == 0) {
        if (is_abs) {
            return allocator.dupe(u8, &.{ separator });
        } else {
            return allocator.dupe(u8, ".");
        }
    }

    return result.toOwnedSlice(allocator);
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
    var path_it = std.mem.tokenizeAny(u8, path, tokens);
    var ancestor_it = std.mem.tokenizeAny(u8, ancestor, tokens);

    if (prefixMatches(&path_it, &ancestor_it)) {
        var start = path_it.next() orelse return ".";
        while (std.mem.eql(u8, start, ".")) {
            start = path_it.next() orelse return ".";
        }

        return path[(@intFromPtr(start.ptr) - @intFromPtr(path.ptr))..];
    } else {
        return path;
    }
}

fn prefixMatches(path_it: *std.mem.TokenIterator(u8, .any), ancestor_it: *std.mem.TokenIterator(u8, .any)) bool {
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

            var it1 = std.mem.tokenizeScalar(u8, p1, sep1);
            var it2 = std.mem.tokenizeScalar(u8, p2, sep2);

            return std.os.windows.eqlIgnoreCaseWtf8(it1.next().?, it2.next().?) and std.os.windows.eqlIgnoreCaseWtf8(it1.next().?, it2.next().?);
        },
    }
}

const CopyTreeError = std.Io.Dir.CopyFileError || std.Io.Dir.OpenError;

pub fn copyTree(io: std.Io, source_dir: std.Io.Dir, source_path: []const u8, dest_dir: std.Io.Dir, dest_path: []const u8, options: std.Io.Dir.CopyFileOptions) CopyTreeError!void {
    // TODO figure out how to handle symlinks better
    source_dir.copyFile(source_path, dest_dir, dest_path, io, options) catch |err| switch (err) {
        error.IsDir => {
            var src = try source_dir.openDir(io, source_path, .{ .follow_symlinks = false, .iterate = true });
            defer src.close(io);

            var dest = try dest_dir.createDirPathOpen(io, dest_path, .{});
            defer dest.close(io);

            try copyDir(io, src, dest, options);
        },
        else => return err,
    };
}

fn copyDir(io: std.Io, source_dir: std.Io.Dir, dest_dir: std.Io.Dir, options: std.Io.Dir.CopyFileOptions) CopyTreeError!void {
    var iter = source_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == std.Io.File.Kind.directory) {
            var src = try source_dir.openDir(io, entry.name, .{ .follow_symlinks = false, .iterate = true });
            defer src.close(io);

            var dest = try dest_dir.createDirPathOpen(io, entry.name, .{});
            defer dest.close(io);

            try copyDir(io, src, dest, options);
        } else {
            try copyTree(io, source_dir, entry.name, dest_dir, entry.name, options);
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
