const std = @import("std");
const Allocator = std.mem.Allocator;

// The main struct to manage our fork simulation.
// It owns all the data structures that represent the process tree.
pub const Forker = struct {
    allocator: Allocator,
    // A list of currently active process names.
    process_list: std.ArrayList([]const u8),
    // Maps a parent's name to a list of its children's names.
    // string -> string[]
    children: std.StringHashMap(std.ArrayList([]const u8)),
    // Maps a child's name to its parent's name.
    parents: std.StringHashMap([]const u8),

    // --- Fields for name generation ---
    base_names: []const u8 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    curr_names: std.ArrayList(std.ArrayList(u8)),
    curr_index: usize,

    pub fn init(allocator: Allocator) !Forker {
        var self = Forker{
            .allocator = allocator,
            .process_list = std.ArrayList([]const u8).init(allocator),
            .children = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .parents = std.StringHashMap([]const u8).init(allocator),
            .curr_names = std.ArrayList(std.ArrayList(u8)).init(allocator),
            .curr_index = 1,
        };

        // Manually create the first generation of names (a-z, A-Z)
        for (self.base_names) |char| {
            var name_list = try std.ArrayList(u8).initCapacity(allocator, 1);
            try name_list.append(char);
            try self.curr_names.append(name_list);
        }

        // Create the root process 'a' to start the tree.
        try self.process_list.append("a");
        try self.children.put("a", std.ArrayList([]const u8).init(allocator));

        return self;
    }

    pub fn deinit(self: *Forker) void {
        var iterator = self.children.valueIterator();
        while (iterator.next()) |list| {
            list.deinit();
        }
        self.children.deinit();
        self.parents.deinit();
        self.process_list.deinit();

        // Also, clean up the name generator's memory.
        for (self.curr_names.items) |name| name.deinit();
        self.curr_names.deinit();
    }

    // Create longer names when we run out of shorter ones.
    fn growNames(self: *Forker) !void {
        var new_names = std.ArrayList(std.ArrayList(u8)).init(self.allocator);
        // Ensure we clean up the new list if an allocation fails mid-loop.
        defer if (new_names.items.len > 0) {
            for (new_names.items) |name| name.deinit();
            new_names.deinit();
        };

        for (self.curr_names.items) |b1| {
            for (self.base_names) |b2| {
                var new_name = std.ArrayList(u8).init(self.allocator);
                try new_name.appendSlice(b1);
                try new_name.append(b2);
                try new_names.append(new_name);
            }
        }

        // Free the old list of names.
        // for (self.curr_names.items) |name| name.deinit();
        self.curr_names.deinit();
        // and replace it with the new, longer names.
        self.curr_names = new_names;
        self.curr_index = 0;
    }

    // The main loop that parses actions and drives the simulation.
    pub fn run(self: *Forker, action_list_str: []const u8) !void {
        const writer = std.io.getStdOut().writer();
        try writer.print("Initial Tree:\n", .{});
        try self.printTree(writer);

        var action_it = std.mem.splitAny(u8, action_list_str, ",");
        while (action_it.next()) |action| {
            try writer.print("\nAction: {s}\n", .{action});

            // Parse the action string
            if (std.mem.indexOf(u8, action, "+")) |split_idx| {
                const parent = action[0..split_idx];
                const child = action[split_idx + 1 ..];

                // In a real program, you'add more error checking here.
                try self.doFork(parent, child);
            } else if (std.mem.indexOf(u8, action, "-")) |split_idx| {
                const proc_to_exit = action[0..split_idx];
                try self.doExit(proc_to_exit);
            }

            try self.printTree(writer);
        }
    }

    // Fetches the next available unique process name.
    pub fn getName(self: *Forker) !std.ArrayList(u8) {
        if (self.curr_index >= self.curr_names.items.len) {
            try self.growNames();
        }

        const names_slice = try self.curr_names.items[self.curr_index].items;
        const name_to_return = try self.allocator.dupe(u8, names_slice);
        self.curr_index += 1;
        return name_to_return;
    }

    // A parent process creates a new child process.
    pub fn doFork(self: *Forker, parent_name: []const u8, child_name: []const u8) !void {
        // 1. Add the new child to the master list of active processes.
        try self.process_list.append(child_name);

        // 2. Give the child its own (empty) list of children
        try self.children.put(child_name, std.ArrayList([]const u8).init(self.allocator));

        // 3. Add the child to its parent's list of children.
        var parent_children_list = self.children.getPtr(parent_name).?;
        try parent_children_list.append(child_name);

        // 4. Set the child' parent
        try self.parents.put(child_name, parent_name);
    }

    // A process exits, and its children are adopted by their grandparent.
    pub fn doExit(self: *Forker, exit_name: []const u8) !void {
        // 1. Find the parent of the exiting process (the grandparent).
        // If the process does'nt exist or has no parent (it's the root), we can't proceed.
        const grandparent_name = self.parents.get(exit_name) orelse return;

        // 2. Remove the exiting process from the master list.
        for (self.process_list.items, 0..) |process_name, i| {
            if (std.mem.eql(u8, process_name, exit_name)) {
                _ = self.process_list.swapRemove(i);
                break;
            }
        }

        // 3. Find the orphans (children of the exiting process).
        // We take ownership of the list of orphans by removing it from the map.
        var orphans_list = self.children.fetchRemove(exit_name).?.value;
        defer orphans_list.deinit();

        // 4. Re-parent each orphan.
        var grandparent_children_list = self.children.getPtr(grandparent_name).?;
        for (orphans_list.items) |orphan_name| {
            // The grandparent adopts the orphan.
            try grandparent_children_list.append(orphan_name);

            // The orphan's parent is now the grandparent.
            try self.parents.put(orphan_name, grandparent_name);
        }

        // 5. Final cleanup: Remove the exiting process from its parent's child list...
        for (grandparent_children_list.items, 0..) |child_name, i| {
            if (std.mem.eql(u8, child_name, exit_name)) {
                _ = grandparent_children_list.swapRemove(i);
                break;
            }
        }

        // ... and from the parents map.
        _ = self.parents.fetchRemove(exit_name);
    }

    // Recursively walks the process tree and prints it
    fn walk(self: *const Forker, writer: anytype, p_name: []const u8, level: u32, pmask: *std.AutoHashMap(u32, bool), is_last: bool) !void {
        // 1. Print the prefix (the | └── stuff)
        if (level > 0) {
            for (0..level - 1) |i| {
                if (pmask.get(@intCast(i)) != null) {
                    try writer.print("│   ", .{});
                } else {
                    try writer.print("    ", .{});
                }
            }

            if (is_last) {
                try writer.print("└── ", .{});
            } else {
                try writer.print("├── ", .{});
            }
        }

        // 2. Print the node itself.
        try writer.print("{s}\n", .{p_name});

        // 3. Recurse for each child.
        if (self.children.get(p_name)) |children_list| {
            // This is the key to drawing the lines correctly. If this node is the last in its peer group,
            // the vertical line at its level should not continue for its children.
            if (is_last and level > 0) {
                _ = pmask.remove(level - 1);
            }

            try pmask.put(level, true);

            for (children_list.items, 0..) |child_name, i| {
                const child_is_last = (i == children_list.items.len - 1);
                try self.walk(writer, child_name, level + 1, pmask, child_is_last);
            }

            // Clean up the mask for this level after we are done with its children.
            _ = pmask.remove(level);
        }
    }

    // Public method to start printing the tree from the root.
    pub fn printTree(self: *const Forker, writer: anytype) !void {
        // A parent mask tracks which vertical lines to draw.
        var pmask = std.AutoHashMap(u32, bool).init(self.allocator);
        defer pmask.deinit();
        // Start the recursive walk from the root process
        try self.walk(writer, "a", 0, &pmask, true);
    }
};
