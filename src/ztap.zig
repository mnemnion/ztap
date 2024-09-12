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

pub const ZTapTodo = error.ZTapTodo;
const SkipZigTest = error.SkipZigTest;

var current_test: ?[]const u8 = null;

/// ZTAP test producer.  Call with `ztap_test(builtin)` in the main
/// function of a test executable, followed by `std.process.exit(0)`.
/// Set `pub fn panic = ztap.ztap_panic` for TAP-compatible bailout
/// behavior.
pub fn ztap_test(builtin: anytype) void {
    const stdout = std.io.getStdOut().writer();
    // Version string.
    _ = stdout.writeAll("\nTAP version 14\n") catch 0;
    // Make sure we have tests to run.
    const builtin_info = @typeInfo(builtin);
    switch (builtin_info) {
        .Struct => {
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
    for (builtin.test_functions, 1..) |t, i| {
        current_test = t.name;
        std.testing.allocator_instance = .{};
        const result = t.func();
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
    }
    current_test = null;
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

/// Panic handler.  Provides Bail out! directive before calling
/// the default panic handler.
pub fn ztap_panic(
    message: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    const stdout = std.io.getStdOut().writer();
    std.debug.print("panic! at the ztap\n", .{});
    const current = if (current_test != null) current_test.? else "pre/post";
    stdout.print("# panic in {s}: {s}\n", .{ current, message }) catch {};
    _ = stdout.writeAll("Bail out!\n") catch 0;
    return std.builtin.default_panic(message, error_return_trace, ret_addr);
}
