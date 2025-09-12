//! The File simulates how a simple CPU scheduler works. It creates one or more "processes", gives them a list of tasks (either
//! using the CPU or waiting for I/O), and then simulates how a scheduler would decide which process to run at each tick of a clock.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Defines when the scheduler should switch to another process
pub const SwitchBehavior = enum {
    onIo,
    onEnd,
};

// Defines what happens when an I/O operation completes
pub const IoDoneBehavior = enum {
    runLater,
    runImmediate,
};

// Represents the possible states of a process
pub const State = enum {
    running,
    ready,
    done,
    blocked,
};

// Represents the types of instructions a process can execute
pub const Instruction = enum {
    cpu,
    io,
    io_done, // A special instruction to handle I/O completion
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // --- Configuration ---
    const switch_behavior = SwitchBehavior.onEnd;
    const io_done_behavior = IoDoneBehavior.runLater;
    const io_length = 5;

    // --- Create and Initialize Scheduler ---
    var scheduler = Scheduler.init(allocator, switch_behavior, io_done_behavior, io_length);
    defer scheduler.deinit();

    // --- Load Processes ---
    try scheduler.loadProgram("c1,i,c1");
    try scheduler.loadProgram("c1,i,c1");

    try scheduler.run();
}

// Represents a single process in the system
pub const Process = struct {
    id: u32,
    state: State,
    code: std.ArrayList(Instruction), // The list of instructions
    io_finish_times: std.ArrayList(u32), // Tracks when its I/O will be done
    pc: u32, // Program Counter: tracks which instruction to run next

    // This method creates a new process.
    pub fn init(allocator: Allocator, id: u32) Process {
        return Process{
            .id = id,
            .pc = 0,
            .state = State.ready,
            .code = std.ArrayList(Instruction).init(allocator),
            .io_finish_times = std.ArrayList(u32).init(allocator),
        };
    }

    // This method releases the memory used by the process's instruction list.
    // This must be called when the process is no longer needed.
    pub fn deinit(self: *Process) void {
        self.code.deinit();
        self.io_finish_times.deinit();
    }
};

// Contains all the logic for creating, managing and running the processes. Think of it as the "Operating System" in our simulation.
pub const Scheduler = struct {
    allocator: Allocator,
    processes: std.ArrayList(Process),

    // --- Configuration ---
    switch_behavior: SwitchBehavior,
    io_done_behavior: IoDoneBehavior,
    io_length: u32,

    // --- State ---
    current_proc_index: ?u32,

    pub fn init(allocator: Allocator, switch_behavior: SwitchBehavior, io_done_behavior: IoDoneBehavior, io_length: u32) Scheduler {
        return Scheduler{
            .allocator = allocator,
            .processes = std.ArrayList(Process).init(allocator),
            .switch_behavior = switch_behavior,
            .io_done_behavior = io_done_behavior,
            .io_length = io_length,
            .current_proc_index = null,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.processes.items) |*process| {
            process.deinit();
        }

        self.processes.deinit();
    }

    // Creates a new process, adds it to the list, and returns its ID.
    fn newProcess(self: *Scheduler) !u32 {
        const proc_id: u32 = @intCast(self.processes.items.len);
        const proc = Process.init(self.allocator, proc_id);

        try self.processes.append(proc);

        return proc_id;
    }

    // This method loads a program from specific string format like "c7, i, c1, i".
    // This means: compute for 7 steps, do an I/O, compute for 1 step, do an I/O.
    pub fn loadProgram(self: *Scheduler, program_str: []const u8) !void {
        const proc_id = try self.newProcess();

        // Split the program string by the comma to get individual instructions.
        var iterator = std.mem.splitAny(u8, program_str, ",");

        while (iterator.next()) |instruction_str| {
            if (instruction_str.len == 0) continue;
            const opcode = instruction_str[0]; // The first character is the operation code ('c' or 'i').
            const code_list = &self.processes.items[proc_id].code;

            switch (opcode) {
                'c' => { // 'c' means compute
                    // The rest of the string is the number of CPU steps.
                    const num = try std.fmt.parseInt(u32, instruction_str[1..], 10);
                    // Add that many 'cpu' instructions to the process's code list.
                    for (0..num) |_| {
                        try code_list.append(Instruction.cpu);
                    }
                },
                'i' => { // 'i' means I/O
                    // Add one 'io' instruction to start the I/O.
                    try code_list.append(Instruction.io);

                    // After an I/O operation, the CPU needs to do a tiny bit of work to process the result.
                    // This 'io_done' instruction represents that work.
                    try code_list.append(Instruction.io_done);
                },
                else => {
                    std.log.err("bad opcode '{c}' in program '{s}'", .{ opcode, program_str });
                    return error.BadOpcode;
                },
            }
        }
    }

    // Changes the state of a given process.
    fn setState(self: *Scheduler, proc_index: u32, new_state: State) void {
        const proc = &self.processes.items[proc_index];
        proc.state = new_state;
    }

    // The core scheduling algorithmn. Finds the next READY process and sets it as the current running process.
    pub fn scheduleNextProcess(self: *Scheduler) void {
        // First, if there's a process currently running, set it back to READY.
        // This is what happens when a time slice ends or an I/O is issued.

        // The `if (let ...)` syntax is a safe way to unwrap an optional.
        // It only runs the block if `current_proc_index` is not null.
        // if (self.current_proc_index) |index| {
        //     // We only remove a RUNNING process to READY. If it's BLOCKED or DONE, it should'nt be touched by the
        //     // regular scheduling logic.
        //     if (self.processes.items[index].state == .running) {
        //         self.setState(index, .ready);
        //     }
        // }

        // Determine the starting point for our search. If a process was running, start with the next one. Otherwise
        // start from the beginning.
        const start_index = if (self.current_proc_index) |i| i + 1 else 0;
        const num_processes = self.processes.items.len;

        // This loop implements the round-robin search. It will check at most `num_processes` times to avoid an infinite loop.
        for (0..num_processes) |i| {
            // The classic modulo(%) trick to make our scan wrap around the list in a circle.
            // This is what makes it "round-robin".
            const check_index = @as(u32, @intCast((start_index + i) % num_processes));
            const process = &self.processes.items[check_index];

            if (process.state == .ready) {
                // Found one. Make it the new running process and we're done
                self.setState(check_index, .running);
                self.current_proc_index = check_index;
                return;
            }
        }

        // If the loop finishes without finding any READY processes,
        // it means nothing can be run right now. We set the current process to null to signify that the CPU is idle.
        self.current_proc_index = null;
    }

    // A special version of the scheduler for the IO_RUN_IMMEDIATE case.
    // It directly switches to a specific process.
    pub fn scheduleImmediate(self: *Scheduler, proc_index: u32) void {
        // If a different process was running, make it READY first.
        if (self.current_proc_index) |current_index| {
            if (current_index != proc_index and self.processes.items[current_index].state == .running) {
                self.setState(current_index, .ready);
            }
        }

        // Make the specified process the current one and set its state to running.
        self.current_proc_index = proc_index;
        self.setState(proc_index, .running);
    }

    // Helper to count the number of processes that are not DONE.
    fn getNumActiveProcesses(self: *const Scheduler) u32 {
        var count: u32 = 0;
        for (self.processes.items) |process| {
            if (process.state != .done) {
                count += 1;
            }
        }

        return count;
    }

    // Helper to count I/O operations that will complete in the future.
    fn getIosInFlight(self: *const Scheduler, current_time: u32) u32 {
        var count: u32 = 0;
        for (self.processes.items) |process| {
            for (process.io_finish_times.items) |finish_time| {
                if (finish_time > current_time) {
                    count += 1;
                }
            }
        }
        return count;
    }

    // Helper to count runnable processes (Ready or Running)
    fn getNumRunnableProcesses(self: *const Scheduler) u32 {
        var count: u32 = 0;
        for (self.processes.items) |process| {
            if (process.state == .ready or process.state == .running) {
                count += 1;
            }
        }

        return count;
    }

    // The main simulation loop.
    pub fn run(self: *Scheduler) !void {
        var clock_tick: u32 = 0;
        var cpu_busy: u32 = 0;
        var io_busy: u32 = 0;
        const writer = std.io.getStdOut().writer();

        if (self.processes.items.len == 0) return;

        // --- Initial State and Headers ---
        self.setState(0, .running);
        self.current_proc_index = 0;

        try writer.print("Time", .{});
        for (self.processes.items) |process| {
            try writer.print("        PID:{d:2}", .{process.id});
        }
        try writer.print("           CPU", .{});
        try writer.print("           IOs\n", .{});

        // --- Main Simulation Loop ---
        while (self.getNumActiveProcesses() > 0) {
            clock_tick += 1;

            // -- Step 1: Check for I/O completions --
            var io_just_finished = false;
            for (self.processes.items, 0..) |*proc, i| {
                var j: usize = 0;
                while (j < proc.io_finish_times.items.len) {
                    if (proc.io_finish_times.items[j] == clock_tick) {
                        io_just_finished = true;
                        _ = proc.io_finish_times.swapRemove(j);
                        self.setState(@intCast(i), .ready);

                        if (self.io_done_behavior == .runImmediate) {
                            self.scheduleImmediate(@intCast(i));
                        } else { // IO_RUN_LATER
                            const proc_index = @as(u32, @intCast(i));
                            if (self.switch_behavior == .onEnd and self.getNumRunnableProcesses() > 1) {
                                self.scheduleImmediate(proc_index);
                            }
                            if (self.getNumRunnableProcesses() == 1) {
                                self.scheduleImmediate(proc_index);
                            }
                        }
                    } else {
                        j += 1;
                    }
                }
            }

            // Ensure the current process is runnable before executing
            // If there is a "current" process but it isn't in the RUNNING state
            // (e.g., it's BLOCKED), call the scheduler to find a new one.
            if (self.current_proc_index) |current_index| {
                if (self.processes.items[current_index].state != .running) {
                    self.scheduleNextProcess();
                }
            }

            // -- Step 2: Execute Current Instruction --
            var instruction_executed: ?Instruction = null;
            if (self.current_proc_index) |current_index| {
                const proc = &self.processes.items[current_index];
                if (proc.state == .running and proc.pc < proc.code.items.len) {
                    instruction_executed = proc.code.items[proc.pc];
                    self.processes.items[current_index].pc += 1;
                    cpu_busy += 1;
                }
            }

            // -- Step 3: Print System State for this Tick (Corrected) --
            if (io_just_finished) {
                try writer.print("{d:3}*", .{clock_tick});
            } else {
                try writer.print("{d:3} ", .{clock_tick});
            }

            // This buffer will be used to format the text for each column before printing.
            var col_buf: [20]u8 = undefined;

            for (self.processes.items, 0..) |*proc, i| {
                const text_to_print = if (self.current_proc_index == @as(u32, @intCast(i)) and instruction_executed != null)
                    // Format "RUN:instruction" into the buffer
                    try std.fmt.bufPrint(&col_buf, "RUN:{s}", .{@tagName(instruction_executed.?)})
                else
                    // Format just the state into the buffer
                    try std.fmt.bufPrint(&col_buf, "{s}", .{@tagName(proc.state)});

                // Now print the formatted text, right-aligned within a 14-character column.
                try writer.print("{s:>14}", .{text_to_print});
            }

            if (instruction_executed != null) {
                try writer.print("{s:>14}", .{"1"});
            } else {
                try writer.print("{s:>14}", .{" "});
            }

            const ios_in_flight = self.getIosInFlight(clock_tick);
            if (ios_in_flight > 0) {
                io_busy += 1;
                try writer.print("{d:>14}\n", .{ios_in_flight});
            } else {
                try writer.print("{s:>14}\n", .{" "});
            }

            // -- Step 4 & 5: Handle Effects and Check if Done (Corrected) --
            if (self.current_proc_index) |current_index| {
                // Handle effects of the instruction that just ran
                if (instruction_executed) |instr| {
                    if (instr == .io) {
                        self.setState(current_index, .blocked);
                        const finish_time = clock_tick + self.io_length + 1;
                        try self.processes.items[current_index].io_finish_times.append(finish_time);
                        // Schedule immediately, just like the Python script.
                        if (self.switch_behavior == .onIo) {
                            self.scheduleNextProcess();
                        }
                    }
                }

                // Check if the current process is now finished
                const proc = &self.processes.items[current_index];
                if (proc.pc >= proc.code.items.len and proc.state != .done) {
                    self.setState(current_index, .done);
                    // Schedule immediately, just like the Python script.
                    self.scheduleNextProcess();
                }
            }
        }

        // --- Final Statistics ---
        const total_ticks = clock_tick;
        const cpu_perc: f64 = if (total_ticks == 0) 0 else @as(f64, @floatFromInt(cpu_busy)) * 100.0 / @as(f64, @floatFromInt(total_ticks));
        const io_perc: f64 = if (total_ticks == 0) 0 else @as(f64, @floatFromInt(io_busy)) * 100.0 / @as(f64, @floatFromInt(total_ticks));

        try writer.print("\nStats: Total Time {d}\n", .{total_ticks});
        try writer.print("Stats: CPU Busy  {d} ({d:.2}%)\n", .{ cpu_busy, cpu_perc });
        try writer.print("Stats: IO Busy   {d} ({d:.2}%)\n", .{ io_busy, io_perc });
    }
};
