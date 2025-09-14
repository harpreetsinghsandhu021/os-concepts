//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const Forker = @import("./forker.zig").Forker;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var forker = try Forker.init(allocator);
    defer forker.deinit();

    const action_list = "a+b,a+c,b+d,c-";
    // const action_list = "a+b,b+c,c-,a+d,-c";
    try forker.run(action_list);
}
