const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
};

const list = struct {
    /// Initializes a list head to be an empty list (points to itself).
    pub fn init(head: *Node) void {
        head.next = head;
        head.prev = head;
    }

    // Inserts a new node between the two known nodes.
    fn insert(new_node: *Node, prev: *Node, next: *Node) void {
        prev.next = new_node;
        new_node.next = next;
        next.prev = new_node;
        new_node.prev = prev;
    }

    // Appends a new node to the end of a list (before the head).
    pub fn append(head: *Node, new_node: *Node) void {
        // The last real element is the one before the head.
        const last_node = head.prev.?;
        list.insert(new_node, last_node, head);
    }

    // Removes a node from its list.
    pub fn remove(node: *Node) void {
        node.prev.?.next = node.next;
        node.next.?.prev = node.prev;
        // Set to null to show it's unlinked.
        node.next = null;
        node.prev = null;
    }

    // Gets the first real element in the list, or null if empty.
    pub fn first(head: *Node) ?*Node {
        if (head.next == head) {
            return null; // List is empty
        }

        return head.next;
    }
};

// Slab is a single, contiguous chunk of memory that contains the metadata, the free list, and
// the actual object storage.
pub const Slab = struct {
    // The intrusive linked list node
    node: Node,

    // A pointer back to the `Cache` that owns this slab. This is needed so that the slab knows
    // about the rules of the game like obj_size.
    cache: *Cache,

    // A slice representing the raw memory area where the actual objects are stored.
    // This is the egg section of our egg carton.
    memory: []u8,

    // The slab's internal free list. It's a stack of indices (`u32`) that point to the free
    // object slots within the memory slice. We pop an index to alloc and push one to free.
    free_list_stack: []u32,

    // A simple counter for how many free slots are currently available in this slab.
    // It also acts as the `stack pointer` for our `free_list_stack`.
    free_count: u32,
};

// Cache acts as the "factory manager" for a single type of object. It doesn't hold the objects
// themselves, but it manages all the `Slab's` that do.
pub const Cache = struct {
    allocator: std.mem.Allocator,

    // These lists will hold our Slab objects.

    // The linked list of slabs that have no free objects.
    // We don't even bother looking here for an allocation.
    full: Node,

    // The linked list of slabs that have some free objects.
    // This is the first place we look when a new allocation is requested.
    // It's the most efficient source of free objects.
    partial: Node,

    // The linked list of slabs where all objects are free. We only use
    // a slab from this list if the `partial` list is empty.
    free: Node,

    // Tracks the length of each list.
    full_len: u32 = 0,
    partial_len: u32 = 0,
    free_len: u32 = 0,

    // The size (in bytes) of a single object that this cache allocates.
    // All slabs in this cache will be carved up for objects of this size.
    obj_size: usize,

    // The calculated number of objects that can fit in a single slab.
    // This is determined once the cache is created.
    objs_per_slab: u32,

    // Simple counters for tracking statistics
    // The total number of object slots this cache has ever created.
    total_objs: u32,
    // The total number of object slots that are currently allocated.
    in_use: u32,

    pub fn init(self: *Cache, allocator: Allocator, obj_size: usize, slab_size: usize) void {
        self.* = .{
            .full = .{},
            .partial = .{},
            .free = .{},
            .obj_size = obj_size,
            .objs_per_slab = 0,
            .total_objs = 0,
            .in_use = 0,
            .allocator = allocator,
        };

        list.init(&self.full);
        list.init(&self.partial);
        list.init(&self.free);

        // Calculation: How many objects can we fit?
        // A slab needs space for the Slab struct, the free list indices, and the objects.
        const metadata_size = @sizeOf(Slab);
        // We subtract the Slab metadata size from the total slab size to find the usable space.
        const usable_space = slab_size - metadata_size;
        // Each object needs space for itself AND for one u32 in the free list.
        const space_per_obj = obj_size + @sizeOf(u32);
        self.objs_per_slab = @intCast(usable_space / space_per_obj);
    }

    pub fn deinit(self: *Cache) void {
        _ = self;
    }

    // Allocates a raw memory page and partitions it into a new, empty Slab for this cache.
    pub fn grow(self: *Cache, slab_size: usize) !void {
        // --- Step 1: Get Raw Memory ---
        // Request a single, large, unformatted chunk of memory from the OS.
        // This is our raw material. For this function, it's just a slice of bytes.
        const slab_mem = try self.allocator.alignedAlloc(u8, @alignOf(Slab), slab_size);
        errdefer self.allocator.free(slab_mem);

        // --- Step 2: Place the Slab Metadata ---
        // The very beginning of this raw memory will hold our `Slab` metadata struct.
        // We cast the raw `[*]u8` pointer to a `*Slab` pointer to give it a type.
        // This doesn't copy any memory, it just reinterprets the address.

        // Perform the cast the fundamental way.
        // Get the memory address of the slice's start as an integer
        const ptr_as_int = @intFromPtr(slab_mem.ptr);
        // Cast the integer back into a pointer of the correct type (*Slab)
        const slab: *Slab = @ptrFromInt(ptr_as_int);

        // --- Step 3: Calculate the Layout with Integer Math ---
        // To do byte-level calculations for the layout, we convert the base pointer to
        // a `usize` integer. This lets us do simple addition with byte sizes.
        const base_addr = @intFromPtr(slab_mem.ptr);

        // The free list stack (the `bufctl` array) lives immediately after the Slab
        // struct in memory. Its starting address is simply the base address plus the size
        // of the Slab struct.
        const free_list_start_addr = base_addr + @sizeOf(Slab);

        // The actual storage area for the objects comes immediately after the free list
        // stack. We calculate its start address by adding the total size of the free list
        // to that stack's start address.
        const obj_storage_start_addr = free_list_start_addr + (self.objs_per_slab * @sizeOf(u32));

        // --- Step 4: Initialize the Slab Struct Fields ---
        // Now that we have all our calculated addresses, we can initialize the Slab struct.
        const list_stack: [*]u32 = @ptrFromInt(free_list_start_addr);
        const memory_slice: [*]u8 = @ptrFromInt(obj_storage_start_addr);
        slab.* = .{
            .node = .{}, // Linked list node is unlinked for now.
            .cache = self, // Pointer back to the cache that owns this slab.

            // Take the integer address we calculated for the free list, cast it back into
            // many-item pointer to `u32` (`[*]u32`), and then slice it to the correct length.
            // This creates our `[]u32` slice.
            .free_list_stack = list_stack[0..self.objs_per_slab],
            .memory = memory_slice[0 .. self.objs_per_slab * self.obj_size],
            .free_count = 0,
        };

        // --- Step 5: Initialize the Slab's Internal free list ---
        // The slab starts completely free. Its internal free list is a stack of indices that
        // point to each available object slot. We initialize it here to be full: `free_list_stack[0] = 0`,
        // `free_list_stack[1] = 1`, etc.
        for (slab.free_list_stack, 0..) |*idx, i| {
            idx.* = @intCast(i);
        }
        slab.free_count = self.objs_per_slab;

        // --- Step 6: Add the New Slab to the Cache ---
        // Finally, add this newly minted, fully-free slab to the cache's `free` list, making it
        // available for future allocation.
        list.append(&self.free, &slab.node);
        self.free_len += 1;
        self.total_objs += self.objs_per_slab;
    }

    // Finds a slab with available objects, growing the cache if necessary.
    fn selectSlab(self: *Cache, slab_size: usize) !*Slab {
        // Rule 1: Try the partial list first.
        if (list.first(&self.partial)) |node| return @fieldParentPtr("node", node);

        // Rule 2: If no partial slabs, try the free list.
        if (list.first(&self.free)) |node| return @fieldParentPtr("node", node);

        // Rule 3: No slabs available, so grow the cache.
        try self.grow(slab_size);

        const node = list.first(&self.free) orelse return error.OutOfMemory;
        return @fieldParentPtr("node", node);
    }

    pub fn alloc(self: *Cache, slab_size: usize) !?*anyopaque {
        const slab = self.selectSlab(slab_size) catch return error.OutOfMemory;

        // --- The "Pop" ---
        // The free list is a stack. Decrement the count to get the index of the top item, which holds the index
        // of the next free object slot.
        slab.free_count -= 1;
        const free_idx = slab.free_list_stack[slab.free_count];

        // Calculate the pointer to the actual object storage.
        const ptr = slab.memory.ptr + (free_idx * self.obj_size);

        // --- List Management ---
        // If the slab was completely free before this allocation...
        if (slab.free_count == self.objs_per_slab - 1) {
            // ... it's now partially full. Move it from the free list to the partial list.

            list.remove(&slab.node);
            self.free_len -= 1;
            list.append(&self.partial, &slab.node);
            self.partial_len += 1;
        } else if (slab.free_count == 0) { // If the slab is now completely full...
            // ...move it from the partial list to the full list.

            list.remove(&slab.node);
            self.partial_len -= 1;
            list.append(&self.full, &slab.node);
            self.full_len += 1;
        }

        self.in_use += 1;
        return @ptrFromInt(@intFromPtr(ptr));
    }

    // Searches a given slab list and deallocates the pointer if it belongs to a slab in that list.
    fn deallocFromSlabList(self: *Cache, head: *Node, ptr: *anyopaque) bool {
        var current_node = list.first(head);

        while (current_node) |node| {
            const slab: *Slab = @fieldParentPtr("node", node);
            const ptr_addr = @intFromPtr(ptr);
            const mem_start_addr = @intFromPtr(slab.memory.ptr);
            const mem_end_addr = mem_start_addr + slab.memory.len;

            // Check if the pointer falls within this slab's memory range.
            if (ptr_addr >= mem_start_addr and ptr_addr < mem_end_addr) {
                // --- Found the slab. Now, free the object. ---

                // 1. Calculate the object's index from its pointer.
                const offset = ptr_addr - mem_start_addr;
                const index: u32 = @intCast(offset / self.obj_size);

                // 2. "Push" the index back onto the slab's free list stack.
                slab.free_list_stack[slab.free_count] = index;
                slab.free_count += 1;

                // --- List Management ---
                // If the slab was full, it's now partial.
                if (slab.free_count == 1) {
                    list.remove(&slab.node);
                    self.full_len -= 1;
                    list.append(&self.partial, &slab.node);
                    self.partial_len += 1;
                } else if (slab.free_count == self.objs_per_slab) { // If the slab was partial and is now completely empty..
                    // ... move it to the free list.
                    list.remove(&slab.node);
                    self.partial_len -= 1;
                    list.append(&self.free, &slab.node);
                    self.free_len += 1;
                }

                self.in_use -= 1;
                return true; // Deallocation successfull.
            }

            current_node = node.next;
            if (current_node == head) break; // Full Circle
        }

        return false; // Pointer not found in this list.
    }

    // Frees a previously allocated object.
    pub fn free_cache(self: *Cache, ptr: ?*anyopaque) void {
        const p = ptr orelse return;
        if (self.deallocFromSlabList(&self.full, p)) return;
        if (self.deallocFromSlabList(&self.partial, p)) return;

        // If the pointer was'nt in the full or partial lists, it's either an invalid
        // pointer or a double-free.
    }

    // A helper function to create a new Cache using the cache_cache.
    pub fn createNewCache(cache_cache: *Cache, allocator: Allocator, obj_size: usize, slab_size: usize) !*Cache {
        // Allocate a new Cache struct from the cache_cache.
        const new_cache_ptr = try cache_cache.alloc(slab_size);
        const new_cache_addr = @intFromPtr(new_cache_ptr.?);
        const new_cache: *Cache = @ptrFromInt(new_cache_addr);
        new_cache.init(allocator, obj_size, slab_size);

        return new_cache;
    }

    pub fn dump(self: *const Cache, writer: anytype) !void {
        try writer.print(
            \\ Cache Stats:
            \\   - Objects In Use: {d}/{d}
            \\   - Object Size: {d} bytes
            \\   - Objects Per Slab: {d}
            \\   - Slabs -> Full: {d}, Partial: {d}, Free: {d}
            \\ 
        , .{ self.in_use, self.total_objs, self.obj_size, self.objs_per_slab, self.full_len, self.partial_len, self.free_len });
    }
};
