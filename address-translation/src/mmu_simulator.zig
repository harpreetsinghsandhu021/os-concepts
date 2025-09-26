const std = @import("std");
const Allocator = std.mem.Allocator;

// Represents the state of a simple Memory Management Unit (MMU) with base and bounds registers.
pub const MMU = struct {
    base: usize,
    limit: usize,

    // Takes a virtual address and returns a physical address.
    // Returns `null` if the virtual address is out of bounds (a segmentation fault).
    pub fn translate(self: MMU, vaddr: usize) ?usize {
        // 1. The Protection check
        if (vaddr > self.limit) {
            return null; // SEGMENTATION FAULT
        }

        // 2. The relocation
        return self.base + vaddr;
    }
};

// The main struct to manage our memory virtualization simulation.
pub const Simulator = struct {
    mmu: MMU,

    // --- Configuration ---
    address_space_size: usize,
    num_addresses_to_gen: u32,

    pub fn run(self: *Simulator, writer: anytype) !void {
        try writer.print(" Base   : 0x{x:0>8} (decimal {d})\n", .{ self.mmu.base, self.mmu.base });
        try writer.print(" Limit  : {d}\n\n", .{self.mmu.limit});
        try writer.print("Virtual Address Trace\n", .{});

        var prng = std.Random.DefaultPrng.init(0);
        const rand = prng.random();

        for (0..self.num_addresses_to_gen) |i| {
            const vaddr = rand.uintAtMost(usize, self.address_space_size - 1);

            if (self.mmu.translate(vaddr)) |paddr| {
                try writer.print(" VA {d:2}: 0x{x:0>8} (decimal: {d:4}) --> VALID 0x{x:0>8} (decimal: {d:4})\n", .{ i, vaddr, vaddr, paddr, paddr });
            } else {
                try writer.print(" VA {d:2}: 0x{x:0>8} (decimal: {d:4}) --> SEGMENTATION VIOLATION\n", .{ i, vaddr, vaddr });
            }
        }
    }
};

fn parseSize(text: []const u8) !usize {
    // ... logic to parse "16k", "1m", etc. ...
    // For a blog post, we'll keep it simple, but a real implementation would go here.
    // For now, we'll hard code.
    _ = text;
    return 16 * 1024;
}
