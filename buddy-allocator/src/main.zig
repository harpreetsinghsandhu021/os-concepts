//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const alloc = @import("buddy-alloc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Create a 64-byte arena for our allocator to manage.
    var arena_memory: [64]u8 = undefined;
    const min_alloc = 8;

    var buddy = try alloc.BuddyAllocator.init(allocator, &arena_memory, min_alloc);
    defer buddy.deinit();

    const writer = std.io.getStdOut().writer();

    // try writer.print("Initial State:\n", .{});

    try writer.print("\nAllocating 10 bytes (round up to 16)...\n", .{});
    const ptr1 = try buddy.malloc(10);
    std.debug.assert(ptr1 != null);

    try writer.print("\nAllocating 10 bytes (round up to 16)...\n", .{});
    const ptr2 = try buddy.malloc(10);
    std.debug.assert(ptr2 != null);

    try writer.print("Freeeing first allocation...\n", .{});
    buddy.free(ptr1.?);

    try writer.print("Freeeing second allocation (should coalesce)...\n", .{});
    buddy.free(ptr2.?);

    // try writer.print("\nFinal State:\n", .{});
}
