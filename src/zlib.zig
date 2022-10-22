const std = @import("std");
const allocators = @import("allocators.zig");
pub const c = @cImport({
    @cDefine("Z_SOLO", {});
    @cDefine("ZLIB_CONST", {});
    @cInclude("zlib.h");
});

fn zlibAlloc(@"opaque": ?*anyopaque, items: c_uint, size: c_uint) callconv(.C) ?*anyopaque {
    var temp_alloc = @ptrCast(*allocators.TempAllocator, @alignCast(8, @"opaque"));
    var alloc = temp_alloc.allocator();
    var buf = alloc.rawAlloc(items * size, 16, 16, 0) catch {
        return null;
    };
    return buf.ptr;
}

fn zlibFree(_: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
    // all memory will be freed when the TempAllocator is reset at the end.
}

fn deflateBound(uncompressed_size: usize, encode_length: bool) usize {
    var compressed_size = uncompressed_size + ((uncompressed_size + 7) >> 3) + ((uncompressed_size + 63) >> 6) + 11;
    if (encode_length) {
        compressed_size += @sizeOf(u64);
    }
    return compressed_size;
}

pub fn deflate(temp_alloc: *allocators.TempAllocator, uncompressed: []const u8, encode_length: bool, level: i8) ![]u8 {
    var allocator = temp_alloc.allocator();
    var result = try allocator.alloc(u8, deflateBound(uncompressed.len, encode_length));
    errdefer allocator.free(result);

    var in = uncompressed;
    var out = result;

    if (encode_length) {
        out = out[@sizeOf(u64)..];
    }

    var stream: c.z_stream = undefined;
    stream.zalloc = zlibAlloc;
    stream.zfree = zlibFree;
    stream.@"opaque" = temp_alloc;

    switch (c.deflateInit(&stream, level)) {
        c.Z_MEM_ERROR => return error.OutOfMemory,
        c.Z_STREAM_ERROR => return error.InvalidLevel,
        c.Z_OK => {},
        else => return error.Unexpected,
    }

    stream.next_out = out.ptr;
    stream.avail_out = 0;
    stream.next_in = in.ptr;
    stream.avail_in = 0;

    const max_bytes: c_uint = std.math.maxInt(c_uint);
    var compressed_size: usize = 0;

    var status: c_int = c.Z_OK;
    while (status == c.Z_OK) {
        if (stream.avail_out == 0) {
            stream.avail_out = if (out.len > max_bytes) max_bytes else @intCast(c_uint, out.len);
            out = out[stream.avail_out..];
        }
        if (stream.avail_in == 0) {
            stream.avail_in = if (in.len > max_bytes) max_bytes else @intCast(c_uint, in.len);
            in = in[stream.avail_in..];
        }
        stream.total_out = 0;
        status = c.deflate(&stream, if (in.len > 0) c.Z_NO_FLUSH else c.Z_FINISH);
        compressed_size += stream.total_out;
    }

    if (status != c.Z_STREAM_END) {
        _ = c.deflateEnd(&stream);
        return error.Unexpected;
    }

    status = c.deflateEnd(&stream);
    if (status != c.Z_OK) {
        return error.Unexpected;
    }

    if (encode_length) {
        compressed_size += @sizeOf(u64);
        var size = std.mem.nativeToLittle(u64, uncompressed.len);

        // @Cleanup: is there a clearer/more idiomatic way to do this?
        @memcpy(result.ptr, @ptrCast([*]align(8) const u8, &size), @sizeOf(u64));
    }

    if (result.len != compressed_size) {
        result.len = compressed_size;
    }

    return result;
}

pub fn getUncompressedLength(compressed: []const u8) usize {
    if (compressed.len < @sizeOf(u64)) {
        return 0;
    }

    var uncompressed_size: u64 = undefined;
    @memcpy(@ptrCast([*]align(8) u8, &uncompressed_size), compressed.ptr, @sizeOf(u64));
    return std.mem.littleToNative(u64, uncompressed_size);
}

pub fn stripUncompressedLength(compressed: []const u8) []const u8 {
    if (compressed.len < @sizeOf(u64)) {
        return compressed[compressed.len..];
    } else {
        return compressed[@sizeOf(u64)..];
    }
}

pub fn inflate(temp_alloc: *allocators.TempAllocator, compressed: []const u8, uncompressed_length: usize) ![]u8 {
    var tmp = [1]u8{0}; // for detection of incomplete stream when uncompressed.len == 0

    var uncompressed: []u8 = undefined;

    if (uncompressed_length == 0) {
        uncompressed = &tmp;
    } else {
        uncompressed = try temp_alloc.allocator().alloc(u8, uncompressed_length);
    }

    var in = compressed;
    var out = uncompressed;

    var stream: c.z_stream = undefined;
    stream.zalloc = zlibAlloc;
    stream.zfree = zlibFree;
    stream.@"opaque" = temp_alloc;
    stream.next_in = in.ptr;
    stream.avail_in = 0;

    switch (c.inflateInit(&stream)) {
        c.Z_MEM_ERROR => return error.OutOfMemory,
        c.Z_OK => {},
        else => return error.Unexpected,
    }

    stream.next_out = out.ptr;
    stream.avail_out = 0;

    const max_bytes: c_uint = std.math.maxInt(c_uint);
    var actual_uncompressed_size: usize = 0;

    var status = c.Z_OK;
    while (status == c.Z_OK) {
        if (stream.avail_out == 0) {
            stream.avail_out = if (out.len > max_bytes) max_bytes else @intCast(c_uint, out.len);
            out = out[stream.avail_out..];
        }
        if (stream.avail_in == 0) {
            stream.avail_in = if (in.len > max_bytes) max_bytes else @intCast(c_uint, in.len);
            in = in[stream.avail_in..];
        }
        stream.total_out = 0;
        status = c.inflate(&stream, c.Z_NO_FLUSH);
        actual_uncompressed_size += stream.total_out;
    }

    if (uncompressed.len == 0) {
        if (actual_uncompressed_size > 0 and status == c.Z_BUF_ERROR) {
            _ = c.inflateEnd(&stream);
            return error.DataCorrupted;
        }
        actual_uncompressed_size = 0;
    }

    if (status == c.Z_NEED_DICT or status == c.Z_BUF_ERROR and (out.len + stream.avail_out > 0)) {
        _ = c.inflateEnd(&stream);
        return error.DataCorrupted;
    } else if (status == c.Z_MEM_ERROR) {
        _ = c.inflateEnd(&stream);
        return error.OutOfMemory;
    } else if (status != c.Z_STREAM_END) {
        _ = c.inflateEnd(&stream);
        return error.Unexpected;
    }

    status = c.inflateEnd(&stream);
    if (status != c.Z_OK) {
        return error.Unexpected;
    }

    return uncompressed[0..actual_uncompressed_size];
}
