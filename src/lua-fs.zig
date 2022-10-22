const std = @import("std");
const allocators = @import("allocators.zig");
const fs = @import("fs.zig");
const lua = @import("lua.zig");
const c = lua.c;
const L = ?*c.lua_State;

pub export fn registerFsLib(l: L) c_int {
    c.luaL_requiref(l, "fs", openFs, 1);
    return 0;
}

fn openFs(l: L) callconv(.C) c_int {
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

fn fsAbsolutePath(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var result = fs.toAbsolute(alloc, path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsCanonicalPath(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var result = std.fs.cwd().realpathAlloc(alloc, path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsComposePath(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    const count = c.lua_gettop(l);
    std.debug.assert(count >= 0);
    var paths = alloc.alloc([]const u8, @intCast(usize, count)) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        const p = @intCast(usize, i - 1);
        paths[p].ptr = c.luaL_checklstring(l, i, &paths[p].len);
    }

    const result = fs.composePath(alloc, paths, 0) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsComposePathSlash(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    const count = c.lua_gettop(l);
    std.debug.assert(count >= 0);
    var paths = alloc.alloc([]const u8, @intCast(usize, count)) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        const p = @intCast(usize, i - 1);
        paths[p].ptr = c.luaL_checklstring(l, i, &paths[p].len);
    }

    const result = fs.composePath(alloc, paths, '/') catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsParentPath(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);
    const result = std.fs.path.dirname(path) orelse "";

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsAncestorRelativePath(l: L) callconv(.C) c_int {
    var child: []const u8 = undefined;
    var ancestor: []const u8 = undefined;
    child.ptr = c.luaL_checklstring(l, 1, &child.len);
    ancestor.ptr = c.luaL_checklstring(l, 2, &ancestor.len);
    var result = fs.pathRelativeToAncestor(child, ancestor);
    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

// function resolve_path (path, search_paths, include_cwd)
fn fsResolvePath(l: L) callconv(.C) c_int {
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
            defer temp.reset();
            var alloc = temp.allocator();

            var search_path: []const u8 = undefined;
            search_path.ptr = c.luaL_checklstring(l, 2, &search_path.len);

            const parts = [_][]const u8{ search_path, path };
            var combined = fs.composePath(alloc, &parts, 0) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };

            std.fs.cwd().access(combined, .{}) catch |err| switch (err) {
                error.FileNotFound, error.BadPathName, error.InvalidUtf8, error.NameTooLong => {
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
            var temp = lua.getTempAlloc(l);
            defer temp.reset();
            var alloc = temp.allocator();

            const cwd = std.process.getCwdAlloc(alloc) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };

            _ = c.lua_pushlstring(l, cwd.ptr, cwd.len);
        }
        c.lua_callk(l, 2, 1, 0, null); // resolve_path(input_path, cwd)
        if (!c.lua_isnoneornil(l, -1)) {
            return 1;
        }
    }

    return 0;
}

fn fsPathStem(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var filename = std.fs.path.basename(path);
    const index = std.mem.lastIndexOfScalar(u8, filename, '.') orelse 0;
    if (index > 0) filename = filename[0..index];

    _ = c.lua_pushlstring(l, filename.ptr, filename.len);
    return 1;
}

fn fsPathFilename(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const result = std.fs.path.basename(path);
    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsPathExtension(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const result = std.fs.path.extension(path);
    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsReplaceExtension(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var new_ext: []const u8 = undefined;
    new_ext.ptr = c.luaL_checklstring(l, 2, &new_ext.len);

    var result = fs.replaceExtension(alloc, path, new_ext) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsCwd(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    const result = std.process.getCwdAlloc(alloc) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsSetCwd(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    std.os.chdir(path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsStat(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var exists = true;
    var stat = std.fs.File.Stat {
        .inode = 0,
        .size = 0,
        .mode = 0,
        .kind = std.fs.File.Kind.Unknown,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    if (std.fs.cwd().statFile(path)) |s| {
        stat = s;
    } else |statFileErr| switch (statFileErr) {
        error.IsDir => {
            var dir = std.fs.cwd().openDir(path, .{}) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };
            stat = dir.stat() catch |err| {
                _ = c.luaL_error(l, fs.errorName(err).ptr);
                unreachable;
            };
        },
        error.FileNotFound, error.BadPathName, error.InvalidUtf8, error.NameTooLong => {
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
        c.lua_pushinteger(l, @intCast(c.lua_Integer, stat.size));
    }
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "kind");
    var kind = switch (stat.kind) {
        .BlockDevice => "blockdevice",
        .CharacterDevice => "chardevice",
        .Directory => "dir",
        .NamedPipe => "pipe",
        .SymLink => "symlink",
        .File => "file",
        .UnixDomainSocket => "socket",
        .Whiteout => "whiteout",
        .Door => "door",
        .EventPort => "eventport",
        .Unknown => "unknown",
    };
    if (!exists) kind = "";
    _ = c.lua_pushlstring(l, kind.ptr, kind.len);
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "mode");
    c.lua_pushinteger(l, @intCast(c.lua_Integer, stat.mode));
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "atime");
    c.lua_pushinteger(l, @intCast(c.lua_Integer, @divFloor(stat.atime, 1000000)));
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "mtime");
    c.lua_pushinteger(l, @intCast(c.lua_Integer, @divFloor(stat.mtime, 1000000)));
    c.lua_rawset(l, 1);

    _ = c.lua_pushstring(l, "ctime");
    c.lua_pushinteger(l, @intCast(c.lua_Integer, @divFloor(stat.ctime, 1000000)));
    c.lua_rawset(l, 1);
    return 1;
}

fn fsGetFileContents(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    const max_size_c = c.lua_tointegerx(l, 2, null);
    const max_size: usize = if (max_size_c <= 0) 5_000_000_000 else @intCast(usize, max_size_c);

    var result = std.fs.cwd().readFileAlloc(alloc, path, max_size) catch |err| switch (err) {
        error.FileNotFound, error.BadPathName, error.InvalidUtf8, error.NameTooLong => {
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

fn fsPutFileContents(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var contents: []const u8 = undefined;
    contents.ptr = c.luaL_tolstring(l, 2, &contents.len);

    var af = std.fs.cwd().atomicFile(path, .{}) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };
    // We can't defer af.deinit(); because luaL_error longjmps away.

    af.file.writeAll(contents) catch |err| {
        af.deinit();
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    af.finish() catch |err| {
        af.deinit();
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    af.deinit();
    return 0;
}

fn fsMove(l: L) callconv(.C) c_int {
    var src_path: []const u8 = undefined;
    src_path.ptr = c.luaL_checklstring(l, 1, &src_path.len);

    var dest_path: []const u8 = undefined;
    dest_path.ptr = c.luaL_checklstring(l, 2, &dest_path.len);

    var force = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;

    if (!force) {
        var exists = true;
        std.fs.cwd().access(dest_path, .{}) catch |err| switch (err) {
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

    std.fs.cwd().rename(src_path, dest_path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsCopy(l: L) callconv(.C) c_int {
    var src_path: []const u8 = undefined;
    src_path.ptr = c.luaL_checklstring(l, 1, &src_path.len);

    var dest_path: []const u8 = undefined;
    dest_path.ptr = c.luaL_checklstring(l, 2, &dest_path.len);

    var force = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;

    if (!force) {
        var exists = true;
        std.fs.cwd().access(dest_path, .{}) catch |err| switch (err) {
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

    var cwd = std.fs.cwd();
    fs.copyTree(cwd, src_path, cwd, dest_path, .{}) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsDelete(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var recursive = c.lua_gettop(l) >= 2 and c.lua_toboolean(l, 2) != 0;

    std.fs.cwd().deleteFile(path) catch |deleteFileErr| switch (deleteFileErr) {
        error.IsDir => {
            if (recursive) {
                std.fs.cwd().deleteTree(path) catch |err| {
                    _ = c.luaL_error(l, fs.errorName(err).ptr);
                    unreachable;
                };
            } else {
                std.fs.cwd().deleteDir(path) catch |err| {
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

fn fsEnsureDirExists(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    std.fs.cwd().makePath(path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    return 0;
}

fn fsVisit(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset();
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var recursive = c.lua_gettop(l) >= 3 and c.lua_toboolean(l, 3) != 0;
    var no_follow = c.lua_gettop(l) >= 4 and c.lua_toboolean(l, 4) != 0;

    var dir = std.fs.cwd().openIterableDir(path, .{ .no_follow = no_follow }) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err).ptr);
        unreachable;
    };

    if (recursive) {
        var walker = dir.walk(alloc) catch |err| {
            dir.close();
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        };

        while (walker.next() catch |err| {
            walker.deinit();
            dir.close();
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        }) |entry| {
            var kind = @tagName(entry.kind);

            c.lua_pushvalue(l, 2);
            _ = c.lua_pushlstring(l, entry.path.ptr, entry.path.len);
            _ = c.lua_pushlstring(l, kind.ptr, kind.len);

            switch (c.lua_pcallk(l, 2, 0, 0, 0, null)) {
                c.LUA_OK => {},
                c.LUA_ERRMEM => {
                    walker.deinit();
                    dir.close();
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
                c.LUA_ERRERR => {
                    walker.deinit();
                    dir.close();
                    _ = c.lua_error(l);
                    unreachable;
                },
                else => {
                    walker.deinit();
                    dir.close();
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
            }
        }
        walker.deinit();

    } else {
        var iter = dir.iterate();
        while (iter.next() catch |err| {
            dir.close();
            _ = c.luaL_error(l, fs.errorName(err).ptr);
            unreachable;
        }) |entry| {
            var kind = @tagName(entry.kind);

            c.lua_pushvalue(l, 2);
            _ = c.lua_pushlstring(l, entry.name.ptr, entry.name.len);
            _ = c.lua_pushlstring(l, kind.ptr, kind.len);

            switch (c.lua_pcallk(l, 2, 0, 0, 0, null)) {
                c.LUA_OK => {},
                c.LUA_ERRMEM => {
                    dir.close();
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
                c.LUA_ERRERR => {
                    dir.close();
                    _ = c.lua_error(l);
                    unreachable;
                },
                else => {
                    dir.close();
                    _ = c.luaL_error(l, "Lua Runtime Error");
                    unreachable;
                },
            }
        }
    }
    dir.close();

    return 0;
}
