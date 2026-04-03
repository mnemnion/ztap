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
const options = @import("options");
const timed = options.timed;

pub const ZTapTodo = error.ZTapTodo;
const SkipZigTest = error.SkipZigTest;

threadlocal var current_test: ?[]const u8 = null;

/// ZTAP test producer.  Call with `ztap_test(builtin)` in the main
/// function of a test executable, followed by `std.process.exit(0)`.
/// Set `pub fn panic = ztap.ztap_panic` for TAP-compatible bailout
/// behavior.
pub fn ztap_test(builtin: anytype) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;
    // Version string.
    _ = stdout.writeAll("\nTAP version 14\n") catch 0;
    // Make sure we have tests to run.
    const builtin_info = @typeInfo(builtin);
    switch (builtin_info) {
        .@"struct" => {
            if (!@hasDecl(builtin, "test_functions")) {
                // Empty plan.
                _ = stdout.writeAll("1..0\n") catch 0;
                return;
            }
        },
        else => @panic("invalid builtin provided"),
    }
    // Plan:
    stdout.print("1..{d}\n", .{builtin.test_functions.len}) catch {};
    var time = std.time.Timer.start() catch unreachable; // Docs say failures are "hostile"
    for (builtin.test_functions, 1..) |t, i| {
        current_test = t.name;
        std.testing.allocator_instance = .{};
        if (timed) time.reset();
        const result = t.func();
        if (timed) {
            const ns = time.lap();
            stdout.print("# {}: ", .{i}) catch {};
            fmtDuration(ns, stdout) catch {};
            stdout.writeByte('\n') catch {};
        }
        if (std.testing.allocator_instance.deinit() == .leak) {
            stdout.print("not ok {d} - {s}: memory leak\n", .{ i, t.name }) catch {};
            continue;
        }
        if (result) |_| {
            stdout.print("ok {d} - ", .{i}) catch {};
            esc_print(stdout, t.name);
            stdout.writeByte('\n') catch {};
        } else |err| switch (err) {
            SkipZigTest => {
                stdout.print("not ok {d} - ", .{i}) catch {};
                esc_print(stdout, t.name);
                stdout.writeAll(" # Skip\n") catch {};
            },
            ZTapTodo => {
                stdout.print("not ok {d} - ", .{i}) catch {};
                esc_print(stdout, t.name);
                stdout.writeAll(" # Todo\n") catch {};
            },
            else => {
                stdout.print("not ok {d} - ", .{i}) catch {};
                esc_print(stdout, t.name);
                // Error names aren't going to have escapables in them.
                stdout.print(": {any}\n", .{err}) catch {};
            },
        }
        stdout.flush() catch {};
    }
    current_test = null;
    stdout.flush() catch {};
}

fn esc_print(stdout: anytype, msg: []const u8) void {
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

/// Format a nice duration
fn fmtDuration(ns: u64, w: anytype) !void {
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
