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
    pixels: [64]Pixel = [_]Pixel{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 64,

    const Self = @This();

    fn put(self: *Self, pixel: Pixel) void {
        const hash = pixel.hash();
        self.pixels[hash] = pixel;
    }

    fn get(self: *Self, index: usize) Pixel {
        return self.pixels[index];
    }
};

const FILE_END: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1 };

const QoiDecoder = struct {
    allocator: Allocator,
    buffer: []const u8,
    impl: QoiReaderVtable = .{},

    const Self = @This();

    fn init(allocator: Allocator) DecoderError!Self {
        return Self{
            .allocator = allocator,
            .buffer = &.{},
        };
    }

    fn feed(ptr: *anyopaque, buffer: []u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.buffer = buffer;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.impl.deinit(@ptrCast(&self.impl.reader));
    }

    fn getResult(ptr: *anyopaque) DecoderError!lib.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const res = try self.impl.getResult(@ptrCast(&self.impl.reader));
        return res;
    }

    fn step(ptr: *anyopaque) DecoderError!Event {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.impl.isInit) {
            const res = try self.impl.step(@ptrCast(&self.impl.reader), self.buffer);
            self.buffer = &.{};
            return res;
        } else {
            const width = std.mem.readInt(u32, self.buffer[4..8], .big);
            const height = std.mem.readInt(u32, self.buffer[8..12], .big);
            const channels = self.buffer[12];
            const colorspace = self.buffer[13];
            self.buffer = self.buffer[14..];

            if (channels == 3) {
                const readerType = QoiReader(lib.PixelType.Rgb);
                @as(*readerType, @ptrCast(&self.impl.reader)).* = try readerType.init(self.allocator, width, height);
                self.impl.step = readerType.step;
                self.impl.getResult = readerType.getResult;
                self.impl.deinit = readerType.deinit;
            } else {
                const readerType = QoiReader(lib.PixelType.Rgba);
                @as(*readerType, @ptrCast(&self.impl.reader)).* = try readerType.init(self.allocator, width, height);
                self.impl.step = readerType.step;
                self.impl.getResult = readerType.getResult;
                self.impl.deinit = readerType.deinit;
            }
            self.impl.isInit = true;

            _ = colorspace;
            return Event.Ok;
        }
    }
};

const QoiReaderVtable = struct {
    reader: union {
        r1: QoiReader(lib.PixelType.Rgb),
        r2: QoiReader(lib.PixelType.Rgba),
    } = undefined,
    isInit: bool = false,
    step: *const fn (*anyopaque, buffer: []const u8) DecoderError!Event = undefined,
    deinit: *const fn (*anyopaque) void = undefined,
    getResult: *const fn (*anyopaque) DecoderError!lib.Image = undefined,
};

fn QoiReader(comptime pixelType: lib.PixelType) type {
    return struct {
        allocator: Allocator,
        image: ?lib.Image,
        runningArray: RunningArray,
        pixelIndex: usize = 0,
        cache: [8]u8 = [_]u8{0} ** 8,
        cacheBuffer: []u8 = &.{},
        latest: Pixel = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Self {
            const img = try lib.Image.init(allocator, width, height, pixelType);
            return .{
                .allocator = allocator,
                .image = img,
                .runningArray = .{},
            };
        }

        fn step(
            thiz: *anyopaque,
            buffer: []const u8,
        ) decoder.DecoderError!decoder.Event {
            const self: *Self = @ptrCast(@alignCast(thiz));

            if (self.pixelIndex == self.image.?.pixels_raw.len) {
                _ = self.fillCache(buffer) catch |err| {
                    if (err == DecoderError.InvalidBufferSize) {
                        return Event.NeedMoreData;
                    } else {
                        return err;
                    }
                };
                if (std.mem.eql(u8, self.cacheBuffer, &FILE_END)) {
                    return Event.Finished;
                } else {
                    return DecoderError.UnknownFormat;
                }
            }

            var index: usize = if (self.cacheBuffer.len > 0)
                self.readFromCache(buffer) catch |err| {
                    if (err == DecoderError.InvalidBufferSize) {
                        return Event.NeedMoreData;
                    } else {
                        return err;
                    }
                }
            else
                0;

            self.cacheBuffer = &.{};

            while (index < buffer.len) {
                if (self.pixelIndex == self.image.?.pixels_raw.len) {
                    if (buffer[index..].len < 8) {
                        self.cacheBuffer = self.cache[0..buffer.len];
                        std.mem.copyForwards(u8, self.cacheBuffer, buffer);
                        return Event.NeedMoreData;
                    } else {
                        if (std.mem.eql(u8, buffer[index..], &FILE_END)) {
                            return Event.Finished;
                        } else {
                            return Event.NeedMoreData;
                        }
                    }
                } else {
                    const buf = buffer[index..];

                    const read = try self.readImage(buf);
                    if (read == 0) {
                        return Event.NeedMoreData;
                    } else {
                        index += read;
                    }
                }
            }
            return Event.NeedMoreData;
        }

        fn getResult(
            thiz: *anyopaque,
        ) !lib.Image {
            const self: *Self = @ptrCast(@alignCast(thiz));
            const img = self.image;
            self.image = undefined;
            return img.?;
        }

        fn deinit(
            thiz: *anyopaque,
        ) void {
            const self: *Self = @ptrCast(@alignCast(thiz));
            _ = self;
        }

        fn readImage(self: *Self, buffer: []const u8) decoder.DecoderError!usize {
            if (buffer[0] == 0b11111110) {
                if (buffer.len < 4) {
                    self.cacheBuffer = self.cache[0..buffer.len];
                    std.mem.copyForwards(u8, self.cacheBuffer, buffer);
                    return 0;
                }
                self.readRgb(buffer);
                return 4;
            } else if (buffer[0] == 0b11111111) {
                if (buffer.len < 5) {
                    self.cacheBuffer = self.cache[0..buffer.len];
                    std.mem.copyForwards(u8, self.cacheBuffer, buffer);
                    return 0;
                }
                self.readRgba(buffer);
                return 5;
            } else if (buffer[0] & 0b11000000 == 0) {
                // HASH
                const p = self.runningArray.get(@as(usize, buffer[0] & 0b00111111));

                self.latest = p;
                self.runningArray.put(p);

                self.image.?.pixels_raw[self.pixelIndex] = p.r;
                self.image.?.pixels_raw[self.pixelIndex + 1] = p.g;
                self.image.?.pixels_raw[self.pixelIndex + 2] = p.b;
                if (pixelType == lib.PixelType.Rgba) {
                    self.image.?.pixels_raw[self.pixelIndex + 3] = p.a;
                }
                self.pixelIndex += @intFromEnum(pixelType);
                return 1;
            } else if (@shrExact(buffer[0] & 0b11000000, 6) == 0b01) {
                var latest = self.latest;
                // QOI_OP_DIFF

                const diffR = @shrExact(buffer[0] & 0b00110000, 4) -% 2;
                const diffG = @shrExact(buffer[0] & 0b00001100, 2) -% 2;
                const diffB = @shrExact(buffer[0] & 0b00000011, 0) -% 2;

                latest.r = latest.r +% diffR;
                latest.g = latest.g +% diffG;
                latest.b = latest.b +% diffB;

                self.runningArray.put(latest);
                self.latest = latest;

                self.image.?.pixels_raw[self.pixelIndex] = latest.r;
                self.image.?.pixels_raw[self.pixelIndex + 1] = latest.g;
                self.image.?.pixels_raw[self.pixelIndex + 2] = latest.b;
                if (pixelType == lib.PixelType.Rgba) {
                    self.image.?.pixels_raw[self.pixelIndex + 3] = latest.a;
                }

                self.pixelIndex += @intFromEnum(pixelType);
                return 1;
            } else if (@shrExact(buffer[0] & 0b11000000, 6) == 0b10) {
                if (buffer.len < 3) {
                    self.cacheBuffer = self.cache[0..buffer.len];
                    std.mem.copyForwards(u8, self.cacheBuffer, buffer);
                    return 0;
                }
                self.readLuma(buffer);
                return 2;
            } else if (@shrExact(buffer[0] & 0b11000000, 6) == 0b11) {
                const run = (buffer[0] & 0b00111111) + 1;

                const latest = self.latest;
                for (0..run) |_| {
                    self.image.?.pixels_raw[self.pixelIndex] = latest.r;
                    self.image.?.pixels_raw[self.pixelIndex + 1] = latest.g;
                    self.image.?.pixels_raw[self.pixelIndex + 2] = latest.b;
                    if (pixelType == lib.PixelType.Rgba) {
                        self.image.?.pixels_raw[self.pixelIndex + 3] = latest.a;
                    }
                    self.pixelIndex += @intFromEnum(pixelType);
                }

                return 1;
            } else {
                return DecoderError.UnknownFormat;
            }
        }

        inline fn fillCache(self: *Self, buffer: []const u8) DecoderError!usize {
            const cacheLen = self.cacheBuffer.len;
            {
                const missingLen = self.cache.len - cacheLen;
                if (missingLen > buffer.len) {
                    std.mem.copyForwards(u8, self.cache[cacheLen..][0..buffer.len], buffer);
                    self.cacheBuffer = self.cache[0 .. cacheLen + buffer.len];
                    return DecoderError.InvalidBufferSize;
                } else {
                    std.mem.copyForwards(u8, self.cache[cacheLen..], buffer[0..missingLen]);
                    self.cacheBuffer = &self.cache;
                }
            }
            return cacheLen;
        }

        inline fn readFromCache(self: *Self, buffer: []const u8) DecoderError!usize {
            const cacheLen = try self.fillCache(buffer);
            if (self.cacheBuffer[0] == 0b11111110) {
                self.readRgb(self.cacheBuffer);
                return 4 - cacheLen;
            } else if (self.cacheBuffer[0] == 0b11111111) {
                self.readRgba(self.cacheBuffer);
                return 5 - cacheLen;
            } else if (@shrExact(self.cacheBuffer[0] & 0b11000000, 6) == 0b10) {
                self.readLuma(self.cacheBuffer);
                return 2 - cacheLen;
            }
            return DecoderError.UnknownFormat;
        }

        inline fn readRgb(self: *Self, buffer: []const u8) void {
            const p = Pixel{
                .r = buffer[1],
                .g = buffer[2],
                .b = buffer[3],
                .a = self.latest.a,
            };

            self.runningArray.put(p);
            self.latest = p;
            self.image.?.pixels_raw[self.pixelIndex] = p.r;
            self.image.?.pixels_raw[self.pixelIndex + 1] = p.g;
            self.image.?.pixels_raw[self.pixelIndex + 2] = p.b;
            if (pixelType == lib.PixelType.Rgba) {
                self.image.?.pixels_raw[self.pixelIndex + 3] = p.a;
            }

            self.pixelIndex += @intFromEnum(pixelType);
        }

        inline fn readRgba(self: *Self, buffer: []const u8) void {
            const p = Pixel{
                .r = buffer[1],
                .g = buffer[2],
                .b = buffer[3],
                .a = buffer[4],
            };

            self.runningArray.put(p);
            self.latest = p;
            self.image.?.pixels_raw[self.pixelIndex] = p.r;
            self.image.?.pixels_raw[self.pixelIndex + 1] = p.g;
            self.image.?.pixels_raw[self.pixelIndex + 2] = p.b;
            if (pixelType == lib.PixelType.Rgba) {
                self.image.?.pixels_raw[self.pixelIndex + 3] = p.a;
            }

            self.pixelIndex += @intFromEnum(pixelType);
        }

        inline fn readLuma(self: *Self, buffer: []const u8) void {
            var latest = self.latest;

            const dg = (buffer[0] & 0b00111111) -% 32;

            const dr = (@shrExact(buffer[1] & 0b11110000, 4) -% 8) +% dg;
            const db = (@shrExact(buffer[1] & 0b00001111, 0) -% 8) +% dg;

            latest.r = latest.r +% dr;
            latest.g = latest.g +% dg;
            latest.b = latest.b +% db;

            self.runningArray.put(latest);
            self.latest = latest;

            self.image.?.pixels_raw[self.pixelIndex] = latest.r;
            self.image.?.pixels_raw[self.pixelIndex + 1] = latest.g;
            self.image.?.pixels_raw[self.pixelIndex + 2] = latest.b;
            if (pixelType == lib.PixelType.Rgba) {
                self.image.?.pixels_raw[self.pixelIndex + 3] = latest.a;
            }

            self.pixelIndex += @intFromEnum(pixelType);
        }
    };
}
