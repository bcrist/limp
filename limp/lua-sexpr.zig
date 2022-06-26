const std = @import("std");
const allocators = @import("allocators.zig");
const sexpr = @import("sexpr.zig");
const lua = @import("lua.zig");
const c = lua.c;
const L = ?*c.lua_State;

//[[!! quiet() fs.put_file_contents('lua-sexpr.bc.lua', string.dump(load_file('lua-sexpr.lua'))) !! 1 ]]
const init_src = @embedFile("lua-sexpr.bc.lua");

pub export fn registerSExprLib(l: L) c_int {
    c.luaL_requiref(l, "sx", openSx, 1);
    return 0;
}

fn openSx(l: L) callconv(.C) c_int {
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

fn sexprParser(l: L) callconv(.C) c_int {
    var source: []const u8 = undefined;
    source.ptr = c.luaL_checklstring(l, 1, &source.len);

    var num_params = c.lua_gettop(l);
    if (num_params > 1) {
        _ = c.luaL_error(l, "Expected 1 parameter (source s-expression text)");
        unreachable;
    }

    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.lua_newuserdata(l, @sizeOf(sexpr.SxParser))));
    c.luaL_setmetatable(l, "class SxParser");

    parser.* = sexpr.SxParser.init(source, allocators.global_gpa.allocator()) catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    };

    return 1;
}

fn parser__gc(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    parser.deinit();
    return 0;
}

fn parser_open(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.open() catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    }) {
        c.lua_pushboolean(l, 1);
    } else {
        c.lua_pushboolean(l, 0);
    }
    return 1;
}

fn parser_close(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.close() catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    }) {
        c.lua_pushboolean(l, 1);
    } else {
        c.lua_pushboolean(l, 0);
    }
    return 1;
}

fn parser_done(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.done() catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    }) {
        c.lua_pushboolean(l, 1);
    } else {
        c.lua_pushboolean(l, 0);
    }
    return 1;
}

fn parser_expression(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        var expected: []const u8 = undefined;
        expected.ptr = c.luaL_checklstring(l, 2, &expected.len);

        if (parser.expression(expected) catch |e| {
            _ = c.luaL_error(l, @errorName(e));
            unreachable;
        }) {
            c.lua_pushboolean(l, 1);
        } else {
            c.lua_pushboolean(l, 0);
        }
        return 1;
    } else {
        if (parser.anyExpression() catch |e| {
            _ = c.luaL_error(l, @errorName(e));
            unreachable;
        }) |val| {
            _ = c.lua_pushlstring(l, val.ptr, val.len);
        } else {
            c.lua_pushnil(l);
        }
        return 1;
    }
}

fn parser_string(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
     if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        var expected: []const u8 = undefined;
        expected.ptr = c.luaL_checklstring(l, 2, &expected.len);

        if (parser.string(expected) catch |e| {
            _ = c.luaL_error(l, @errorName(e));
            unreachable;
        }) {
            c.lua_pushboolean(l, 1);
        } else {
            c.lua_pushboolean(l, 0);
        }
        return 1;
    } else {
        if (parser.anyString() catch |e| {
            _ = c.luaL_error(l, @errorName(e));
            unreachable;
        }) |val| {
            _ = c.lua_pushlstring(l, val.ptr, val.len);
        } else {
            c.lua_pushnil(l);
        }
        return 1;
    }
}

fn parser_float(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    if (parser.anyFloat(c.lua_Number) catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    }) |val| {
        _ = c.lua_pushnumber(l, val);
    } else {
        c.lua_pushnil(l);
    }
    return 1;
}

fn parser_int(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));

    var radix: u8 = 10;
    if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        radix = @intCast(u8, std.math.clamp(c.luaL_checkinteger(l, 2), 0, 36));
    }

    if (parser.anyInt(c.lua_Integer, radix) catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    }) |val| {
        _ = c.lua_pushinteger(l, val);
    } else {
        c.lua_pushnil(l);
    }
    return 1;
}

fn parser_unsigned(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));

    var radix: u8 = 10;
    if (c.lua_gettop(l) >= 2 and !c.lua_isnil(l, 2)) {
        radix = @intCast(u8, std.math.clamp(c.luaL_checkinteger(l, 2), 0, 36));
    }

    if (parser.anyUnsigned(u32, radix) catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    }) |val| {
        _ = c.lua_pushinteger(l, @intCast(c.lua_Integer, val));
    } else {
        c.lua_pushnil(l);
    }
    return 1;
}

fn parser_ignore_remaining_expression(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    parser.ignoreRemainingExpression() catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    };
    return 0;
}

fn parser_print_parse_error_context(l: L) callconv(.C) c_int {
    var parser = @ptrCast(*sexpr.SxParser, @alignCast(8, c.luaL_checkudata(l, 1, "class SxParser")));
    parser.printParseErrorContext() catch |e| {
        _ = c.luaL_error(l, @errorName(e));
        unreachable;
    };
    return 0;
}
