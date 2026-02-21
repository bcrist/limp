const std = @import("std");
const globals = @import("globals.zig");
pub const fs = @import("lua-fs.zig");
pub const sexpr = @import("lua-sexpr.zig");
pub const util = @import("lua-util.zig");
pub const c = @cImport({
    @cDefine("LUA_EXTRASPACE", std.fmt.comptimePrint("{}", .{@sizeOf(globals.Temp_Allocator)}));
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});
const L = ?*c.lua_State;

/// Use State.call(0, 0) or State.callAll to invoke this
pub fn registerStdLib(l: L) callconv(.c) c_int {
    c.luaL_openlibs(l);
    return 0;
}

pub fn getTempAlloc(l: L) *globals.Temp_Allocator {
    // Note: this relies on LUA_EXTRASPACE being defined correctly, both in the @cImport and when the lua source files are compiled
    return @ptrCast(@alignCast(c.lua_getextraspace(l)));
}

pub const State = struct {
    l: L,

    pub fn init() !State {
        const l = c.luaL_newstate();
        errdefer c.lua_close(l);
        getTempAlloc(l).* = try globals.Temp_Allocator.init(100 * 1024 * 1024);
        return State {
            .l = l,
        };
    }

    pub fn deinit(self: State) void {
        getTempAlloc(self.l).deinit();
        c.lua_close(self.l);
    }

    pub fn execute(self: State, chunk: []const u8, chunk_name: [:0]const u8) !void {
        switch (c.luaL_loadbufferx(self.l, chunk.ptr, chunk.len, chunk_name.ptr, null)) {
            c.LUA_OK => {},
            c.LUA_ERRMEM => return error.OutOfMemory,
            else => return error.LuaSyntaxError,
        }
        try self.call(0, 0);
    }

    pub fn callAll(self: State, funcs: []const c.lua_CFunction) !void {
        if (funcs.len > std.math.maxInt(c_int) or 0 == c.lua_checkstack(self.l, @intCast(funcs.len))) {
            return error.TooManyFunctions;
        }
        self.pushCFunction(traceUnsafe);
        const trace_index = self.getTop();
        self.pushCFunction(callAllUnsafe);
        for (funcs) |func| {
            self.pushCFunction(func);
        }

        defer self.removeIndex(trace_index);
        switch (c.lua_pcallk(self.l, @intCast(funcs.len), 0, trace_index, 0, null)) {
            c.LUA_OK => {},
            c.LUA_ERRMEM => return error.OutOfMemory,
            else => return error.LuaRuntimeError,
        }
    }
    fn callAllUnsafe(l: L) callconv(.c) c_int {
        const top = c.lua_gettop(l);
        var i: c_int = 1;
        while (i <= top) : (i += 1) {
            c.lua_pushvalue(l, i);
            c.lua_callk(l, 0, 0, 0, null);
        }
        return 0;
    }

    pub fn call(self: State, num_args: c_int, num_results: c_int) !void {
        const func_index = self.getTop() - num_args;
        self.pushCFunction(traceUnsafe);
        self.moveToIndex(func_index); // put it under function and args
        defer self.removeIndex(func_index);
        switch (c.lua_pcallk(self.l, num_args, num_results, func_index, 0, null)) {
            c.LUA_OK => {},
            c.LUA_ERRMEM => return error.OutOfMemory,
            else => return error.LuaRuntimeError,
        }
    }
    fn traceUnsafe(l: L) callconv(.c) c_int {
        if (c.lua_isstring(l, 1) != 0) {
            const ptr = c.lua_tolstring(l, 1, null);
            c.luaL_traceback(l, l, ptr, 1);
        } else if (!c.lua_isnoneornil(l, 1)) {
            const ptr = c.luaL_tolstring(l, 1, null);
            c.luaL_traceback(l, l, ptr, 1);
            removeIndex(.{ .l = l }, 2);
        }
        return 1;
    }

    pub fn callNoTrace(self: State, num_args: c_int, num_results: c_int) !void {
        switch (c.lua_pcallk(self.l, num_args, num_results, 0, 0, null)) {
            c.LUA_OK => {},
            c.LUA_ERRMEM => return error.OutOfMemory,
            else => return error.LuaRuntimeError,
        }
    }

    pub fn pushGlobal(self: State, slot: []const u8) !void {
        _ = c.lua_rawgeti(self.l, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);
        try self.pushTableString(-1, slot);
        self.removeIndex(-2);
    }

    const TableStringParams = struct {
        slot: []const u8,
        value: []const u8,
    };

    pub fn pushTableString(self: State, table_index: c_int, slot: []const u8) !void {
        var params = TableStringParams {
            .slot = slot,
            .value = "",
        };

        c.lua_pushvalue(self.l, table_index);
        self.pushCFunction(pushTableStringUnsafe);
        self.moveToIndex(-2);
        self.pushPointer(&params);
        try self.call(2, 1);
    }
    fn pushTableStringUnsafe(l: L) callconv(.c) c_int {
        const params_ptr: *const TableStringParams = @ptrCast(@alignCast(c.lua_topointer(l, 2)));
        const params = params_ptr.*;
        _ = c.lua_pushlstring(l, params.slot.ptr, params.slot.len);
        _ = c.lua_gettable(l, 1);
        return 1;
    }

    pub fn setGlobalString(self: State, slot: []const u8, value: []const u8) !void {
        _ = c.lua_rawgeti(self.l, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);
        try self.setTableStringString(-1, slot, value);
        c.lua_settop(self.l, -2);
    }

    pub fn setTableStringString(self: State, table_index: c_int, slot: []const u8, value: []const u8) !void {
        var params = TableStringParams {
            .slot = slot,
            .value = value,
        };

        c.lua_pushvalue(self.l, table_index);
        self.pushCFunction(setTableStringStringUnsafe);
        self.moveToIndex(-2);
        self.pushPointer(&params);
        try self.call(2, 0);
    }
    fn setTableStringStringUnsafe(l: L) callconv(.c) c_int {
        const params_ptr: *const TableStringParams = @ptrCast(@alignCast(c.lua_topointer(l, 2)));
        const params = params_ptr.*;
        _ = c.lua_pushlstring(l, params.slot.ptr, params.slot.len);
        _ = c.lua_pushlstring(l, params.value.ptr, params.value.len);
        c.lua_settable(l, 1);
        return 0;
    }

    pub fn pushString(self: State, str: []const u8) !void {
        self.pushCFunction(pushStringUnsafe);
        self.pushPointer(&str);
        self.callNoTrace(1, 1);
    }
    fn pushStringUnsafe(l: L) callconv(.c) c_int {
        const str_ptr = @as(*[]const u8, c.lua_topointer(l, 1));
        c.lua_settop(l, 0);
        _ = c.lua_pushlstring(l, str_ptr.*.ptr, str_ptr.*.len);
        return 1;
    }

    pub inline fn pushInteger(self: State, value: c.lua_Integer) void {
        c.lua_pushinteger(self.l, value);
    }

    pub inline fn pushPointer(self: State, value: *anyopaque) void {
        c.lua_pushlightuserdata(self.l, value);
    }

    pub inline fn pushCFunction(self: State, func: c.lua_CFunction) void {
        c.lua_pushcclosure(self.l, func, 0);
    }

    pub inline fn moveToIndex(self: State, index: c_int) void {
        c.lua_rotate(self.l, index, 1);
    }

    // This is only safe when removing an index that isn't to-be-closed
    inline fn removeIndex(self: State, index: c_int) void {
        c.lua_rotate(self.l, index, -1);
        c.lua_settop(self.l, -2);
    }

    pub inline fn getTop(self: State) c_int {
        return c.lua_gettop(self.l);
    }

    pub inline fn setTop(self: State, index: c_int) void {
        c.lua_settop(self.l, index);
    }

    pub fn getString(self: State, index: i8, default: []const u8) []const u8 {
        if (c.lua_type(self.l, index) == c.LUA_TSTRING) {
            var slice: []const u8 = undefined;
            slice.ptr = c.lua_tolstring(self.l, index, &slice.len);
            return slice;
        } else {
            return default;
        }
    }

    pub fn debugStack(self: State, msg: []const u8) !void {
        var stdout = std.Io.getStdOut().writer();

        const top = self.getTop();
        try stdout.print("{s} ({}): ", .{ msg, top });

        var i: c_int = 1;
        while (i <= top) : (i += 1) {
            switch (c.lua_type(self.l, i)) {
                c.LUA_TNIL => {
                    try stdout.print("nil, ", .{});
                },
                c.LUA_TNUMBER => {
                    try stdout.print("number, ", .{});
                },
                c.LUA_TBOOLEAN => {
                    try stdout.print("boolean, ", .{});
                },
                c.LUA_TSTRING => {
                    try stdout.print("string, ", .{});
                },
                c.LUA_TTABLE => {
                    try stdout.print("table, ", .{});
                },
                c.LUA_TFUNCTION => {
                    try stdout.print("function, ", .{});
                },
                c.LUA_TUSERDATA => {
                    try stdout.print("ud, ", .{});
                },
                c.LUA_TTHREAD => {
                    try stdout.print("thread, ", .{});
                },
                c.LUA_TLIGHTUSERDATA => {
                    try stdout.print("lightud, ", .{});
                },
                else => {
                    try stdout.print("unknown, ", .{});
                },
            }
        }
        try stdout.print("\n", .{});
    }
};
