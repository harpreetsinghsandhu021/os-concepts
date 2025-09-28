const std = @import("std");
const seg = @import("segmentation.zig");

pub fn main() !void {
    const p_size: usize = 64 * 1024; // 64k physical memory
    const a_size: usize = 16 * 1024; // 16k address space
    const num_addrs = 10;

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    const seg0_limit = rand.uintAtMost(usize, a_size / 2);
    const seg1_limit = rand.uintAtMost(usize, a_size / 2);

    const seg0_base = rand.uintAtMost(usize, p_size - seg0_limit - 1);

    var seg1_base: usize = undefined;

    while (true) {
        seg1_base = rand.uintAtMost(usize, p_size - seg1_limit - 1);

        const seg0_end = seg0_base + seg0_limit;
        const seg1_end = seg1_base + seg1_limit;
        if (seg0_end <= seg1_base or seg1_end <= seg0_base) {
            break;
        }
    }

    var simulator = seg.Simulator{
        .mmu = .{
            .segments = .{
                .{ .base = seg0_base, .limit = seg0_limit, .grows_positive = true },
                .{ .base = seg1_base + seg1_limit, .limit = seg1_limit, .grows_positive = false },
            },
        },
        .address_space_size = a_size,
        .num_addresses_to_gen = num_addrs,
    };

    const writer = std.io.getStdOut().writer();

    try simulator.run(writer);
}
