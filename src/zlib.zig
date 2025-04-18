const std = @import("std");
const allocators = @import("allocators.zig");

fn deflateBound(uncompressed_size: usize, encode_length: bool) usize {
    // TODO: is this still valid with the std.compress.flate implementation?  Probably not; let's use something more conservative...
    //var compressed_size = uncompressed_size + ((uncompressed_size + 7) >> 3) + ((uncompressed_size + 63) >> 6) + 11;
    var compressed_size = uncompressed_size + @divFloor(uncompressed_size, 4) + 256;
    if (encode_length) {
        compressed_size += @sizeOf(u64);
    }
    return compressed_size;
}

pub fn deflate(temp_alloc: *allocators.Temp_Allocator, uncompressed: []const u8, encode_length: bool, level: i8) ![]u8 {
    var allocator = temp_alloc.allocator();
    var result = try allocator.alloc(u8, deflateBound(uncompressed.len, encode_length));
    errdefer allocator.free(result);

    var out = result;
    if (encode_length) {
        out = out[@sizeOf(u64)..];
    }

    var uncompressed_stream = std.io.fixedBufferStream(uncompressed);
    var compressed_stream = std.io.fixedBufferStream(out);

    try std.compress.flate.compress(uncompressed_stream.reader(), compressed_stream.writer(), .{
        .level = @enumFromInt(level),
    });

    var compressed_size = compressed_stream.getWritten().len;

    if (encode_length) {
        compressed_size += @sizeOf(u64);
        var size = std.mem.nativeToLittle(u64, uncompressed.len);
        @memcpy(result.ptr, std.mem.asBytes(&size));
    }

    _ = allocator.resize(result, compressed_size);

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
    @memcpy(std.mem.asBytes(&uncompressed_size), compressed.ptr);
    return std.mem.littleToNative(u64, uncompressed_size);
}

pub fn stripUncompressedLength(compressed: []const u8) []const u8 {
    if (compressed.len < @sizeOf(u64)) {
        return compressed[compressed.len..];
    } else {
        return compressed[@sizeOf(u64)..];
    }
}

pub fn inflate(temp_alloc: *allocators.Temp_Allocator, compressed: []const u8, uncompressed_length: usize) ![]u8 {
    const uncompressed = try temp_alloc.allocator().alloc(u8, @max(1, uncompressed_length));
    errdefer temp_alloc.allocator().free(uncompressed);

    var compressed_stream = std.io.fixedBufferStream(compressed);
    var uncompressed_stream = std.io.fixedBufferStream(uncompressed);

    try std.compress.flate.decompress(compressed_stream.reader(), uncompressed_stream.writer());

    const result = uncompressed_stream.getWritten();
    _ = temp_alloc.allocator().resize(uncompressed, result.len);
    return result;
}
