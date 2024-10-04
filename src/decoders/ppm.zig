const std = @import("std");
const Allocator = std.mem.Allocator;

const lib = @import("../root.zig");
const decoder = @import("./decoder.zig");

pub const PPMDecoderFactory = decoder.DecoderFactory{
    .canHandle = canHandle,
    .newInstance = newInstance,
};

fn canHandle(buffer: []const u8) bool {
    return buffer.len > 2 and buffer[0] == 'P' and buffer[1] == '6';
}

fn newInstance(allocator: Allocator) decoder.DecoderError!decoder.Decoder {
    const d = try PPMDecoder.init(allocator);
    return decoder.Decoder{
        .ptr = d,
        .vtable = .{
            .feed = PPMDecoder.feed,
            .step = PPMDecoder.step,
            .deinit = PPMDecoder.deinit,
            .getResult = PPMDecoder.getResult,
        },
    };
}

const Decoder = struct {
    image: ?lib.Image,
    allocator: Allocator,
};

const State = enum {
    NotInit,
    Init,
};

const PPMDecoder = struct {
    image: ?lib.Image,
    allocator: Allocator,
    buffer: []const u8,
    index: usize,

    const Self = @This();

    fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.image = null;
        self.buffer = &[_]u8{};
        self.index = 0;
        return self;
    }

    fn feed(ptr: *anyopaque, buffer: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.buffer = buffer;
    }

    fn step(ptr: *anyopaque) decoder.DecoderError!decoder.Event {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.buffer.len == 0) {
            return decoder.Event.NeedMoreData;
        } else {
            if (self.image == null) {
                if (self.buffer[0] != 'P' or self.buffer[1] != '6' or self.buffer[2] != '\n') {
                    return error.UnknownFormat;
                } else {
                    self.buffer = self.buffer[3..];
                    const indexOfNext = std.mem.indexOfScalar(u8, self.buffer, '\n') orelse return error.InvalidBufferSize;
                    const size = self.buffer[0..indexOfNext];
                    var f = std.mem.splitScalar(u8, size, ' ');
                    const width = try std.fmt.parseInt(usize, f.next().?, 10);

                    const height = try std.fmt.parseInt(usize, f.next().?, 10);
                    self.image = try lib.Image.init(self.allocator, width, height);

                    self.buffer = self.buffer[indexOfNext + 1 ..];

                    const indexOfEndDepth = std.mem.indexOfScalar(u8, self.buffer, '\n') orelse return error.InvalidBufferSize;
                    const depthStr = self.buffer[0..indexOfEndDepth];

                    const depth = try std.fmt.parseInt(usize, depthStr, 10);
                    if (depth != 255) {
                        return error.UnknownFormat;
                    }
                    self.buffer = self.buffer[indexOfEndDepth + 1 ..];

                    return decoder.Event.Ok;
                }
            } else {
                for (self.buffer) |p| {
                    self.image.?.pixels[self.index] = p;
                    self.index += 1;
                }

                self.buffer = &.{};

                if (self.index == self.image.?.pixels.len) {
                    return decoder.Event.Finished;
                } else {
                    return decoder.Event.NeedMoreData;
                }
            }
        }
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.image.?.deinit();
        self.image = null;
    }

    fn getResult(ptr: *anyopaque) decoder.DecoderError!lib.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const img = self.image.?;
        self.image = null;
        return img;
    }
};
