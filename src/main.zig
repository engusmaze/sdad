const std = @import("std");
const sdad = @import("sdad");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    const start = try std.time.Instant.now();
    const cock = try sdad.parse(@embedFile("test.sdad"), allocator);
    const end = try std.time.Instant.now();
    defer cock.deinit(allocator);
    std.debug.print("{d}\n", .{@as(f64, @floatFromInt(end.since(start))) / 1000000.0});

    std.debug.print("{s}\n", .{try cock.to_string(allocator, false)});

    try std.fs.cwd().writeFile2(.{
        .sub_path = "output.sdad",
        .data = try cock.to_string_pretty(allocator),
    });
}
