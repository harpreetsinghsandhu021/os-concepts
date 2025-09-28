const std = @import("std");

// Holds the register state for a single memory segment.
pub const Segment = struct {
    base: usize,
    limit: usize,
    grows_positive: bool,
};

// Represents the state of an MMU that supports segmentation.
// It now holds an array of segment registers.
pub const MMU = struct {
    segments: [2]Segment, // Array for our two segments

    // Translates a virtual address using segmentation logic.
    pub fn translate(self: MMU, vaddr: usize, asize: usize) ?usize {
        // 1. Determine the segment by checking the top bit.
        const seg_index = vaddr / (asize / 2);
        const segment = self.segments[seg_index];

        if (segment.grows_positive) {
            // --- LOGIC FOR SEGMENT 0 (CODE/HEAP) ---
            // The virtual address is the offset.
            const offset = vaddr;
            if (offset >= segment.limit) {
                return null; // Segfault
            }

            return segment.base + offset;
        } else {
            // --- LOGIC FOR SEGMENT 1 (STACK) ---
            // The virtual addresses are in the top half, e.g, 8192-16383.
            // We need the offset from the top of the address space.
            const offset_from_top = asize - vaddr;
            if (offset_from_top > segment.limit) {
                return null;
            }

            // The base points to the top of the physical block, we subtract.
            return segment.base - offset_from_top;
        }
    }
};

// The main struct to manage our memory simulation.
pub const Simulator = struct {
    mmu: MMU,
    address_space_size: usize,
    num_addresses_to_gen: u32,

    pub fn run(self: *Simulator, writer: anytype) !void {
        try writer.print("Segment 0 -> Base: 0x{x:0>8}, Limit: {d}\n", .{
            self.mmu.segments[0].base, self.mmu.segments[0].limit,
        });

        try writer.print("Segment 1 -> Base: 0x{x:0>8}, Limit: {d}\n\n", .{
            self.mmu.segments[1].base, self.mmu.segments[1].limit,
        });

        try writer.print("Virtual Address Trace\n", .{});

        var prng = std.Random.DefaultPrng.init(0);
        const rand = prng.random();

        for (0..self.num_addresses_to_gen) |i| {
            const vaddr = rand.uintAtMost(usize, self.address_space_size - 1);

            if (self.mmu.translate(vaddr, self.address_space_size)) |paddr| {
                try writer.print("  VA {d:2}: 0x{x:0>8} --> VALID: 0x{x:0>8}\n", .{ i, vaddr, paddr });
            } else {
                try writer.print("  VA {d:2}: 0x{x:0>8} --> SEGMENTATION VIOLATION\n", .{ i, vaddr });
            }
        }
    }
};
