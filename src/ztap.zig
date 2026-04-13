//! ZTAP: A TAP test runner for Zig
//!
//! The Test Anything Protocol is a simple output format for test runs.
//! Originating in Perl, it is widely supported as a cross-system way
//! to report test results.
//!
//! ZTAP is a test runner for the Zig build system, which outputs in
//! TAP 14 format, the latest standard.  The output is also TAP 13
//! compliant, except for the version string, so it should function
//! anywhere TAP is spoken.

const std = @import("std");
const zig_builtin = @import("builtin");
const options = @import("options");
const threaded = options.threaded;
const timed = options.timed;

pub const ZTapTodo = error.ZTapTodo;
const SkipZigTest = error.SkipZigTest;
const invalid_ticket = std.math.maxInt(usize);
const threaded_leak_name = "ztap_runner.threaded tests don't leak memory";

threadlocal var current_test: ?[]const u8 = null;

/// ZTAP test producer.  Call with `ztap_test(builtin)` in the main
/// function of a test executable, followed by `std.process.exit(0)`.
/// Set `pub fn panic = ztap.ztap_panic` for TAP-compatible bailout
/// behavior.
pub fn ztap_test(builtin: anytype) void {
    @disableInstrumentation();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;

    // Version string.
    stdout.writeAll("\nTAP version 14\n") catch {};

    // Make sure we have tests to run.
    const builtin_info = @typeInfo(builtin);
    switch (builtin_info) {
        .@"struct" => {
            if (!@hasDecl(builtin, "test_functions")) {
                // Empty plan.
                stdout.writeAll("1..0\n") catch {};
                return;
            }
        },
        else => @panic("invalid builtin provided"),
    }

    // Plan:
    const threaded_run = shouldRunThreaded(builtin.test_functions.len);
    const total_tests = builtin.test_functions.len + @intFromBool(threaded_run);
    stdout.print("1..{d}\n", .{total_tests}) catch {};
    if (timed) {
        stdout.writeAll("pragma +timed\n") catch {};
    }
    stdout.flush() catch {};

    if (threaded_run) {
        runThreaded(builtin, stdout);
    } else {
        runSequential(builtin, stdout);
    }

    current_test = null;
    stdout.flush() catch {};
}

fn runSequential(builtin: anytype, stdout: anytype) void {
    @disableInstrumentation();
    var time: std.time.Timer = undefined;
    if (timed) {
        time = std.time.Timer.start() catch unreachable;
    }

    for (builtin.test_functions, 1..) |t, i| {
        current_test = t.name;
        std.testing.allocator_instance = .{};
        if (timed) time.reset();

        const result = t.func();
        const timing_ns: ?u64 = if (timed) time.lap() else null;
        const leaked = std.testing.allocator_instance.deinit() == .leak;

        writeTestChunk(stdout, i, t.name, result, timing_ns, leaked);
        stdout.flush() catch {};
    }
}

fn runThreaded(builtin: anytype, stdout: anytype) void {
    @disableInstrumentation();
    const tests = builtin.test_functions;
    const worker_count = @min(tests.len, std.Thread.getCpuCount() catch 1);

    const allocator = std.heap.page_allocator;
    const TestFn = @TypeOf(tests[0]);

    const Worker = struct {
        tests: []const TestFn,
        start_index: usize,
        slot: *ThreadedSlot,
        coord: *ThreadedCoordinator,
        allocator: std.mem.Allocator,

        fn run(worker: *@This()) void {
            var time: std.time.Timer = undefined;
            if (timed) {
                time = std.time.Timer.start() catch unreachable;
            }

            for (worker.tests, worker.start_index + 1..) |t, i| {
                current_test = t.name;
                if (timed) time.reset();

                const result = t.func();
                const timing_ns: ?u64 = if (timed) time.lap() else null;

                worker.slot.buffer.clearRetainingCapacity();
                var writer = worker.slot.buffer.writer(worker.allocator);
                writeTestChunk(&writer, i, t.name, result, timing_ns, false);
                worker.coord.publish(worker.slot);
            }

            current_test = null;
        }
    };

    const slots = allocator.alloc(ThreadedSlot, worker_count) catch unreachable;
    defer allocator.free(slots);
    for (slots) |*slot| {
        slot.* = ThreadedSlot.init(allocator);
    }
    defer for (slots) |*slot| {
        slot.deinit(allocator);
    };

    const workers = allocator.alloc(Worker, worker_count) catch unreachable;
    defer allocator.free(workers);

    const threads = allocator.alloc(std.Thread, worker_count) catch unreachable;
    defer allocator.free(threads);

    std.testing.allocator_instance = .{};

    var coord = ThreadedCoordinator{
        .slots = slots,
    };

    for (workers, threads, 0..) |*worker, *thread, idx| {
        const range = partitionRange(idx, worker_count, tests.len);
        worker.* = .{
            .tests = tests[range.start..range.end],
            .start_index = range.start,
            .slot = &slots[idx],
            .coord = &coord,
            .allocator = allocator,
        };
        thread.* = std.Thread.spawn(.{
            .allocator = allocator,
        }, Worker.run, .{worker}) catch unreachable;
    }

    for (0..tests.len) |ticket| {
        const slot_index = coord.waitForTicket(ticket);
        const slot = &slots[slot_index];

        stdout.writeAll(slot.buffer.items) catch {};
        stdout.flush() catch {};
        coord.acknowledge(slot);
    }

    for (threads) |thread| {
        thread.join();
    }

    const leaked = std.testing.allocator_instance.deinit() == .leak;
    writeLeakCheckChunk(stdout, tests.len + 1, leaked);
    stdout.flush() catch {};
}
const TestRange = struct {
    start: usize,
    end: usize,
};

const ThreadedSlot = struct {
    buffer: std.ArrayList(u8),
    ready: bool = false,
    ticket: usize = invalid_ticket,
    written: std.Thread.Condition = .{},

    fn init(allocator: std.mem.Allocator) ThreadedSlot {
        _ = allocator;
        return .{
            .buffer = .empty,
        };
    }

    fn deinit(slot: *ThreadedSlot, allocator: std.mem.Allocator) void {
        slot.buffer.deinit(allocator);
    }
};

const ThreadedCoordinator = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.Thread.Condition = .{},
    next_ticket: usize = 0,
    slots: []ThreadedSlot,

    fn publish(coord: *ThreadedCoordinator, slot: *ThreadedSlot) void {
        @disableInstrumentation();
        coord.mutex.lock();
        defer coord.mutex.unlock();

        std.debug.assert(!slot.ready);
        slot.ticket = coord.next_ticket;
        coord.next_ticket += 1;
        slot.ready = true;

        coord.ready.signal();
        while (slot.ready) {
            slot.written.wait(&coord.mutex);
        }
    }

    fn waitForTicket(coord: *ThreadedCoordinator, ticket: usize) usize {
        @disableInstrumentation();
        coord.mutex.lock();
        defer coord.mutex.unlock();

        while (true) {
            for (coord.slots, 0..) |*slot, idx| {
                if (slot.ready and slot.ticket == ticket) {
                    return idx;
                }
            }

            coord.ready.wait(&coord.mutex);
        }
    }

    fn acknowledge(coord: *ThreadedCoordinator, slot: *ThreadedSlot) void {
        @disableInstrumentation();
        coord.mutex.lock();
        defer coord.mutex.unlock();

        std.debug.assert(slot.ready);
        slot.ready = false;
        slot.ticket = invalid_ticket;
        slot.written.signal();
    }
};

fn esc_print(stdout: anytype, msg: []const u8) void {
    @disableInstrumentation();
    var cursor: usize = 0;
    var idx: usize = 0;
    while (idx < msg.len) : (idx += 1) {
        switch (msg[idx]) {
            '\\', '#' => {
                stdout.writeAll(msg[cursor..idx]) catch {};
                stdout.writeByte('\\') catch {};
                cursor = idx;
            },
            else => {},
        }
    }
    stdout.writeAll(msg[cursor..idx]) catch {};
}

fn partitionRange(idx: usize, parts: usize, len: usize) TestRange {
    @disableInstrumentation();
    std.debug.assert(parts > 0);
    std.debug.assert(idx < parts);

    const base = len / parts;
    const extra = len % parts;
    const start = (idx * base) + @min(idx, extra);
    const end = start + base + @intFromBool(idx < extra);

    return .{
        .start = start,
        .end = end,
    };
}

fn shouldRunThreaded(test_count: usize) bool {
    if (!threaded or zig_builtin.single_threaded or test_count == 0) {
        return false;
    }

    return @min(test_count, std.Thread.getCpuCount() catch 1) > 1;
}

fn writeTestChunk(
    stdout: anytype,
    i: usize,
    name: []const u8,
    result: anytype,
    timing_ns: ?u64,
    leaked: bool,
) void {
    @disableInstrumentation();
    if (leaked) {
        stdout.print("not ok {d} - {s}: memory leak\n", .{ i, name }) catch {};
        return;
    }

    if (result) |_| {
        stdout.print("ok {d} - ", .{i}) catch {};
        esc_print(stdout, name);
        stdout.writeByte('\n') catch {};
    } else |err| switch (err) {
        SkipZigTest => {
            stdout.print("not ok {d} - ", .{i}) catch {};
            esc_print(stdout, name);
            stdout.writeAll(" # Skip\n") catch {};
        },
        ZTapTodo => {
            stdout.print("not ok {d} - ", .{i}) catch {};
            esc_print(stdout, name);
            stdout.writeAll(" # Todo\n") catch {};
        },
        else => {
            stdout.print("not ok {d} - ", .{i}) catch {};
            esc_print(stdout, name);
            stdout.print(": {any}\n", .{err}) catch {};
        },
    }
    if (timing_ns) |ns| {
        stdout.print("---\n  time: ", .{}) catch {};
        fmtDuration(ns, stdout) catch {};
        stdout.print(" # {d}\n...\n", .{i}) catch {};
    }
}

fn writeLeakCheckChunk(stdout: anytype, i: usize, leaked: bool) void {
    @disableInstrumentation();
    if (leaked) {
        stdout.print("not ok {d} - {s}: memory leak\n", .{ i, threaded_leak_name }) catch {};
    } else {
        stdout.print("ok {d} - ", .{i}) catch {};
        esc_print(stdout, threaded_leak_name);
        stdout.writeByte('\n') catch {};
    }
}

/// Format a nice duration
fn fmtDuration(ns: u64, w: anytype) !void {
    @disableInstrumentation();
    const t = std.time;

    if (ns < t.ns_per_us) {
        return w.print("{}ns", .{ns});
    } else if (ns < t.ns_per_ms) {
        return fmtScaled(ns, t.ns_per_us, "µs", w);
    } else if (ns < t.ns_per_s) {
        return fmtScaled(ns, t.ns_per_ms, "ms", w);
    } else {
        return fmtScaled(ns, t.ns_per_s, "s", w);
    }
}

/// Scale-round approximates and drop decimal.
fn fmtScaled(ns: u64, unit: u64, suffix: []const u8, w: anytype) !void {
    @disableInstrumentation();
    // integer part
    const whole = ns / unit;

    // remainder for fractional
    const rem = ns % unit;

    // tenths = floor( (rem / unit) * 10 )
    // do it in integer space:
    const tenths = @as(u8, @intCast((rem * 10) / unit));

    if (tenths <= 1) {
        // snap down
        try w.print("{}{s}", .{ whole, suffix });
    } else if (tenths >= 9) {
        // snap up
        try w.print("{}{s}", .{ whole + 1, suffix });
    } else {
        try w.print("{}.{}{s}", .{ whole, tenths, suffix });
    }
}

/// Panic handler.  Provides Bail out! directive before calling
/// the default panic handler.
pub fn ztap_panic(
    message: []const u8,
    ret_addr: ?usize,
) noreturn {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;
    std.debug.print("panic! at the ztap\n", .{});
    const current = if (current_test != null) current_test.? else "pre/post";
    stdout.print("# panic in {s}: {s}\n", .{ current, message }) catch {};
    _ = stdout.writeAll("Bail out!\n") catch 0;
    std.debug.defaultPanic(message, ret_addr);
}

//| Tests

const expectEqual = std.testing.expectEqual;

test "partitionRange covers all items contiguously" {
    const ranges = [_]TestRange{
        partitionRange(0, 3, 8),
        partitionRange(1, 3, 8),
        partitionRange(2, 3, 8),
    };

    try expectEqual(@as(usize, 0), ranges[0].start);
    try expectEqual(@as(usize, 3), ranges[0].end);
    try expectEqual(ranges[0].end, ranges[1].start);
    try expectEqual(@as(usize, 6), ranges[1].end);
    try expectEqual(ranges[1].end, ranges[2].start);
    try expectEqual(@as(usize, 8), ranges[2].end);
}

test "partitionRange sizes differ by at most one" {
    var min_size: usize = std.math.maxInt(usize);
    var max_size: usize = 0;

    for (0..4) |idx| {
        const range = partitionRange(idx, 4, 10);
        const size = range.end - range.start;
        min_size = @min(min_size, size);
        max_size = @max(max_size, size);
    }

    try expectEqual(@as(usize, 1), max_size - min_size);
}

test "partitionRange preserves original numbering" {
    const range = partitionRange(1, 3, 7);

    try expectEqual(@as(usize, 3), range.start);
    try expectEqual(@as(usize, 5), range.end);
    try expectEqual(@as(usize, 4), range.start + 1);
    try expectEqual(@as(usize, 5), range.end);
}
