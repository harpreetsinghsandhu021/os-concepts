const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BitSet = struct {
    bits: []u8,
    allocator: Allocator,

    // Creates a new BitSet with enough bytes to hold `num_bits`, will all bits initialized to 0.
    pub fn init(allocator: Allocator, num_bits: usize) !BitSet {
        // The `+ 7` is a common integer arithematic trick to perform a ceiling division.
        // It ensures we allocate enough whole bytes to store all the bits. For example, 9 bits needs `(9 + 7) / 8 = 2` bytes.
        const num_bytes = (num_bits + 7) / 8;

        // Request a slice of `u8` (bytes) from the system via the provided allocator. This can fail if we're out of memory.
        const slice = try allocator.alloc(u8, num_bytes);

        // It's crucial to zero out the memory. This ensures our bitset starts `clean` with all the bits set to 0 (false).
        for (slice) |*byte| {
            byte.* = 0;
        }

        return BitSet{
            .bits = slice,
            .allocator = allocator,
        };
    }

    // Fress the memory slice used by the BitSet.
    pub fn deinit(self: *BitSet) void {
        self.allocator.free(self.bits);
    }

    // Sets the bit at a given position to 1 (true).
    pub fn set(self: *BitSet, pos: usize) void {
        // Figure out which byte in our slice holds the bit we're interested in.
        // Since there are 8 bits per byte, we divide by 8.
        const byte_index = pos / 8;

        // Figure out the exact position of the bit within that byte (0-7).
        const bit_index = pos % 8;

        // 1. Start with the number 1, which is `00000001` in binary.
        // 2. Left-shift the 1 by `bit_index`. This creates a `mask` where only the bit we care about is set.
        // e.g, if bit_index is 3, the mask becomes `00001000`.
        // 3. Use the bitwise OR (`|=`) operator. This merges our mask with the existing byte, setting our target bit to 1 without
        // affecting any of the other bits.
        self.bits[byte_index] |= (@as(u8, 1) << @intCast(bit_index));
    }

    // Clears the bit at a given position to 0 (false).
    pub fn clear(self: *BitSet, pos: usize) void {
        const byte_index = pos / 8;
        const bit_index = pos % 8;

        // This is the inverse of `set()`:
        // 1. Create the same mask as before e.g, `00001000`.
        // 2. Use the bitwise NOT (`~`) operator to invert the mask. `00001000` becomes `11110111`. Now, every bit is 1 except
        // for the one we want to clear.
        // 3. Use the bitwise AND (`&=`) operator. `X AND 1 = X` and `X AND 0 = 0`. This operation clears our target bit to 0 without afecting
        // any of the other bits.
        self.bits[byte_index] &= ~(@as(u8, 1) << @intCast(bit_index));
    }

    // Returns `true` if the bit at a given position is 1, `false` otherwise.
    pub fn bitset_test(self: *const BitSet, pos: usize) bool {
        const byte_index = pos / 8;
        const bit_index = pos % 8;

        // 1. Create the mask with the target bit set e.g, `00001000`.
        // 2. Use bitwise AND (`&`) to isolate our target bit. If the bit in the original byte was 1, the result is the mask. If it was 0, the
        // result is all zeros (`00000000`).
        // 3. Check if the result is non-zero. If it is, the bit was set.
        return (self.bits[byte_index] & (@as(u8, 1) << @intCast(bit_index))) != 0;
    }
};

// Represents a node in the conceptual buddy tree.
pub const Node = struct { index: usize, depth: u8 };

pub const BuddyTree = struct {
    // The maximum depth of the tree. An order of 20 can manage 2^20 blocks.
    order: u8,
    // A slice where each byte stores the status of a corresponding node
    status: []u8,
    allocator: Allocator,

    // Creates a new BuddyTree for a given order.
    pub fn init(allocator: Allocator, order: u8) !BuddyTree {
        // A complete binary tree of `order` levels has (2 ^ (order+1) - 1) nodes.
        // We allocate one extra bit to make 1-based indexing easier.
        const total_nodes = (@as(usize, 1) << @intCast(order + 1));
        const status_slice = try allocator.alloc(u8, total_nodes);

        for (status_slice) |*status| {
            status.* = 0;
        }

        return BuddyTree{ .order = order, .status = status_slice, .allocator = allocator };
    }

    pub fn deinit(self: *BuddyTree) void {
        self.allocator.free(self.status);
    }

    // Returns the root node of the tree.
    pub fn root(self: *const BuddyTree) Node {
        _ = self;
        return Node{ .index = 1, .depth = 1 };
    }

    // Returns the parent of a given node.
    pub fn parent(self: *const BuddyTree, node: Node) ?Node {
        _ = self;
        if (node.index <= 1) return null;

        return Node{ .index = node.index / 2, .depth = node.depth - 1 };
    }

    // Returns the left child of a given node.
    pub fn leftChild(self: *const BuddyTree, node: Node) Node {
        _ = self;
        return Node{ .index = node.index * 2, .depth = node.depth + 1 };
    }

    // Returns the `buddy` of a given node.
    pub fn sibling(self: *const BuddyTree, node: Node) Node {
        _ = self;

        // The bitwise XOR trick: if index is even (e.g, 10), it becomes odd (11).
        // If it's odd (11), it becomes even (10). This flips between left/right children.
        return Node{ .index = node.index ^ 1, .depth = node.depth };
    }

    // Recursively finds a free node at a specific depth.
    pub fn findFree(self: *const BuddyTree, target_depth: u8, current_node: Node) ?Node {
        // The status number tells us the order of the LARGEST free block in this subtree.
        // A smaller status numner means a larger free block.
        const required_status = self.order - target_depth;
        if (self.status[current_node.index] > required_status) {
            return null; // The subtree doesn't contain a free block big enough.
        }

        // Base case: We are at the target depth. If the status is what we require, it means this block is available.
        if (current_node.depth == target_depth) {
            return current_node;
        }

        // Try to find a free block in its left child's subtree first.
        const left = self.leftChild(current_node);
        if (self.status[left.index] <= required_status) {
            return self.findFree(target_depth, left);
        }

        // If nothing was found on the left, try the right child's subtree.
        // The right child is just the sibling of the left child.
        return self.findFree(target_depth, self.sibling(left));
    }

    // Marks a node as used and propagates status change up the parent chain.
    pub fn markAsUsed(self: *BuddyTree, node: Node) void {
        // A fully used node has a status equal to its maximum possible order.
        const max_status = self.order - node.depth + 1;
        self.status[node.index] = max_status;

        var current = node;
        while (self.parent(current)) |parent_node| {
            const buddy = self.sibling(current);
            const buddy_status = self.status[buddy.index];
            const current_status = self.status[current.index];

            // The parent's status is 1 + the minimum of its children's statuses.
            self.status[parent_node.index] = 1 + @min(buddy_status, current_status);
            current = parent_node;
        }
    }

    // Releases a node and recursively coalesces with its buddy, also updating parent statuses.
    pub fn releaseAndCoalesce(self: *BuddyTree, node: Node) void {
        // A freed node has a status of 0.
        self.status[node.index] = 0;

        var current = node;
        while (self.parent(current)) |parent_node| {
            const buddy = self.sibling(current);

            if (self.status[current.index] == 0 and self.status[buddy.index] == 0) {
                // If this node and its buddy are both fully free, their parent also becomes fully free.
                self.status[parent_node.index] = 0;
            } else {
                // Otherwise, the parent is partially used. Recalculate its status.
                const buddy_status = self.status[buddy.index];
                const current_status = self.status[current.index];
                self.status[parent_node.index] = 1 + @min(buddy_status, current_status);
            }
            current = parent_node;
        }
    }
};

pub const BuddyAllocator = struct {
    allocator: Allocator, // For the allocator's own metadata
    arena: []u8, // The memory the allocator manages
    tree: BuddyTree,
    min_alloc_size: usize,

    // Creates a new BuddyAllocator to manage the provided memory arena.
    pub fn init(allocator: Allocator, arena: []u8, min_alloc_size: usize) !BuddyAllocator {
        // Calculate the order of the tree needed to manage this arena.
        const order = std.math.log2_int(usize, arena.len / min_alloc_size) + 1;

        return BuddyAllocator{
            .allocator = allocator,
            .arena = arena,
            .tree = try BuddyTree.init(allocator, @intCast(order)),
            .min_alloc_size = min_alloc_size,
        };
    }

    pub fn deinit(self: *BuddyAllocator) void {
        self.tree.deinit();
    }

    // Allocates a block of memory.
    pub fn malloc(self: *BuddyAllocator, size: usize) !?*anyopaque {
        // --- Step 1: Calculate Required Block Size ---
        // Buddy allocators only work with power-of-two sizes. We find the smallest power of two that is big enough to hold the request.
        // e.g, a request for 100 bytes will be rounded up to 128.
        const alloc_size = try std.math.ceilPowerOfTwo(usize, size);

        // --- Step 2: Convert Size to a Tree Depth ---
        // How many of the smallest possible blocks fits into our desired size?
        // e.g, if we need 128 bytes and the min is 16, this is 8.
        const num_min_blocks = alloc_size / self.min_alloc_size;

        // The tree's depth is "inverted": depth 1 is the largest block, and the max depth is the smallest. We use log2 to find the
        // "level" of our size and subtract from the max order to get the target depth.
        const power_of_two_level = std.math.log2_int(usize, num_min_blocks);
        const depth: u8 = self.tree.order - @as(u8, @intCast(power_of_two_level));

        // --- Step 3: Find and Mark a Node in the Tree ---
        // Ask the BuddyTree to find a free node at our target depth.
        if (self.tree.findFree(depth, self.tree.root())) |node| {
            // if we found one, claim it and update the tree's status bits.
            self.tree.markAsUsed(node);

            // --- Step 4: Convert the Node back to a Memory Address ---
            // Calculate the size in bytes of any block at this depth.
            // The root (depth 1) is the whole arena. Each level down halves the size.
            // `arena.len >> (depth - 1)` is a fast way to do `arena.len / 2^(depth - 1)`.
            const block_size_at_depth = self.arena.len >> @intCast(node.depth - 1);

            // Calculate the node's zero-based column within its own level.
            // A level `d` in a binary tree starts at global index `2^(d-1)`.
            const level_start_index = @as(usize, 1) << @intCast(node.depth - 1);
            const index_in_level = node.index - level_start_index;

            // The final address is the start of the arena plus the offset.
            const addr_offset = index_in_level * block_size_at_depth;
            const final_ptr: *anyopaque = @ptrFromInt(@intFromPtr(self.arena.ptr) + addr_offset);

            return final_ptr;
        } else {
            // No node of the required size was available.
            return null; // Out of memory.
        }
    }

    // Frees a previously allocated block of memory.
    pub fn free(self: *BuddyAllocator, ptr: *anyopaque) void {
        // --- Step 1: Convert Address back to a Node ---
        // Get the address as a simple byte offset from the start of our memory arena.
        const addr_offset = @intFromPtr(ptr) - @intFromPtr(self.arena.ptr);

        // Look up the size of the block being freed.
        // Note: A real allocator gets this from a header or hash map, we simplify here.
        const size = self.findAllocatedSize(addr_offset);

        // Do the same `size -> depth` calculation as in `malloc`.
        const num_min_blocks = size / self.min_alloc_size;
        const power_of_two_level = std.math.log2_int(usize, num_min_blocks);
        const depth: u8 = self.tree.order - @as(u8, @intCast(power_of_two_level));

        // Calculate the size of blocks at this depth.
        const block_size_at_depth = self.arena.len >> @intCast(depth - 1);

        // Figure out the block's zero-based column within its level.
        const index_in_level = addr_offset / block_size_at_depth;

        // Reconstruct the global tree index from the level's start and the column.
        const level_start_index = @as(usize, 1) << @intCast(depth - 1);
        const index = level_start_index + index_in_level;

        // Now, we have the full `coordinate` of the block in our tree.
        const node = Node{ .index = index, .depth = depth };

        // --- Step 2: Release the Node ---
        // Tell the BuddyTree to free this node and trigger the coalescing magic.
        self.tree.releaseAndCoalesce(node);
    }

    // A helper function to find the size of an allocation given its address.
    fn findAllocatedSize(self: *BuddyAllocator, offset: usize) usize {
        _ = offset;
        return self.min_alloc_size;
    }
};
