const std = @import("std");
const root = @import("root");
const globals = @import("globals.zig");
const sx = @import("sx");
const lua = @import("lua.zig");
const c = lua.c;
const L = ?*c.lua_State;

//[[!! quiet() fs.put_file_contents('lua-sexpr.bc.lua', string.dump(load_file('lua-sexpr.lua'))) !! 1 ]]
const init_src = @embedFile("lua-sexpr.bc.lua");

pub export fn registerSExprLib(l: L) c_int {
    c.luaL_requiref(l, "sx", openSx, 1);
    return 0;
}

fn openSx(l: L) callconv(.c) c_int {
    var parser_funcs = [_]c.luaL_Reg {
        .{ .name = "__gc", .func = parser__gc },
        .{ .name = "open", .func = parser_open },
        .{ .name = "close", .func = parser_close },
        .{ .name = "done", .func = parser_done },
        .{ .name = "expression", .func = parser_expression },
        .{ .name = "string", .func = parser_string },
        .{ .name = "float", .func = parser_float },
        .{ .name = "int", .func = parser_int },
        .{ .name = "unsigned", .func = parser_unsigned },
        .{ .name = "ignore_remaining_expression", .func = parser_ignore_remaining_expression },
        .{ .name = "print_parse_error_context", .func = parser_print_parse_error_context },
        .{ .name = null, .func = null },
    };
    _ = c.luaL_newmetatable(l, "class SxParser");
    c.luaL_setfuncs(l, &parser_funcs, 0);
    _ = c.lua_pushstring(l, "__index");
    c.lua_pushvalue(l, -2);
    c.lua_rawset(l, -1);

    const chunk: []const u8 = init_src;
    switch (c.luaL_loadbufferx(l, chunk.ptr, chunk.len, "sx init", null)) {
        c.LUA_OK => {},
        c.LUA_ERRMEM => {
            _ = c.luaL_error(l, "Out of memory");
            unreachable;
        },
        else => {
            _ = c.luaL_error(l, "Syntax error in sexpr init");
            unreachable;
        },
    }
    c.lua_pushvalue(l, -2);
    c.lua_callk(l, 1, 0, 0, null);

    var funcs = [_]c.luaL_Reg {
        .{ .name = "parser", .func = sexprParser },
        .{ .name = null, .func = null },
    };

    c.lua_createtable(l, 0, funcs.len - 1);
    c.luaL_setfuncs(l, &funcs, 0);
    return 1;
}

const Parser = struct {
    stream_reader: std.Io.Reader,
    reader: sx.Reader,
};

fn sexprParser(l: L) callconv(.c) c_int {
    var source: []const u8 = undefined;
    source.ptr = c.luaL_checklstring(l, 1, &source.len);

    const num_params = c.lua_gettop(l);
    if (num_params > 1) {
        _ = c.luaL_error(l, "Expected 1 parameter (source s-expression text)");
        unreachable;
    }

    var parser: *Parser = @ptrCast(@alignCast(c.lua_newuserdata(l, @sizeOf(Parser))));
    c.luaL_setmetatable(l, "class SxParser");

    var alloc = globals.gpa;

    const ownedSource: []const u8 = alloc.dupe(u8, source) catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    };

    parser.stream_reader = std.Io.Reader.fixed(ownedSource);
    parser.reader = sx.reader(alloc, &parser.stream_reader);

    return 1;
}

fn parser__gc(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    parser.reader.deinit();
    globals.gpa.free(parser.stream_reader.buffer);
    return 0;
}

fn parser_open(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.reader.open() catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    }) {
        c.lua_pushboolean(l, 1);
    } else {
        c.lua_pushboolean(l, 0);
    }
    return 1;
}

fn parser_close(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.reader.close() catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    }) {
        c.lua_pushboolean(l, 1);
    } else {
        c.lua_pushboolean(l, 0);
    }
    return 1;
}

fn parser_done(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.reader.done() catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    }) {
        c.lua_pushboolean(l, 1);
    } else {
        c.lua_pushboolean(l, 0);
    }
    return 1;
}

fn parser_expression(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        var expected: []const u8 = undefined;
        expected.ptr = c.luaL_checklstring(l, 2, &expected.len);

        if (parser.reader.expression(expected) catch |e| {
            _ = c.luaL_error(l, @errorName(e).ptr);
            unreachable;
        }) {
            c.lua_pushboolean(l, 1);
        } else {
            c.lua_pushboolean(l, 0);
        }
        return 1;
    } else {
        if (parser.reader.any_expression() catch |e| {
            _ = c.luaL_error(l, @errorName(e).ptr);
            unreachable;
        }) |val| {
            _ = c.lua_pushlstring(l, val.ptr, val.len);
        } else {
            c.lua_pushnil(l);
        }
        return 1;
    }
}

fn parser_string(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
     if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        var expected: []const u8 = undefined;
        expected.ptr = c.luaL_checklstring(l, 2, &expected.len);

        if (parser.reader.string(expected) catch |e| {
            _ = c.luaL_error(l, @errorName(e).ptr);
            unreachable;
        }) {
            c.lua_pushboolean(l, 1);
        } else {
            c.lua_pushboolean(l, 0);
        }
        return 1;
    } else {
        if (parser.reader.any_string() catch |e| {
            _ = c.luaL_error(l, @errorName(e).ptr);
            unreachable;
        }) |val| {
            _ = c.lua_pushlstring(l, val.ptr, val.len);
        } else {
            c.lua_pushnil(l);
        }
        return 1;
    }
}

fn parser_float(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.reader.any_float(c.lua_Number) catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    }) |val| {
        _ = c.lua_pushnumber(l, val);
    } else {
        c.lua_pushnil(l);
    }
    return 1;
}

fn parser_int(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));

    var radix: u8 = 10;
    if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        radix = @intCast(std.math.clamp(c.luaL_checkinteger(l, 2), 0, 36));
    }

    if (parser.reader.any_int(c.lua_Integer, radix) catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    }) |val| {
        _ = c.lua_pushinteger(l, val);
    } else {
        c.lua_pushnil(l);
    }
    return 1;
}

fn parser_unsigned(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));

    var radix: u8 = 10;
    if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        radix = @intCast(std.math.clamp(c.luaL_checkinteger(l, 2), 0, 36));
    }

    if (parser.reader.any_unsigned(u32, radix) catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    }) |val| {
        _ = c.lua_pushinteger(l, @intCast(val));
    } else {
        c.lua_pushnil(l);
    }
    return 1;
}

fn parser_ignore_remaining_expression(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    parser.reader.ignore_remaining_expression() catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    };
    return 0;
}

fn parser_print_parse_error_context(l: L) callconv(.c) c_int {
    var parser: *Parser = @ptrCast(@alignCast(c.luaL_checkudata(l, 1, "class SxParser")));
    var ctx = parser.reader.token_context() catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    };
    ctx.print_for_string(parser.stream_reader.buffer, root.stderr, 150) catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    };
    root.stderr.flush() catch |e| {
        _ = c.luaL_error(l, @errorName(e).ptr);
        unreachable;
    };
    return 0;
}
