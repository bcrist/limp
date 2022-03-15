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

        // .{ .name = "remove", .func = fs_path_remove },
        // .{ .name = "move", .func = fs_path_remove },
        // .{ .name = "create_dirs", .func = fs_create_dirs },
        // .{ .name = "get_files", .func = fs_get_files },
        // .{ .name = "get_dirs", .func = fs_get_dirs },

        .{ .name = null, .func = null },
    };

    c.lua_createtable(l, 0, funcs.len - 1);
    c.luaL_setfuncs(l, &funcs, 0);
    return 1;
}

fn fsAbsolutePath(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var result = fs.toAbsolute(alloc, path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsCanonicalPath(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var result = std.fs.cwd().realpathAlloc(alloc, path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsComposePath(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};
    var alloc = temp.allocator();

    const count = c.lua_gettop(l);
    std.debug.assert(count >= 0);
    var paths = alloc.alloc([]const u8, @intCast(usize, count)) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        const p = @intCast(usize, i - 1);
        paths[p].ptr = c.luaL_checklstring(l, i, &paths[p].len);
    }

    const result = fs.composePath(alloc, paths, 0) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsComposePathSlash(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};
    var alloc = temp.allocator();

    const count = c.lua_gettop(l);
    std.debug.assert(count >= 0);
    var paths = alloc.alloc([]const u8, @intCast(usize, count)) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        const p = @intCast(usize, i - 1);
        paths[p].ptr = c.luaL_checklstring(l, i, &paths[p].len);
    }

    const result = fs.composePath(alloc, paths, '/') catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
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
            defer temp.reset(65536) catch {};
            var alloc = temp.allocator();

            var search_path: []const u8 = undefined;
            search_path.ptr = c.luaL_checklstring(l, 2, &search_path.len);

            const parts = [_][]const u8{ search_path, path };
            var combined = fs.composePath(alloc, &parts, 0) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err));
                unreachable;
            };

            std.fs.cwd().access(combined, .{}) catch |err| switch (err) {
                error.FileNotFound, error.BadPathName, error.InvalidUtf8, error.NameTooLong => {
                    break :blk;
                },
                else => {
                    _ = c.luaL_error(l, fs.errorName(err));
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
            defer temp.reset(65536) catch {};
            var alloc = temp.allocator();

            const cwd = std.process.getCwdAlloc(alloc) catch |err| {
                _ = c.luaL_error(l, fs.errorName(err));
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
    defer temp.reset(65536) catch {};
    var alloc = temp.allocator();

    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    var new_ext: []const u8 = undefined;
    new_ext.ptr = c.luaL_checklstring(l, 2, &new_ext.len);

    var result = fs.replaceExtension(alloc, path, new_ext) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsCwd(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};
    var alloc = temp.allocator();

    const result = std.process.getCwdAlloc(alloc) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    _ = c.lua_pushlstring(l, result.ptr, result.len);
    return 1;
}

fn fsSetCwd(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    std.os.chdir(path) catch |err| {
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    return 0;
}

fn fsStat(l: L) callconv(.C) c_int {
    var path: []const u8 = undefined;
    path.ptr = c.luaL_checklstring(l, 1, &path.len);

    c.lua_settop(l, 0);
    c.lua_createtable(l, 0, 5);

    if (std.fs.cwd().statFile(path)) |stat| {
        _ = c.lua_pushstring(l, "size");
        if (stat.size > std.math.maxInt(c.lua_Integer)) {
            c.lua_pushinteger(l, std.math.maxInt(c.lua_Integer));
        } else {
            c.lua_pushinteger(l, @intCast(c.lua_Integer, stat.size));
        }

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
        _ = c.lua_pushlstring(l, kind.ptr, kind.len);

        _ = c.lua_pushstring(l, "atime");
        c.lua_pushinteger(l, @intCast(c.lua_Integer, @divFloor(stat.atime, 1000000)));

        _ = c.lua_pushstring(l, "mtime");
        c.lua_pushinteger(l, @intCast(c.lua_Integer, @divFloor(stat.mtime, 1000000)));

        _ = c.lua_pushstring(l, "ctime");
        c.lua_pushinteger(l, @intCast(c.lua_Integer, @divFloor(stat.ctime, 1000000)));
    } else |err| switch (err) {
        error.FileNotFound, error.BadPathName, error.InvalidUtf8, error.NameTooLong => {
            _ = c.lua_pushstring(l, "size");
            c.lua_pushnil(l);
            _ = c.lua_pushstring(l, "kind");
            c.lua_pushnil(l);
            _ = c.lua_pushstring(l, "atime");
            c.lua_pushnil(l);
            _ = c.lua_pushstring(l, "mtime");
            c.lua_pushnil(l);
            _ = c.lua_pushstring(l, "ctime");
            c.lua_pushnil(l);
        },
        else => {
            _ = c.luaL_error(l, fs.errorName(err));
            unreachable;
        },
    }

    c.lua_rawset(l, 1);
    c.lua_rawset(l, 1);
    c.lua_rawset(l, 1);
    c.lua_rawset(l, 1);
    c.lua_rawset(l, 1);
    return 1;
}

fn fsGetFileContents(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};
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
            _ = c.luaL_error(l, fs.errorName(err));
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
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };
    // We can't defer af.deinit(); because luaL_error longjmps away.

    af.file.writeAll(contents) catch |err| {
        af.deinit();
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    af.finish() catch |err| {
        af.deinit();
        _ = c.luaL_error(l, fs.errorName(err));
        unreachable;
    };

    af.deinit();
    return 0;
}

// int fs_is_dir(lua_State* L) {
//    Path p(luaL_checkstring(L, 1));
//    lua_pushboolean(L, fs::is_directory(p));
//    return 1;
// }

// int fs_cwd(lua_State* L) {
//    lua_pushstring(L, util::cwd().string().c_str());
//    return 1;
// }

// int fs_create_dirs(lua_State* L) {
//    Path p(luaL_checkstring(L, 1));
//    lua_pushboolean(L, fs::create_directories(p));
//    return 1;
// }

// int fs_file_mtime(lua_State* L) {
//    auto time_pt = fs::last_write_time(luaL_checkstring(L, 1));
//    time_t mtime = decltype(time_pt)::clock::to_time_t(time_pt);
//    lua_pushinteger(L, lua_Integer(mtime));
//    return 1;
// }

// int fs_path_remove(lua_State* L) {
//    lua_pushboolean(L, fs::remove(luaL_checkstring(L, 1)) ? 1 : 0);
//    return 1;
// }

// fn fsExists(l: L) callconv(.C) c_int {
//     var path: []const u8 = undefined;
//     path.ptr = c.luaL_checklstring(l, 1, &path.len);

//     var result: c_int = 1;
//     std.fs.cwd().access(path, .{}) catch |err| switch (err) {
//         error.FileNotFound, error.BadPathName, error.InvalidUtf8, error.NameTooLong => {
//             result = 0;
//         },
//         else => {
//             _ = c.luaL_error(l, fs.errorName(err));
//             unreachable;
//         },
//     };

//     c.lua_pushboolean(l, result);
//     return 1;
// }

// int fs_path_equivalent(lua_State* L) {
//    std::size_t len;
//    const char* ptr = luaL_checklstring(L, 1, &len);
//    S a(ptr, len);
//    ptr = luaL_checklstring(L, 2, &len);
//    S b(ptr, len);

//    lua_pushboolean(L, fs::equivalent(a, b) ? 1 : 0);
//    return 1;
// }

// // return names of all non-directory files in the specified directory, or cwd if no dir specified
// int fs_get_files(lua_State* L) {
//    Path p;
//    int count = 0;
//    if (lua_gettop(L) == 0) {
//       p = fs::current_path();
//    } else {
//       p = luaL_checkstring(L, 1);
//    }

//    try {
//       if (fs::exists(p) && fs::is_directory(p)) {
//          for (fs::directory_iterator i(p), end; i != end; ++i) {
//             const Path& ipath = i->path();
//             if (fs::is_regular_file(ipath)) {
//                lua_checkstack(L, 1);
//                lua_pushstring(L, ipath.filename().string().c_str());
//                ++count;
//             }
//          }
//       } else {
//          return luaL_error(L, "Specified path is not a directory!");
//       }
//    } catch (fs::filesystem_error& e) {
//       return luaL_error(L, e.what());
//    }
//    return count;
// }

// // return names of all directories in the specified directory, or cwd if no dir specified
// int fs_get_dirs(lua_State* L) {
//    Path p;
//    int count = 0;
//    if (lua_gettop(L) == 0) {
//       p = fs::current_path();
//    } else {
//       p = luaL_checkstring(L, 1);
//    }

//    try {
//       if (fs::exists(p) && fs::is_directory(p)) {
//          for (fs::directory_iterator i(p), end; i != end; ++i) {
//             const fs::path& ipath = i->path();
//             if (fs::is_directory(ipath)) {
//                lua_checkstack(L, 1);
//                lua_pushstring(L, ipath.filename().string().c_str());
//                ++count;
//             }
//          }
//       } else {
//          return luaL_error(L, "Specified path is not a directory!");
//       }
//    } catch (fs::filesystem_error& e) {
//       return luaL_error(L, e.what());
//    }
//    return count;
// }

// int fs_find_file(lua_State* L) {
//    Path filename(luaL_checkstring(L, 1));

//    std::vector<Path> search_paths;

//    I32 last = lua_gettop(L);
//    for (I32 i = 2; i <= last; ++i) {
//       util::parse_multi_path(luaL_checkstring(L, i), search_paths);
//    }

//    if (search_paths.empty()) {
//       search_paths.push_back(util::cwd());
//    }

//    filename = util::find_file(filename, search_paths);
//    if (filename.empty()) {
//       return 0;
//    } else {
//       lua_pushstring(L, filename.string().c_str());
//       return 1;
//    }
// }

// int fs_glob(lua_State* L) {
//    std::size_t len;
//    const char* ptr = luaL_checklstring(L, 1, &len);
//    S pattern(ptr, len);

//    std::vector<Path> search_paths;

//    if (!lua_isnoneornil(L, 2)) {
//       if (lua_type(L, 2) == LUA_TTABLE) {
//          lua_pushnil(L);
//          while (lua_next(L, 2) != 0) {
//             ptr = luaL_tolstring(L, -1, &len);
//             S str(ptr, len);
//             lua_pop(L, 2);
//             util::parse_multi_path(str, search_paths);
//          }
//       } else {
//          ptr = luaL_tolstring(L, 2, &len);
//          S str(ptr, len);
//          lua_pop(L, 1);
//          util::parse_multi_path(str, search_paths);
//       }
//    }

//    if (search_paths.empty()) {
//       search_paths.push_back(util::cwd());
//    }

//    util::PathMatchType type = util::PathMatchType::all;

//    if (!lua_isnoneornil(L, 3)) {
//       U8 type_mask = 0;
//       ptr = lua_tolstring(L, 3, &len);
//       S typestr(ptr, len);
//       if (std::find(typestr.begin(), typestr.end(), 'f') != typestr.end()) {
//          type_mask |= static_cast<U8>(util::PathMatchType::files);
//       }
//       if (std::find(typestr.begin(), typestr.end(), 'd') != typestr.end()) {
//          type_mask |= static_cast<U8>(util::PathMatchType::directories);
//       }
//       if (std::find(typestr.begin(), typestr.end(), '?') != typestr.end()) {
//          type_mask |= static_cast<U8>(util::PathMatchType::misc);
//       }
//       if (std::find(typestr.begin(), typestr.end(), 'r') != typestr.end()) {
//          type_mask |= static_cast<U8>(util::PathMatchType::recursive);
//       }
//       type = static_cast<util::PathMatchType>(type_mask);
//    }

//    std::vector<Path> paths = util::glob(pattern, search_paths, type);

//    lua_settop(L, 0);
//    if (paths.size() > (std::size_t)std::numeric_limits<int>::max() || !lua_checkstack(L, (int)paths.size())) {
//       luaL_error(L, "Too many paths to return on stack!");
//       // TODO consider returning a table (sequence) instead to avoid this issue
//    }

//    for (Path& p : paths) {
//       S str = p.string();
//       lua_pushlstring(L, str.c_str(), str.length());
//    }

//    return (int)paths.size();
// }

