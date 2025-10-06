//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const alloc = @import("buddy-alloc.zig");
const slab_alloc = @import("slab-alloc.zig");
const Cache = slab_alloc.Cache;

// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();

//     // Create a 64-byte arena for our allocator to manage.
//     var arena_memory: [64]u8 = undefined;
//     const min_alloc = 8;

//     var buddy = try alloc.BuddyAllocator.init(allocator, &arena_memory, min_alloc);
//     defer buddy.deinit();

//     const writer = std.io.getStdOut().writer();

//     // try writer.print("Initial State:\n", .{});

//     try writer.print("\nAllocating 10 bytes (round up to 16)...\n", .{});
//     const ptr1 = try buddy.malloc(10);
//     std.debug.assert(ptr1 != null);

//     try writer.print("\nAllocating 10 bytes (round up to 16)...\n", .{});
//     const ptr2 = try buddy.malloc(10);
//     std.debug.assert(ptr2 != null);

//     try writer.print("Freeeing first allocation...\n", .{});
//     buddy.free(ptr1.?);

//     try writer.print("Freeeing second allocation (should coalesce)...\n", .{});
//     buddy.free(ptr2.?);

//     // try writer.print("\nFinal State:\n", .{});
// }

const Foo = struct { a: u64, b: u64 };

// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//     const writer = std.io.getStdOut().writer();
//     const slab_size = 4096;

//     // --- 1. Bootstrap the cache_cache ---
//     // Manually allocate memory for the first cache.
//     var cache_cache_mem = try allocator.create(slab_alloc.Cache);
//     cache_cache_mem.init(allocator, @sizeOf(slab_alloc.Cache), slab_size);

//     try writer.print("--- Initial State ---\n", .{});
//     try cache_cache_mem.dump(writer);

//     // --- 2. Create a new cache for our Foo objects ---
//     const foo_cache = try slab_alloc.Cache.createNewCache(cache_cache_mem, allocator, @sizeOf(Foo), slab_size);

//     try writer.print("--- After creating foo_cache ---\n", .{});
//     try cache_cache_mem.dump(writer); // cache_cache now has one object in use.

//     // --- 3. Allocate and free a Foo object ---
//     try writer.print("--- Allocating a Foo ---\n", .{});
//     const foo_ptr = try foo_cache.alloc(slab_size);
//     try foo_cache.dump(writer);

//     try writer.print("--- Freeing a Foo ---\n", .{});
//     foo_cache.free_cache(foo_ptr);
//     try foo_cache.dump(writer);
// }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const writer = std.io.getStdOut().writer();
    const slab_size = 4096;

    // --- 1. Bootstrap the cache_cache ---
    // Manually allocate memory for the first cache.
    var cache_cache_mem = try allocator.create(slab_alloc.Cache);
    cache_cache_mem.init(allocator, @sizeOf(slab_alloc.Cache), slab_size);

    // --- 2. Create a new cache for our Foo objects ---
    const foo_cache = try slab_alloc.Cache.createNewCache(cache_cache_mem, allocator, @sizeOf(Foo), slab_size);

    // Keep track of all the pointers we allocate
    var pointers = std.ArrayList(?*anyopaque).init(allocator);
    defer pointers.deinit();

    try writer.print("--- 1. Filling the first slab... ---\n", .{});
    // The number of objects per slab was calculated in init()
    for (0..foo_cache.objs_per_slab) |_| {
        const ptr = try foo_cache.alloc(slab_size);
        try pointers.append(ptr);
    }
    try foo_cache.dump(writer);

    try writer.print("--- 2. Allocating one more to force a grow... ---\n", .{});
    const extra_ptr = try foo_cache.alloc(slab_size);
    try pointers.append(extra_ptr);
    try foo_cache.dump(writer);

    try writer.print("--- 3. Freeing an object from the full slab... ---\n", .{});
    const ptr_to_free = pointers.items[0]; // Free the very first object we allocated
    foo_cache.free_cache(ptr_to_free);
    try foo_cache.dump(writer);
}
