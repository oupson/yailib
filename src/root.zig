const std = @import("std");

const decoder = @import("decoders/decoder.zig");
pub const Decoder = decoder;

pub const Image = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Self {
        const pixels = try allocator.alloc(u8, width * height * 3);
        return Self{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pixels);
    }
};
