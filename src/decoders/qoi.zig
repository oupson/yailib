const std = @import("std");
const Allocator = std.mem.Allocator;

const lib = @import("../root.zig");
const decoder = @import("./decoder.zig");

const DecoderError = decoder.DecoderError;
const Event = decoder.Event;

pub const DecoderFactory = decoder.DecoderFactory{
    .canHandle = canHandle,
    .newInstance = newInstance,
};

fn canHandle(buffer: []const u8) bool {
    return buffer.len > 4 and std.mem.eql(u8, buffer[0..4], "qoif");
}

fn newInstance(allocator: Allocator) DecoderError!decoder.Decoder {
    const d = try allocator.create(QoiDecoder);
    d.* = try QoiDecoder.init(allocator);
    return decoder.Decoder{
        .ptr = d,
        .vtable = .{
            .feed = QoiDecoder.feed,
            .step = QoiDecoder.step,
            .deinit = QoiDecoder.deinit,
            .getResult = QoiDecoder.getResult,
        },
    };
}

const Pixel = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    fn hash(self: @This()) usize {
        return (@as(
            usize,
            self.r,
        ) * 3 + @as(
            usize,
            self.g,
        ) * 5 + @as(usize, self.b) * 7 + @as(
            usize,
            self.a,
        ) * 11) % 64;
    }
};

const RunningArray = struct {
    pixels: [64]Pixel = [_]Pixel{.{ .r = 0, .g = 0, .b = 0, .a = 255 }} ** 64,

    const Self = @This();

    fn put(self: *Self, pixel: Pixel) void {
        const hash = pixel.hash();
        self.pixels[hash] = pixel;
    }

    fn get(self: *Self, index: usize) Pixel {
        return self.pixels[index];
    }
};

const QoiDecoder = struct {
    allocator: Allocator,
    buffer: []const u8,
    image: ?lib.Image,
    runningArray: RunningArray,
    pixelIndex: usize = 0,
    cache: [4]u8 = [_]u8{0} ** 4,
    cache_buffer: []u8 = &.{},
    latest: Pixel = .{},

    const Self = @This();

    fn init(allocator: Allocator) DecoderError!Self {
        return Self{
            .allocator = allocator,
            .buffer = &.{},
            .image = null,
            .runningArray = .{},
        };
    }

    fn feed(ptr: *anyopaque, buffer: []u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.buffer = buffer;
    }

    fn step(ptr: *anyopaque) DecoderError!Event {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.image) |img| {
            var index: usize = 0;

            while (index < self.buffer.len) {
                if (self.pixelIndex == img.pixels.len) {
                    // TODO: check end
                    return Event.Finished;
                } else if (self.buffer[index] == 0b11111110) {
                    const p = Pixel{
                        .r = self.buffer[index + 1],
                        .g = self.buffer[index + 2],
                        .b = self.buffer[index + 3],
                    };

                    self.runningArray.put(p);
                    self.latest = p;
                    self.image.?.pixels[self.pixelIndex] = p.r;
                    self.image.?.pixels[self.pixelIndex + 1] = p.g;
                    self.image.?.pixels[self.pixelIndex + 2] = p.b;

                    self.pixelIndex += 3;

                    index += 4;
                } else if (self.buffer[index] == 0x11111111) {
                    const p = Pixel{
                        .r = self.buffer[index + 1],
                        .g = self.buffer[index + 2],
                        .b = self.buffer[index + 3],
                        .a = self.buffer[index + 4],
                    };

                    self.runningArray.put(p);
                    self.latest = p;
                    self.image.?.pixels[self.pixelIndex] = p.r;
                    self.image.?.pixels[self.pixelIndex + 1] = p.g;
                    self.image.?.pixels[self.pixelIndex + 2] = p.b;
                    // TODO: alpha

                    self.pixelIndex += 3;

                    index += 5;
                } else if (self.buffer[index] & 0b11000000 == 0) {
                    // HASH
                    const p = self.runningArray.get(@as(usize, self.buffer[index] & 0b00111111));

                    self.latest = p;
                    self.runningArray.put(p);

                    self.image.?.pixels[self.pixelIndex] = p.r;
                    self.image.?.pixels[self.pixelIndex + 1] = p.g;
                    self.image.?.pixels[self.pixelIndex + 2] = p.b;
                    self.pixelIndex += 3;
                    index += 1;
                } else if (@shrExact(self.buffer[index] & 0b11000000, 6) == 0b01) {
                    var latest = self.latest;
                    // QOI_OP_DIFF

                    const diffR = @subWithOverflow(@shrExact(
                        self.buffer[index] & 0b00110000,
                        4,
                    ), 2)[0];
                    const diffG = @subWithOverflow(@shrExact(
                        self.buffer[index] & 0b00001100,
                        2,
                    ), 2)[0];
                    const diffB = @subWithOverflow(@shrExact(
                        self.buffer[index] & 0b00000011,
                        0,
                    ), 2)[0];

                    latest.r = @addWithOverflow(latest.r, diffR)[0];
                    latest.g = @addWithOverflow(latest.g, diffG)[0];
                    latest.b = @addWithOverflow(latest.b, diffB)[0];

                    self.runningArray.put(latest);
                    self.latest = latest;

                    self.image.?.pixels[self.pixelIndex] = latest.r;
                    self.image.?.pixels[self.pixelIndex + 1] = latest.g;
                    self.image.?.pixels[self.pixelIndex + 2] = latest.b;
                    // TODO: alpha

                    self.pixelIndex += 3;
                    index += 1;
                } else if (@shrExact(self.buffer[index] & 0b11000000, 6) == 0b10) {
                    var latest = self.latest;

                    const dg = @subWithOverflow(
                        self.buffer[index] & 0b00111111,
                        32,
                    )[0];

                    const dr = @addWithOverflow(
                        @subWithOverflow(
                            @shrExact(self.buffer[index + 1] & 0b11110000, 4),
                            8,
                        )[0],
                        dg,
                    )[0];

                    const db = @addWithOverflow(
                        @subWithOverflow(
                            @shrExact(self.buffer[index + 1] & 0b00001111, 0),
                            8,
                        )[0],
                        dg,
                    )[0];

                    latest.r = @addWithOverflow(latest.r, dr)[0];
                    latest.g = @addWithOverflow(latest.g, dg)[0];
                    latest.b = @addWithOverflow(latest.b, db)[0];

                    self.runningArray.put(latest);
                    self.latest = latest;

                    self.image.?.pixels[self.pixelIndex] = latest.r;
                    self.image.?.pixels[self.pixelIndex + 1] = latest.g;
                    self.image.?.pixels[self.pixelIndex + 2] = latest.b; // TODO: alpha

                    self.pixelIndex += 3;
                    index += 2;
                } else if (@shrExact(self.buffer[index] & 0b11000000, 6) == 0b11) {
                    const run = (self.buffer[index] & 0b00111111) + 1;

                    const latest = self.latest;
                    for (0..run) |_| {
                        self.image.?.pixels[self.pixelIndex] = latest.r;
                        self.image.?.pixels[self.pixelIndex + 1] = latest.g;
                        self.image.?.pixels[self.pixelIndex + 2] = latest.b;
                        // TODO: alpha
                        self.pixelIndex += 3;
                    }

                    index += 1;
                } else {
                    return DecoderError.UnknownFormat;
                }
            }
            self.buffer = &.{};
            return Event.NeedMoreData;
        } else {
            const width = std.mem.readInt(u32, self.buffer[4..8], .big);
            const height = std.mem.readInt(u32, self.buffer[8..12], .big);
            const channels = self.buffer[12];
            const colorspace = self.buffer[13];
            self.buffer = self.buffer[14..];

            // TODO
            if (channels != 3) {
                return DecoderError.Uninplemented;
            }
            self.image = try lib.Image.init(self.allocator, @intCast(width), @intCast(height));
            _ = colorspace;
            return Event.Ok;
        }
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
    }

    fn getResult(ptr: *anyopaque) DecoderError!lib.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const res = self.image;
        self.image = null;
        return res.?;
    }
};
