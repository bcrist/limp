const std = @import("std");
const allocators = @import("allocators.zig");
const zlib = @import("zlib.zig");
const lua = @import("lua.zig");
const c = lua.c;
const L = ?*c.lua_State;

pub export fn registerUtilLib(l: L) c_int {
    c.luaL_requiref(l, "util", openUtil, 1);
    return 0;
}

fn openUtil(l: L) callconv(.C) c_int {
    var funcs = [_]c.luaL_Reg{
        .{ .name = "deflate", .func = utilDeflate },
        .{ .name = "inflate", .func = utilInflate },
        .{ .name = null, .func = null },
    };

    c.lua_createtable(l, 0, funcs.len - 1);
    c.luaL_setfuncs(l, &funcs, 0);
    return 1;
}

fn utilDeflate(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};

    var uncompressed: []const u8 = undefined;
    uncompressed.ptr = c.luaL_checklstring(l, 1, &uncompressed.len);

    var num_params = c.lua_gettop(l);
    if (num_params > 3) {
        _ = c.luaL_error(l, "Expected 1 to 3 parameters (data, level, encode_length)");
        unreachable;
    }

    var level: i8 = 8;
    if (num_params >= 2) {
        level = @intCast(i8, c.luaL_checkinteger(l, 2));
    }

    var encode_length = false;
    if (c.lua_gettop(l) >= 3) {
        if (!c.lua_isboolean(l, 3)) {
            _ = c.luaL_error(l, "Expected third parameter to be a boolean (encode_length)");
            unreachable;
        }
        encode_length = c.lua_toboolean(l, 3) != 0;
    }

    var compressed = zlib.deflate(temp, uncompressed, encode_length, level) catch |err| {
        var error_name: [:0]const u8 = undefined;
        switch (err) {
            error.OutOfMemory => error_name = "Out of memory",
            error.InvalidLevel => error_name = "Invalid compression level",
            error.Unexpected => error_name = "Unexpected zlib error",
        }
        _ = c.luaL_error(l, error_name.ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, compressed.ptr, compressed.len);
    return 1;
}

fn utilInflate(l: L) callconv(.C) c_int {
    var temp = lua.getTempAlloc(l);
    defer temp.reset(65536) catch {};

    var compressed: []const u8 = undefined;
    compressed.ptr = c.luaL_checklstring(l, 1, &compressed.len);

    var uncompressed_length: usize = undefined;
    if (c.lua_gettop(l) > 1) {
        uncompressed_length = @intCast(usize, c.luaL_checkinteger(l, 2));
    } else {
        uncompressed_length = zlib.getUncompressedLength(compressed);
        compressed = zlib.stripUncompressedLength(compressed);
    }

    var uncompressed = zlib.inflate(temp, compressed, uncompressed_length) catch |err| {
        var error_name: [:0]const u8 = undefined;
        switch (err) {
            error.OutOfMemory => error_name = "Out of memory",
            error.DataCorrupted => error_name = "Data corrupted or not deflated",
            error.Unexpected => error_name = "Unexpected zlib error",
        }
        _ = c.luaL_error(l, error_name.ptr);
        unreachable;
    };

    _ = c.lua_pushlstring(l, uncompressed.ptr, uncompressed.len);
    return 1;
}
