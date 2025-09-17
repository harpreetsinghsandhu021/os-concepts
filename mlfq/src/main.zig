//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Represents all the state for a single job in the system.
// This is our version of a Process Control Block (PCB).
pub const Job = struct {
    id: u32,
    start_time: u32,
    run_time: u32,
    time_left: u32,

    // MLFQ-specific state
    curr_pri: u32,
    ticks_left: u32, // Time left in current quantum
    allot_left: u32, // Allotment slices left at this level

    // I/O state
    io_freq: u32,
    doing_io: bool,

    // Statistics
    first_run_time: i32 = -1,
    end_time: u32 = 0,
};

// An event that happens at a specific time, like an I/O finishing.
pub const TimedEvent = struct {
    job_id: u32,
    event_type: []const u8,
};

// The main struct that owns and manages the entire MLFQ simulation.
pub const Scheduler = struct {
    allocator: Allocator,

    // Maps a job_id to its full Job struct.
    jobs: std.AutoHashMap(u32, Job),

    // Maps a queue priority level to a list of job_ids.
    queues: std.AutoHashMap(u32, std.ArrayList(u32)),

    // Maps a time to a list of events that complete at that time.
    events: std.AutoHashMap(u32, std.ArrayList(TimedEvent)),

    // --- Configuration ---
    num_queues: u32,
    quantum: std.AutoHashMap(u32, u32), // Per-queue quantum
    allotment: std.AutoHashMap(u32, u32), // Per-queue allotment
    boost_period: u32,
    io_time: u32,

    pub fn init(allocator: Allocator, num_queues: u32, quantum: u32, allotment: u32, boost_period: u32, io_time: u32) !Scheduler {
        var self = Scheduler{
            .allocator = allocator,
            .jobs = std.AutoHashMap(u32, Job).init(allocator),
            .queues = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator),
            .events = std.AutoHashMap(u32, std.ArrayList(TimedEvent)).init(allocator),
            .num_queues = num_queues,
            .quantum = std.AutoHashMap(u32, u32).init(allocator),
            .allotment = std.AutoHashMap(u32, u32).init(allocator),
            .boost_period = boost_period,
            .io_time = io_time,
        };

        // Initialize each queue with an empty list of jobs
        // Also, populate the quantum/allotment rules for each queue level
        for (0..num_queues) |i| {
            try self.queues.put(@as(u32, @intCast(i)), std.ArrayList(u32).init(allocator));
            try self.quantum.put(@as(u32, @intCast(i)), quantum);
            try self.allotment.put(@as(u32, @intCast(i)), allotment);
        }

        return self;
    }

    pub fn deinit(self: *Scheduler) void {
        var queue_it = self.queues.valueIterator();
        while (queue_it.next()) |queue_list| {
            queue_list.deinit();
        }

        var event_it = self.events.valueIterator();
        while (event_it.next()) |event_list| {
            event_list.deinit();
        }

        self.jobs.deinit();
        self.queues.deinit();
        self.events.deinit();
        self.quantum.deinit();
        self.allotment.deinit();
    }

    pub fn loadJob(self: *Scheduler, id: u32, start_time: u32, run_time: u32, io_freq: u32) !void {
        const hi_queue = self.num_queues - 1;
        const new_job = Job{
            .id = id,
            .start_time = start_time,
            .run_time = run_time,
            .time_left = run_time,
            .curr_pri = hi_queue,
            .ticks_left = self.quantum.get(hi_queue).?,
            .allot_left = self.allotment.get(hi_queue).?,
            .io_freq = io_freq,
            .doing_io = false,
        };

        // Add the job to the master list of all jobs.
        try self.jobs.put(id, new_job);

        // Add a "JOB BEGINS" event to the event queue for the job's start time.
        const event_list_entry = try self.events.getOrPut(start_time);

        // If the entry was just created, its value (the ArrayList) is uninitialized.
        // We can check for this and initialize it on the spot.
        if (!event_list_entry.found_existing) {
            event_list_entry.value_ptr.* = std.ArrayList(TimedEvent).init(self.allocator);
        }

        // Now, we are guaranteed to have a valid ArrayList. Append the event.
        try event_list_entry.value_ptr.append(TimedEvent{ .job_id = id, .event_type = "JOB BEGINS" });
    }

    pub fn run(self: *Scheduler) !void {
        var current_time: u32 = 0;
        var finished_jobs: u32 = 0;
        const num_jobs = self.jobs.count();
        const writer = std.io.getStdOut().writer();

        while (finished_jobs < num_jobs) {
            // 1. Check if it's time for priority boost.
            try self.handlePriorityBoost(writer, current_time);

            // 2. Handle events for the current time (I/O done, jobs starting).
            try self.handleEvents(writer, current_time);

            // 3. Find the highest-priority job to run.
            const job_id = self.findNextJob();

            if (job_id) |id| {
                // 4. If a job is found, run it for one tick.
                try self.runJobForOneTick(writer, id, current_time);

                // 5. Check if the job's state changed (finished, did I/O, etc.).
                const did_finish = try self.handleStateChange(writer, id, current_time);
                if (did_finish) {
                    finished_jobs += 1;
                }
            } else {
                try writer.print("[ time {d} ] IDLE\n", .{current_time});
            }

            current_time += 1;
        }
    }

    // Finds the highest-priority, non-empty queue and returns the ID of the job at the front of that queue.
    fn findNextJob(self: *Scheduler) ?u32 {
        var q = self.num_queues - 1;
        while (q > 0) : (q -= 1) {
            if (self.queues.get(q).?.items.len > 0) {
                return self.queues.get(q).?.items[0];
            }
        }

        if (self.queues.get(0).?.items.len > 0) {
            return self.queues.get(0).?.items[0];
        }

        return null;
    }

    // Checks the event map for the current time and processes any events, like moving newly
    // arrived or I/O-finished jobs into a ready queue.
    fn handleEvents(self: *Scheduler, writer: anytype, current_time: u32) !void {
        if (self.events.get(current_time)) |event_list| {
            for (event_list.items) |event| {
                const job = self.jobs.getPtr(event.job_id).?;
                job.doing_io = false;

                try writer.print("[ time {d} ] {s} by JOB {d}\n", .{ current_time, event.event_type, event.job_id });
                // Add job to the back of its current priority queue.
                try self.queues.getPtr(job.curr_pri).?.append(job.id);
            }

            // This time's events are processed, so we can remove them.
            _ = self.events.remove(current_time);
        }
    }

    // Implements the priority boost, moving all jobs to the highest queue.
    fn handlePriorityBoost(self: *Scheduler, writer: anytype, current_time: u32) !void {
        if (self.boost_period > 0 and current_time > 0 and current_time % self.boost_period == 0) {
            try writer.print("[ time {d} ] BOOST ( every {d} )\n", .{ current_time, self.boost_period });
            const hi_queue = self.num_queues - 1;

            // Move all jobs from lower queues to the highest queues.
            for (0..hi_queue) |q_index| {
                var lower_q = self.queues.getPtr(@intCast(q_index)).?;
                var hi_q = self.queues.getPtr(hi_queue).?;
                try hi_q.appendSlice(lower_q.items);
                lower_q.clearRetainingCapacity();
            }

            // Reset the priority and allotment for all active jobs.
            var job_it = self.jobs.valueIterator();
            while (job_it.next()) |job| {
                if (job.time_left > 0) {
                    job.curr_pri = hi_queue;
                    job.ticks_left = self.quantum.get(hi_queue).?;
                    job.allot_left = self.allotment.get(hi_queue).?;
                }
            }
        }
    }

    // Simulates a job running for one tick, updating its timers.
    fn runJobForOneTick(self: *Scheduler, writer: anytype, id: u32, current_time: u32) !void {
        const job = self.jobs.getPtr(id).?;
        job.time_left -= 1;
        job.ticks_left -= 1;

        // Record the first time the job runs for statistics.
        if (job.first_run_time == -1) {
            job.first_run_time = @intCast(current_time);
        }

        try writer.print("[ time {d} ] Run JOB {d} at PRIORITY {d} [ TICKS {d} ALLOT {d} TIME {d} (of {d}) ]\n", .{ current_time, id, job.curr_pri, job.ticks_left, job.allot_left, job.time_left, job.run_time });
    }

    // After a job runs, this functions checks its state and applies MLFQ rules.
    // Returns "true" if the job finished.
    fn handleStateChange(self: *Scheduler, writer: anytype, id: u32, current_time: u32) !bool {
        var job = self.jobs.getPtr(id).?;
        var job_finished = false;
        var issued_io = false;

        // Rule 1: CHECK FOR JOB COMPLETION. This is the highest priority event.
        if (job.time_left == 0) {
            try writer.print("[ time {d} ] FINISHED JOB {d}\n", .{ current_time + 1, id });
            job_finished = true;
            job.end_time = current_time + 1;
            // Remove from the front of its current queue.
            _ = self.queues.getPtr(job.curr_pri).?.orderedRemove(0);

            return job_finished;
        }

        // Rule 2: CHECK FOR I/O. A job yielding for I/O is the next priority.
        if (job.io_freq > 0 and (job.run_time - job.time_left) % job.io_freq == 0) {
            issued_io = true;
            // Remove from its current queue to go wait for I/O.
            _ = self.queues.getPtr(job.curr_pri).?.orderedRemove(0);
            job.doing_io = true;

            // Schedule the IO_DONE event to happen in the future.
            const future_time = current_time + 1 + self.io_time;
            const event_list_entry = try self.events.getOrPut(future_time);

            if (!event_list_entry.found_existing) {
                event_list_entry.value_ptr.* = std.ArrayList(TimedEvent).init(self.allocator);
            }

            try event_list_entry.value_ptr.append(TimedEvent{ .job_id = id, .event_type = "IO_DONE" });
        }

        // Rule 3: CHECK FOR QUANTUM/ALLOTMENT END. This happens if the job did'nt finish or do I/O.
        if (job.ticks_left == 0) {
            // If the job didn't just issue an I/O, it must be removed from the front of the queue.
            if (!issued_io) {
                _ = self.queues.getPtr(job.curr_pri).?.orderedRemove(0);
            }

            // Decrement allotment for this priority level.
            job.allot_left -= 1;

            if (job.allot_left == 0) {
                // Allotment used up: demote to a lower-priority queue (if possible)
                if (job.curr_pri > 0) {
                    job.curr_pri -= 1;
                }

                // Add to the back of the new queue if it's not doing I/O.
                if (!issued_io) {
                    try self.queues.getPtr(job.curr_pri).?.append(id);
                }
            } else {
                // Allotment remains: move to the back of the same queue
                if (!issued_io) {
                    try self.queues.getPtr(job.curr_pri).?.append(id);
                }
            }

            // Reset ticks_left and allot_left for the new level.
            job.ticks_left = self.quantum.get(job.curr_pri).?;
            job.allot_left = self.allotment.get(job.curr_pri).?;
        }

        return job_finished;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var scheduler = try Scheduler.init(allocator, 3, 10, 1, 30, 5);
    defer scheduler.deinit();

    // Job 0: Interactive (short run, frequent I/O)
    try scheduler.loadJob(0, 0, 20, 5);
    // Job 1: CPU-Bound (long run, no I/O)
    try scheduler.loadJob(1, 0, 100, 0);

    try scheduler.run();
}
