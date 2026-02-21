const std = @import("std");
const globals = @import("globals.zig");
const fs = @import("fs.zig");
const lua = @import("lua.zig");
const c = lua.c;
const L = ?*c.lua_State;

pub export fn registerFsLib(l: L) c_int {
    c.luaL_requiref(l, "fs", openFs, 1);
    return 0;
}

fn openFs(l: L) callconv(.c) c_int {
    var funcs = [_]c.luaL_Reg{
        .{ .name = "absolute_path", .func = fsAbsolutePath },
        .{ .name = "canonical_path", .func = fsCanonicalPath },
        .{ .name = "compose_path", .func = fsComposePath },
        .{ .name = "compose_path_slash", .func = fsComposePathSlash },
        .{ .name = "parent_path", .func = fsParentPath },
        .{ .name = "ancestor_relative_path", .func = fsAncestorRelativePath },
        .{ .name = "resolve_path", .func = fsResolvePath },
        .{ .name = "path_stem", .func = fsPathStem },
        .{ .name = "path_filename", .func = fsPathFilename },
        .{ .name = "path_extension", .func = fsPathExtension },
        .{ .name = "replace_extension", .func = fsReplaceExtension },
        .{ .name = "cwd", .func = fsCwd },
        .{ .name = "set_cwd", .func = fsSetCwd },
        .{ .name = "stat", .func = fsStat },
        .{ .name = "get_file_contents", .func = fsGetFileContents },
        .{ .name = "put_file_contents", .func = fsPutFileContents },
        .{ .name = "move", .func = fsMove },
        .{ .name = "copy", .func = fsCopy },
        .{ .name = "delete", .func = fsDelete },
        .{ .name = "ensure_dir_exists", .func = fsEnsureDirExists },
        .{ .name = "visit", .func = fsVisit },
        .{ .name = null, .func = null },
    };

    c.lua_createtable(l, 0, funcs.len - 1);
    c.luaL_setfuncs(l, &funcs, 0);
    return 1;
}

fn fsAbsolutePath(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    const alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const result = fs.toAbsolute(globals.io, alloc, path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsCanonicalPath(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    const alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const result = std.Io.Dir.cwd().realPathFileAlloc(globals.io, path, alloc) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsComposePath(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    var alloc = temp.allocator();

    const count = c.lua_gettop(l);
    std.debug.assert(count >= 0);
    var paths = alloc.alloc([]const u8, @intCast(count)) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        const p: usize = @intCast(i - 1);
        paths[p].ptr = c.luaL_checklstring(l, i, &paths[p].len);
    }

    const result = fs.composePath(alloc, paths, 0) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsComposePathSlash(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    var alloc = temp.allocator();

    const count = c.lua_gettop(l);
    std.debug.assert(count >= 0);
    var paths = alloc.alloc([]const u8, @intCast(count)) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        const p: usize = @intCast(i - 1);
        paths[p].ptr = c.luaL_checklstring(l, i, &paths[p].len);
    }

    const result = fs.composePath(alloc, paths, '/') catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsParentPath(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);
    const result = std.Io.Dir.path.dirname(path) orelse "";

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsAncestorRelativePath(l: L) callconv(.c) c_int {
    var child: []const u8 = undefined;
    var ancestor: []const u8 = undefined;
    child.ptr = c.luaL_checklstring(l, 1, &child.len);
    ancestor.ptr = c.luaL_checklstring(l, 2, &ancestor.len);
    const result = fs.pathRelativeToAncestor(child, ancestor);
    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

// function resolve_path (path, search_paths, include_cwd)
fn fsResolvePath(l: L) callconv(.c) c_int {
    if (c.lua_isnoneornil(l, 1)) {
        return 0;
    }

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    if (!c.lua_isnoneornil(l, 2)) blk: {
        if (c.lua_type(l, 2) == c.LUA_TTABLE) {
            c.lua_pushnil(l);
            while (c.lua_next(l, 2) != 0) {
                c.lua_pushcfunction(l, fsResolvePath);
                c.lua_pushvalue(l, 1);
                c.lua_pushvalue(l, -3);
                c.lua_callk(l, 2, 1, 0, null); // resolve_path(input_path, search_paths[k])
                if (!c.lua_isnoneornil(l, -1)) {
                    return 1;
                }
                c.lua_pop(l, 2); // value, and returned nil
            }
        } else {
            var temp = lua.getTempAlloc(l);
            defer temp.reset(.{});
            const alloc = temp.allocator();

            var search_path: []const u8 = undefined;
            search_path.ptr = c.luaL_checklstring(l, 2, &search_path.len);

            const parts = [_][]const u8{ search_path, path };
            const combined = fs.composePath(alloc, &parts, 0) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };

            std.Io.Dir.cwd().access(globals.io, combined, .{}) catch |err| switch (err) {
                error.FileNotFound, error.BadPathName, error.NameTooLong => {
                    break :blk;
                },
                else => {
                    _ = c.luaL_error(l, fs.errorName(err).ptr);
                    unreachable;
                },
            };

            _ = c.lua_pushlstring(l, combined.ptr, combined.len);
            return 1;
        }
    }

    if (c.lua_toboolean(l, 3) != 0) {
        c.lua_pushcfunction(l, fsResolvePath);
        c.lua_pushvalue(l, 1);
        {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const n = std.process.currentPath(globals.io, &buf) catch |err| switch (err) {
                error.NameTooLong => unreachable,
                else => |err| {
                    _ = c.luaL_error(l, fs.errorName(err).ptr);
                    unreachable;
                },
            };
            _ = c.lua_pushlstring(l, (&buf).ptr, n);
        }
        c.lua_callk(l, 2, 1, 0, null); // resolve_path(input_path, cwd)
        if (!c.lua_isnoneornil(l, -1)) {
            return 1;
        }
    }

    return 0;
}

fn fsPathStem(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var filename = std.Io.Dir.path.basename(path);
    const index = std.mem.lastIndexOfScalar(u8, filename, '.') orelse 0;
    if (index > 0) filename = filename[0..index];

    _ = c.lua_pushlstring(l, filename.ptr, filename.len);
    return 1;
}

fn fsPathFilename(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const result = std.Io.Dir.path.basename(path);
    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsPathExtension(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const result = std.Io.Dir.path.extension(path);
    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsReplaceExtension(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    const alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var new_ext: []const u8 = undefined;
    new_ext.ptr = c.luaL_checklstring(l, 2, &new_ext.len);

    const result = fs.replaceExtension(alloc, path, new_ext) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsCwd(l: L) callconv(.c) c_int {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(globals.io, &buf) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, (&buf).ptr, n);
    return 1;
}

fn fsSetCwd(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var dir = std.Io.Dir.cwd().openDir(globals.io, path, .{}) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    std.process.setCurrentDir(globals.io, dir) catch |err| {
        dir.close(globals.io);
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    dir.close(globals.io);
    return 0;
}

fn fsStat(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var exists = true;
    var stat = std.Io.File.Stat {
        .inode = 0,
        .nlink = 0,
        .size = 0,
        .permissions = .default_file,
        .kind = std.Io.File.Kind.unknown,
        .atime = null,
        .mtime = .zero,
        .ctime = .zero,
        .block_size = 0,
    };
    if (std.Io.Dir.cwd().statFile(globals.io, path, .{ .follow_symlinks = true })) |s| {
        stat = s;
    } else |statFileErr| switch (statFileErr) {
        error.IsDir => {
            var dir = std.Io.Dir.cwd().openDir(globals.io, path, .{}) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };
            stat = dir.stat(globals.io) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };
        },
        error.FileNotFound, error.BadPathName, error.NameTooLong => {
            exists = false;
        },
        else => {
            _ = c.luaL_error(l, fs.errorName(statFileErr).ptr);
            unreachable;
        },
    }

    c.lua_settop(l, 0);
    c.lua_createtable(l, 0, 5);

    _ = c.lua_pushstring(l, "size");
    if (stat.size > std.math.maxInt(c.lua_Integer)) {
        c.lua_pushinteger(l, std.math.maxInt(c.lua_Integer));
    } else {
        c.lua_pushinteger(l, @intCast(stat.size));
    }
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "kind");
    var kind = switch (stat.kind) {
        .block_device => "block_device",
        .character_device => "char_device",
        .directory => "dir",
        .named_pipe => "pipe",
        .sym_link => "symlink",
        .file => "file",
        .unix_domain_socket => "socket",
        .whiteout => "whiteout",
        .door => "door",
        .event_port => "event_port",
        .unknown => "unknown",
    };
    if (!exists) kind = "";
    _ = c.lua_pushlstring(l, kind.ptr, kind.len);
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "mode");
    c.lua_pushinteger(l, @intCast(@intFromEnum(stat.permissions)));
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "atime");
    if (stat.atime) |time| {
        c.lua_pushinteger(l, time.toMilliseconds());
    } else {
        c.lua_pushnil(l);
    }
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "mtime");
    c.lua_pushinteger(l, stat.mtime.toMilliseconds());
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "ctime");
    c.lua_pushinteger(l, stat.ctime.toMilliseconds());
    c.lua_rawset(l, 1);
    return 1;
}

fn fsGetFileContents(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    const alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const max_size_c = c.lua_tointegerx(l, 2, null);
    const max_size: usize = if (max_size_c <= 0) 5_000_000_000 else @intCast(max_size_c);

    const result = std.Io.Dir.cwd().readFileAlloc(globals.io, path, alloc, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound, error.BadPathName, error.NameTooLong => {
            return 0;
        },
        else => {
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        },
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsPutFileContents(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var contents: []const u8 = undefined;
    contents.ptr = c.luaL_tolstring(l, 2, &contents.len);

    const use_hardlink = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;

    var af = std.Io.Dir.cwd().createFileAtomic(globals.io, path, .{
        .make_path = true,
        .replace = !use_hardlink,
    }) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };
    // We can't defer af.deinit(); because luaL_error longjmps away.

    var buf: [16384]u8 = undefined;
    var writer = af.file.writer(globals.io, &buf);

    writer.interface.writeAll(contents) catch |err| {
        af.deinit(globals.io);
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    writer.interface.flush() catch |err| {
        af.deinit(globals.io);
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    if (use_hardlink) {
        af.link(globals.io) catch |err| {
            af.deinit(globals.io);
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        };
    } else {
        af.replace(globals.io) catch |err| {
            af.deinit(globals.io);
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        };
    }

    af.deinit(globals.io);
    return 0;
}

fn fsMove(l: L) callconv(.c) c_int {
    var src_path: []const u8 = undefined;
    src_path.ptr = c.luaL_checklstring(l, 1, &src_path.len);

    var dest_path: []const u8 = undefined;
    dest_path.ptr = c.luaL_checklstring(l, 2, &dest_path.len);

    const force = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;

    if (!force) {
        var exists = true;
        std.Io.Dir.cwd().access(globals.io, dest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => exists = false,
            else => {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            }
        };
        if (exists) {
            _ = c.luaL_error(l, fs.errorName(error.PathAlreadyExists).ptr);
            unreachable;
        }
    }

    std.Io.Dir.cwd().rename(src_path, std.Io.Dir.cwd(), dest_path, globals.io) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsCopy(l: L) callconv(.c) c_int {
    var src_path: []const u8 = undefined;
    src_path.ptr = c.luaL_checklstring(l, 1, &src_path.len);

    var dest_path: []const u8 = undefined;
    dest_path.ptr = c.luaL_checklstring(l, 2, &dest_path.len);

    const force = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;

    if (!force) {
        var exists = true;
        std.Io.Dir.cwd().access(globals.io, dest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => exists = false,
            else => {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            }
        };
        if (exists) {
            _ = c.luaL_error(l, fs.errorName(error.PathAlreadyExists).ptr);
            unreachable;
        }
    }

    fs.copyTree(globals.io, std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, .{}) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsDelete(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const recursive = c.lua_gettop(l) >= 2 and c.lua_toboolean(l, 2) != 0;

    std.Io.Dir.cwd().deleteFile(globals.io, path) catch |deleteFileErr| switch (deleteFileErr) {
        error.IsDir => {
            if (recursive) {
                std.Io.Dir.cwd().deleteTree(globals.io, path) catch |err| {
                    _ = c.luaL_error(l, fs.errorName(err).ptr);
                    unreachable;
                };
            } else {
                std.Io.Dir.cwd().deleteDir(globals.io, path) catch |err| {
                    _ = c.luaL_error(l, fs.errorName(err).ptr);
                    unreachable;
                };
            }
        },
        else => {
            _ = c.luaL_error(l, fs.errorName(deleteFileErr).ptr);
            unreachable;
        }
    };

    return 0;
}

fn fsEnsureDirExists(l: L) callconv(.c) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    std.Io.Dir.cwd().createDirPath(globals.io, path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsVisit(l: L) callconv(.c) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(.{});
    const alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const recursive = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;
    const no_follow = c.lua_gettop(l) >= 4 and c.lua_toboolean(l, 4) != 0;

    var dir = std.Io.Dir.cwd().openDir(globals.io, path, .{ .follow_symlinks = !no_follow, .iterate = true }) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    if (recursive) {
        var walker = dir.walk(alloc) catch |err| {
            dir.close(globals.io);
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        };

        while (walker.next(globals.io) catch |err| {
            walker.deinit();
            dir.close(globals.io);
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        }) |entry| {
            const kind = @tagName(entry.kind);

            c.lua_pushvalue(l, 2);
            _ = c.lua_pushlstring(l, entry.path.ptr, entry.path.len);
            _ = c.lua_pushlstring(l, kind.ptr, kind.len);

            switch (c.lua_pcallk(l, 2, 0, 0, 0, null)) {
                c.LUA_OK => {},
                c.LUA_ERRMEM => {
                    walker.deinit();
                    dir.close(globals.io);
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
                c.LUA_ERRERR => {
                    walker.deinit();
                    dir.close(globals.io);
                    _ = c.lua_error(l);
                    unreachable;
                },
                else => {
                    walker.deinit();
                    dir.close(globals.io);
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
            }
        }
        walker.deinit();

    } else {
        var iter = dir.iterate();
        while (iter.next(globals.io) catch |err| {
            dir.close(globals.io);
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        }) |entry| {
            const kind = @tagName(entry.kind);

            c.lua_pushvalue(l, 2);
            _ = c.lua_pushlstring(l, entry.name.ptr, entry.name.len);
            _ = c.lua_pushlstring(l, kind.ptr, kind.len);

            switch (c.lua_pcallk(l, 2, 0, 0, 0, null)) {
                c.LUA_OK => {},
                c.LUA_ERRMEM => {
                    dir.close(globals.io);
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
                c.LUA_ERRERR => {
                    dir.close(globals.io);
                    _ = c.lua_error(l);
                    unreachable;
                },
                else => {
                    dir.close(globals.io);
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
            }
        }
    }
    dir.close(globals.io);

    return 0;
}
