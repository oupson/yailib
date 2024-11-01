const std = @import("std");
const yaiv = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.skip();
    const name = args.next() orelse {
        return error.MissingInputFile;
    };

    const cwd = std.fs.cwd();

    const inputFile = try cwd.openFile(name, .{});
    const reader = inputFile.reader();
    var buffer: [1024]u8 = undefined;

    var size = try reader.read(&buffer);
    const factory = try yaiv.Decoder.getDecoderFactory(buffer[0..size]);
    const decoder = try factory.newInstance(allocator);

    decoder.feed(buffer[0..size]);
    while (true) {
        const event = try decoder.step();
        switch (event) {
            .NeedMoreData => {
                size = try reader.read(&buffer);
                if (size == 0) {
                    return error.UnexpectedEof;
                }

                decoder.feed(buffer[0..size]);
            },
            .Ok => {
                continue;
            },
            .Finished => {
                break;
            },
        }
    }

    const imgRes = try decoder.getResult();

    const out = std.io.getStdOut();
    try out.writeAll(imgRes.pixels_raw);
}
