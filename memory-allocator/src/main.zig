const std = @import("std");
const memory_allocator = @import("allocator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var m = try memory_allocator.Mallocator.init(allocator, 100, 100, .best_fit, .address_sort, 0, true);
    defer m.deinit();

    const writer = std.io.getStdOut().writer();

    const ops_list = "+10,+20,-0,+30,-1";
    try m.run(writer, ops_list);
}
