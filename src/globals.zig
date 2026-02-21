const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const Temp_Allocator = @import("Temp_Allocator");

var debug_alloc = std.heap.DebugAllocator(.{}) {};

pub const gpa: std.mem.Allocator = if (@import("builtin").mode == .Debug) debug_alloc.allocator() else std.heap.smp_allocator;

// Never freed until exit
pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// Reset before each matching input file is processed
pub var temp_arena: Temp_Allocator = undefined;

pub var io: std.Io = undefined;
