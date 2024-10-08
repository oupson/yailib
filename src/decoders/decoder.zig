const std = @import("std");
const Allocator = std.mem.Allocator;

const ppm = @import("ppm.zig");
const qoi = @import("qoi.zig");

const lib = @import("../root.zig");

const factories = [_]DecoderFactory{
    ppm.PPMDecoderFactory,
    qoi.DecoderFactory,
};

pub fn getDecoderFactory(buffer: []u8) DecoderError!DecoderFactory {
    for (factories) |factory| {
        if (factory.canHandle(buffer)) {
            return factory;
        }
    }
    return error.UnknownFormat;
}

pub const Event = enum {
    NeedMoreData,
    Ok,
    Finished,
};

pub const DecoderError = error{
    OutOfMemory,
    UnknownFormat,
    InvalidBufferSize,
    ParseIntError,
    Overflow,
    InvalidCharacter,
    Uninplemented,
};

pub const DecoderFactory = struct {
    canHandle: *const fn ([]const u8) bool,
    newInstance: *const fn (Allocator) DecoderError!Decoder,
};

pub const Decoder = struct {
    ptr: *anyopaque,
    vtable: struct {
        feed: *const fn (*anyopaque, buffer: []u8) void,
        step: *const fn (*anyopaque) DecoderError!Event,
        deinit: *const fn (*anyopaque) void,
        getResult: *const fn (*anyopaque) DecoderError!lib.Image,
    },

    pub fn feed(self: @This(), buffer: []u8) void {
        self.vtable.feed(self.ptr, buffer);
    }

    pub fn step(self: @This()) DecoderError!Event {
        return self.vtable.step(self.ptr);
    }

    pub fn deinit(self: @This()) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getResult(self: @This()) DecoderError!lib.Image {
        return self.vtable.getResult(self.ptr);
    }
};
