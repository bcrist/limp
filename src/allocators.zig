const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const TempAllocator = @import("TempAllocator");

pub var global_gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }) {};

// Never freed until exit
pub var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// Reset before each matching input file is processed
pub var temp_arena: TempAllocator = undefined;
