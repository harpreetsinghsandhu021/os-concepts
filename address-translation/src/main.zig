const std = @import("std");
const simulator = @import("./mmu_simulator.zig");
pub fn main() !void {
    // --- Configuration ---
    const p_size: usize = 16 * 1024; // 16k physical memory
    const a_size: usize = 1 * 1024; // 1k address space
    const num_addrs = 5;

    // Randomly place the process in memory
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    const limit = a_size; // Limit is just the size of the address space
    const base = rand.uintAtMost(usize, p_size - limit - 1);

    // Run the Simulation
    var sim = simulator.Simulator{
        .mmu = .{ .base = base, .limit = limit },
        .address_space_size = a_size,
        .num_addresses_to_gen = num_addrs,
    };

    const writer = std.io.getStdOut().writer();
    try sim.run(writer);
}
