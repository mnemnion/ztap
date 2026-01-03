# ZTAP

The [Test Anything Protocol](https://testanything.org/) is a simple,
venerable, and widely-used format for reporting the output of tests.

ZTAP is a Zig library for running and reporting tests in the TAP 14
format.

## Compatibility

ZTAP requires Zig 0.14.

## Use

This can be used as the main unit testing step, or as a custom step.
Instructions will assume the latter, but are easily adapted for the
former case.

Add to `build.zig.zon` in the usual fashion:

```sh
zig fetch --save "https://github.com/mnemnion/ztap/archive/refs/tags/v0.9.2.tar.gz"
```
You'll need a test runner.  A default one is included, and looks like this:

```zig
const std = @import("std");
const builtin = @import("builtin");
const ztap = @import("ztap");

// This gives TAP-compatible panic handling
pub const panic = std.debug.FullPanic(ztap.ztap_panic);

pub fn main() !void {
    ztap.ztap_test(builtin);
    std.process.exit(0);
}
```
Which you could customize, on the off chance that you need that.

Do be sure to exit with `0`, since the protocol interprets non-zero as
a test failure.

Next, set up your `build.zig`.  We'll assume you want to use the
default test runner, and make this a custom step.

```zig
    // If you want to filter tests, add this.  It works with the stock
    // unit test runner as well.
    const test_filters: []const []const u8 = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any of the specified filters",
    ) orelse &.{};

    const ztap_dep = b.dependency("ztap", .{
        .target = target,
        .optimize = optimize,
    });

    // ZTAP test runner step.
    const ztap_unit_tests = b.addTest(.{
        .name = "ztap-run",
        .root_module = your_module_to_test,
        .filters = test_filters,
        // With the provided test runner:
        .test_runner = .{ .path = ztap_dep.namedLazyPath("runner"), .mode = .simple},
        // Or you can use your own:
        // .test_runner = .{ .path = b.path("src/ztap_custom_runner.zig"), .mode = .simple },
    });
    ztap_unit_tests.root_module.addImport("ztap", ztap_dep.module("ztap"));

    // To put the runner in zig-out etc.
    b.installArtifact(ztap_unit_tests);

    const run_ztap_tests = b.addRunArtifact(ztap_unit_tests);

    // To always run tests, even if nothing changed, add this:
    // run_ztap_tests.has_side_effects = true;

    // TAP producers write to stdout.
    //
    // To suppress stderr chatter, you can uncomment this:

    // _ = run_ztap_tests.captureStdErr();

    // Just call this "test" to make ZTAP the main test runner.
    const ztap_step = b.step("ztap", "Run tests with ZTAP");
    ztap_step.dependOn(&run_ztap_tests.step);
    // Otherwise you can set up default tests as well, in the
    // expected manner.  It's nice to have options.
```
That should do the trick.  See the first link for an example of what to
expect in the way of output.

## Use Notes

ZTAP is simply an output format for Zig's test system, and no changes
should be necessary to use it as such.  If `error.SkipZigTest` is
returned, ZTAP will issue the `# Skip` directive.  Zig doesn't support
a TODO for tests (not that it should necessarily), but TAP does, so if
`error.ZTapTodo` is returned, ZTAP will issue `# Todo`.  Zig's test
runner will treat the latter as any other error.  In the event that Zig
adds a TODO error to the test system, ZTAP will support that also.

The `ztap_panic` function will add a comment to the TAP output naming
the test, and issue the `Bail out!` directive which is proper for a
fatal error.  It then calls the default panic handler, which does the
accustomed things using `stderr`.

## Roadmap

ZTAP does what it needs to.  There is no visible need for additional
functionality, the library is stable and in use.

The only contemplated change is in the event that Zig does add a TODO
type error to the test system.  In that event, ZTAP will support both,
with a deprecation notice for `error.ZTapTodo`, and the custom error
will be removed in 1.0.

Speaking of 1.0, an earlier version of the README suggested that ZTAP
would declare 1.0 under conditions which have in fact been achieved.
However, changes to the panic handling in Zig 0.14 required ZTAP to
make changes to its public interface.  In recognition of this, ZTAP
will not declare a 1.0 edition before Zig itself does.

However, the only breaking changes I will countenance are those needed
to keep up with changes in Zig.  Other than that, consider ZTAP to have
reached release status.

### Why Though?

Everything speaks TAP.  CI speaks TAP, distros speak TAP, your editor
speaks TAP.  If you find yourself wanting to integrate with some or all
of these things, ZTAP will TAP your Zig.

Also, if you print to `stdout`, ZTAP will not hang your unit tests.  That
doesn't make it a good idea, TAP harnesses ignore what they don't grok,
but it can't help things, and it can screw them up.  It does mean that
tests will complete in the event that `stdout` is printed to.
