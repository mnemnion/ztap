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
        std.testing.allocator_instance = .{};
        const result = t.func();
        if (std.testing.allocator_instance.deinit() == .leak) {
            stdout.print("not ok {d} - {s}: memory leak\n", .{ i, t.name }) catch {};
            continue;
        }
        if (result) |_| {
            stdout.print("ok {d} - {s}\n", .{ i, t.name }) catch {};
        } else |err| switch (err) {
            SkipZigTest => {
                stdout.print("not ok {d} - {s} # Skip\n", .{ i, t.name }) catch {};
            },
            ZTapTodo => {
                stdout.print("not ok {d} - {s} # Todo\n", .{ i, t.name }) catch {};
            },
            else => {
                stdout.print("not ok {d} - {s}: {any}\n", .{ i, t.name, err }) catch {};
            },
        }
    }
}