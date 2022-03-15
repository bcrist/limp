const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

// Never freed until exit
pub var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// Reset before each matching input file is processed
pub var temp_arena = TempAllocator.init(std.heap.page_allocator);

/// A version of std.heap.ArenaAllocator that can be reset without freeing (all of) the underlying memory, allowing it to
/// be reused again. This is useful when a program has a "top level" loop where the allocator can be reset, such as the
/// main loop of a game.
///
/// Each time the allocator is reset, it may choose to allocate a single contiguous block that it expects should be large
/// enough to cover all usage until the next reset, based on usage during previous iterations (low-pass filtered to avoid
/// thrashing).  
pub const TempAllocator = struct {
    child_allocator: Allocator,
    state: State,

    /// Inner state of TempAllocator. Can be stored rather than the entire TempAllocator
    /// as a memory-saving optimization.
    pub const State = struct {
        buffer_list: std.SinglyLinkedList([]u8) = @as(std.SinglyLinkedList([]u8), .{}),
        end_index: usize = 0,
        usage_estimate: usize = 0,
        prev_usage: usize = 0,

        pub fn promote(self: State, child_allocator: Allocator) TempAllocator {
            return .{
                .child_allocator = child_allocator,
                .state = self,
            };
        }
    };

    pub fn allocator(self: *TempAllocator) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    const BufNode = std.SinglyLinkedList([]u8).Node;

    pub fn init(child_allocator: Allocator) TempAllocator {
        return (State{}).promote(child_allocator);
    }

    pub fn deinit(self: TempAllocator) void {
        var it = self.state.buffer_list.first;
        while (it) |node| {
            // this has to occur before the free because the free frees node
            const next_it = node.next;
            self.child_allocator.free(node.data);
            it = next_it;
        }
    }

    pub fn reset(self: *TempAllocator, min_capacity: usize) !void {
        // The "half-life" for usage_estimate reacting to changes in usage is:
        //     ~11 cycles after an increase
        //     ~710 cycles after a decrease
        // If the initial capacity node overflows two cycles in a row, it will be expanded on the second reset.
        try self.resetAdvanced(min_capacity, 1, 64, 1024);
    }

    pub fn resetAdvanced(self: *TempAllocator, min_capacity: usize, comptime usage_contraction_rate: u16, comptime usage_expansion_rate: u16, comptime fast_usage_expansion_rate: u16) !void {
        if (self.state.buffer_list.first) |first_node| {
            var usage = self.state.end_index;

            var it = first_node.next;
            while (it) |node| {
                usage += node.data.len - @sizeOf(BufNode);
                const next_it = node.next;
                self.child_allocator.free(node.data);
                it = next_it;
            }
            first_node.next = null;
            self.state.end_index = 0;

            const capacity = first_node.data.len - @sizeOf(BufNode);

            const new_usage_estimate = self.computeUsageEstimate(usage, capacity, usage_contraction_rate, usage_expansion_rate, fast_usage_expansion_rate);
            self.state.usage_estimate = new_usage_estimate;
            self.state.prev_usage = usage;

            if (new_usage_estimate > capacity or (new_usage_estimate * 3 < capacity and capacity > padAndExpandSize(min_capacity))) {
                const target_capacity = @maximum(min_capacity, new_usage_estimate);
                const bigger_buf_size = padAndExpandSize(target_capacity);
                if (self.child_allocator.resize(first_node.data, bigger_buf_size)) |buf| {
                    first_node.data = buf;
                } else {
                    self.child_allocator.free(first_node.data);
                    self.state.buffer_list.first = null;
                    _ = try self.createNode(0, target_capacity);
                }
            }
        } else {
            _ = try self.createNode(0, @maximum(min_capacity, self.state.usage_estimate));
        }
    }

    fn computeUsageEstimate(self: *TempAllocator, usage: usize, capacity: usize, comptime usage_contraction_rate: u16, comptime usage_expansion_rate: u16, comptime fast_usage_expansion_rate: u16) usize {
        const last_usage_estimate = self.state.usage_estimate;
        if (last_usage_estimate == 0) {
            return usage;
        } else if (usage > last_usage_estimate) {
            if (usage > capacity and self.state.prev_usage > capacity) {
                const delta = @maximum(usage, self.state.prev_usage) - last_usage_estimate;
                return last_usage_estimate + scaleUsageDelta(delta, fast_usage_expansion_rate);
            } else {
                const avg_usage = usage / 2 + self.state.prev_usage / 2;
                if (avg_usage > last_usage_estimate) {
                    return last_usage_estimate + scaleUsageDelta(avg_usage - last_usage_estimate, usage_expansion_rate);
                } else {
                    return last_usage_estimate;
                }
            }
        } else if (usage < last_usage_estimate) {
            return last_usage_estimate - scaleUsageDelta(last_usage_estimate - usage, usage_contraction_rate);
        } else {
            return last_usage_estimate;
        }
    }

    fn scaleUsageDelta(delta: usize, comptime scale: usize) usize {
        return @maximum(1, if (delta >= (1 << 20)) delta / 1024 * scale else delta * scale / 1024);
    }

    fn padAndExpandSize(size: usize) usize {
        const padded_size = size + @sizeOf(BufNode) + 16;
        return padded_size + padded_size / 2;
    }

    fn createNode(self: *TempAllocator, prev_len: usize, minimum_size: usize) !*BufNode {
        const len = padAndExpandSize(prev_len + minimum_size);
        const buf = try self.child_allocator.rawAlloc(len, @alignOf(BufNode), 1, @returnAddress());
        const buf_node = @ptrCast(*BufNode, @alignCast(@alignOf(BufNode), buf.ptr));
        buf_node.* = BufNode{
            .data = buf,
            .next = null,
        };
        self.state.buffer_list.prepend(buf_node);
        self.state.end_index = 0;
        return buf_node;
    }

    fn alloc(self: *TempAllocator, n: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
        _ = len_align;
        _ = ra;

        var cur_node = if (self.state.buffer_list.first) |first_node| first_node else try self.createNode(0, n + ptr_align);
        while (true) {
            const cur_buf = cur_node.data[@sizeOf(BufNode)..];
            const addr = @ptrToInt(cur_buf.ptr) + self.state.end_index;
            const adjusted_addr = mem.alignForward(addr, ptr_align);
            const adjusted_index = self.state.end_index + (adjusted_addr - addr);
            const new_end_index = adjusted_index + n;

            if (new_end_index <= cur_buf.len) {
                const result = cur_buf[adjusted_index..new_end_index];
                self.state.end_index = new_end_index;
                return result;
            }

            const bigger_buf_size = @sizeOf(BufNode) + new_end_index;
            // Try to grow the buffer in-place
            cur_node.data = self.child_allocator.resize(cur_node.data, bigger_buf_size) orelse {
                // Allocate a new node if that's not possible
                cur_node = try self.createNode(cur_buf.len, n + ptr_align);
                continue;
            };
        }
    }

    fn resize(self: *TempAllocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) ?usize {
        _ = buf_align;
        _ = len_align;
        _ = ret_addr;

        const cur_node = self.state.buffer_list.first orelse return null;
        const cur_buf = cur_node.data[@sizeOf(BufNode)..];
        if (@ptrToInt(cur_buf.ptr) + self.state.end_index != @ptrToInt(buf.ptr) + buf.len) {
            if (new_len > buf.len) return null;
            return new_len;
        }

        if (buf.len >= new_len) {
            self.state.end_index -= buf.len - new_len;
            return new_len;
        } else if (cur_buf.len - self.state.end_index >= new_len - buf.len) {
            self.state.end_index += new_len - buf.len;
            return new_len;
        } else {
            return null;
        }
    }

    fn free(self: *TempAllocator, buf: []u8, buf_align: u29, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;

        const cur_node = self.state.buffer_list.first orelse return;
        const cur_buf = cur_node.data[@sizeOf(BufNode)..];

        if (@ptrToInt(cur_buf.ptr) + self.state.end_index == @ptrToInt(buf.ptr) + buf.len) {
            self.state.end_index -= buf.len;
        }
    }
};
