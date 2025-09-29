const std = @import("std");
const Allocator = std.mem.Allocator;

// The placement policies for finding a free block.
pub const Policy = enum {
    first_fit,
    best_fit,
    worst_fit,
};

// The policies for how the free list is ordered
pub const ListOrder = enum {
    address_sort,
    size_sort_asc,
    size_sort_desc,
    insert_front,
    insert_back,
};

// Represents a single contiguos chunk of free memory on the heap.
pub const FreeBlock = struct {
    addr: usize,
    size: usize,
};

// The main struct that manages the heap and its free list.
pub const Mallocator = struct {
    allocator: Allocator, // For this struct's own memory needs

    // --- Heap State ---
    heap_start: usize,
    heap_size: usize,
    free_list: std.ArrayList(FreeBlock),

    // Maps an allocated address to its size, needed for free()
    size_map: std.AutoHashMap(usize, usize),

    // --- Configuration ---
    policy: Policy,
    list_order: ListOrder,
    header_size: usize,
    coalesce: bool,

    pub fn init(allocator: Allocator, heap_start: usize, heap_size: usize, policy: Policy, list_order: ListOrder, header_size: usize, coalesce: bool) !Mallocator {
        var free_list = std.ArrayList(FreeBlock).init(allocator);
        try free_list.append(.{ .addr = heap_start, .size = heap_size });

        return Mallocator{ .allocator = allocator, .heap_start = heap_start, .heap_size = heap_size, .free_list = free_list, .size_map = std.AutoHashMap(usize, usize).init(allocator), .policy = policy, .list_order = list_order, .header_size = header_size, .coalesce = coalesce };
    }

    pub fn deinit(self: *Mallocator) void {
        self.free_list.deinit();
        self.size_map.deinit();
    }

    pub fn malloc(self: *Mallocator, size: usize) !struct { ptr: isize, count: u32 } {
        // 1. Account for header size. (Alignment logic would also go here).
        const required_size = size + self.header_size;

        // 2. Scan the free list to find a suitable block.
        var best_idx: ?usize = null;
        var best_size: usize = 0; // Will be set based on policy
        var search_count: u32 = 0;

        switch (self.policy) {
            .best_fit => best_size = std.math.maxInt(usize),
            .worst_fit => best_size = 0,
            .first_fit => {}, // No init needed
        }

        for (self.free_list.items, 0..) |block, i| {
            search_count += 1;

            if (block.size >= required_size) {
                switch (self.policy) {
                    .first_fit => {
                        best_idx = i;
                        break; // Found one, we're done.
                    },
                    .best_fit => {
                        if (block.size < best_size) {
                            best_size = block.size;
                            best_idx = i;
                        }
                    },
                    .worst_fit => {
                        if (block.size > best_size) {
                            best_size = block.size;
                            best_idx = i;
                        }
                    },
                }
            }
        }

        // 3. If we found a block, allocate from it.
        if (best_idx) |idx| {
            const block = self.free_list.items[idx];

            // If the block is larger than needed, split it.
            // The first part is allocated, the second part remains on the free list.
            if (block.size > required_size) {
                const new_free_size = block.size - required_size;
                self.free_list.items[idx] = .{ .addr = block.addr + required_size, .size = new_free_size };
            } else {
                // Perfect fit, remove the whole block.
                _ = self.free_list.swapRemove(idx);
            }

            // Record the allocation and return the pointer.
            try self.size_map.put(block.addr, required_size);
            return .{ .ptr = @intCast(block.addr), .count = search_count };
        }

        // No suitable block was found, so return -1.
        return .{ .ptr = -1, .count = search_count };
    }

    pub fn free(self: *Mallocator, addr: usize) !void {
        // Look up the block's size.
        const size = self.size_map.fetchRemove(addr) orelse return;

        // 1. Add the block back to the free list based on the ordering policy.
        try self.free_list.append(.{ .addr = addr, .size = size.value });

        switch (self.list_order) {
            .address_sort => std.mem.sort(FreeBlock, self.free_list.items, {}, addrCompare),
            .size_sort_asc => std.mem.sort(FreeBlock, self.free_list.items, {}, sizeCompareAsc),
            .size_sort_desc => std.mem.sort(FreeBlock, self.free_list.items, {}, sizeCompareAsc),
            .insert_front => {
                const last_idx = self.free_list.items.len - 1;
                if (last_idx > 0) {
                    std.mem.swap(FreeBlock, &self.free_list.items[0], &self.free_list.items[last_idx]);
                }
            },
            .insert_back => {},
        }

        if (self.coalesce) {
            // Coalescing also needs the corrected sort call.
            std.mem.sort(FreeBlock, self.free_list.items, {}, addrCompare);

            var new_list = std.ArrayList(FreeBlock).init(self.allocator);
            errdefer new_list.deinit();

            if (self.free_list.items.len > 0) {
                var current = self.free_list.items[0];

                for (self.free_list.items[1..]) |next_block| {
                    if (current.addr + current.size == next_block.addr) {
                        current.size += next_block.size;
                    } else {
                        try new_list.append(current);
                        current = next_block;
                    }
                }

                try new_list.append(current);
            }
            self.free_list.deinit();
            self.free_list = new_list;
        }
    }

    // Prints the current state of the free list.
    pub fn dump(self: *Mallocator, writer: anytype) !void {
        try writer.print("Free List [ Size {d} ]: ", .{self.free_list.items.len});
        for (self.free_list.items) |block| {
            try writer.print("[ addr: {d} sz:{d} ]", .{ block.addr, block.size });
        }

        try writer.print("\n", .{});
    }

    // Runs a list of allocation/free operations.
    pub fn run(self: *Mallocator, writer: anytype, ops_list_str: []const u8) !void {
        var allocated_ptrs = std.ArrayList(usize).init(self.allocator);
        defer allocated_ptrs.deinit();

        var op_it = std.mem.splitAny(u8, ops_list_str, ",");

        while (op_it.next()) |op| {
            if (op[0] == '+') { // Allocation
                const size = try std.fmt.parseInt(usize, op[1..], 10);
                const result = try self.malloc(size);
                if (result.ptr != -1) {
                    try allocated_ptrs.append(@intCast((result.ptr)));
                }
                try writer.print("Alloc({d}) -> ptr {any}\n", .{ size, result.ptr });
            } else if (op[0] == '-') { //Free
                const idx = try std.fmt.parseInt(usize, op[1..], 10);

                if (idx >= allocated_ptrs.items.len) {
                    try writer.print("Invalid Free: Skipping\n", .{});
                    continue;
                }

                const ptr_to_free = allocated_ptrs.items[idx];
                try self.free(ptr_to_free);
                try writer.print("Free(ptr[{d}])\n", .{idx});
            }
            try self.dump(writer);
        }
    }
};

fn addrCompare(context: void, a: FreeBlock, b: FreeBlock) bool {
    _ = context;
    return a.addr < b.addr;
}

fn sizeCompareAsc(context: void, a: FreeBlock, b: FreeBlock) bool {
    _ = context;
    return a.size < b.size;
}

fn sizeCompareDesc(context: void, a: FreeBlock, b: FreeBlock) bool {
    _ = context;
    return a.size > b.size;
}
