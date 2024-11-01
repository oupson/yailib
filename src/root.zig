const std = @import("std");

const decoder = @import("decoders/decoder.zig");
pub const Decoder = decoder;

const Pixel = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

pub const PixelType = enum(u8) {
    Rgb = 3,
    Rgba = 4,
};

pub const Image = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixelType: PixelType,
    pixels_raw: []u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
        pixelType: PixelType,
    ) !Self {
        const pixels = try allocator.alloc(u8, width * height * @intFromEnum(pixelType));
        return Self{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels_raw = pixels,
            .pixelType = pixelType,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pixels_raw);
    }
};
