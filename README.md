# ZTAP

The [Test Anything Protocol](https://testanything.org/) is a simple,
venerable, and widely-used format for reporting the output of tests.

ZTAP is a Zig library for running and reporting tests in the TAP 14
format.

## Use

This can be used as the main unit testing step, or as a custom step.
Instructions will assume the latter, but are easily adapted for the
former case.

Add to `build.zig.zon` in the usual fashion:

```sh
zig fetch --save "http://github.com/mnemnion/ztap/etc"
```
You'll need a test runner a la `src/ztap-runner.zig`:

```zig
const std = @import("std");
const builtin = @import("builtin");
const ztap = @import("ztap");

pub fn main() !void {
    ztap.ztap_test(builtin);
    std.process.exit(0);
}
```
Do be sure to exit with `0`, since the protocol interprets non-zero as
a test failure.

Add something of this nature to `build.zig`:

```zig
    // ZTap test runner step.
    const ztap_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test-root-file.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = b.path("src/ztap-runner.zig"),
    });

    const run_ztap_tests = b.addRunArtifact(ztap_unit_tests);

    // To unilaterally run tests, add this:
    run_ztap_tests.has_side_effects = true;

    // Workaround for something which currently causes a bunch of
    // blank stderr lines.  ¯\_(ツ)_/¯
    _ = run_ztap_tests.captureStdErr();

    if (b.lazyDependency("ztap", .{
        .target = target,
        .optimize = optimize,
    })) |ztap_dep| {
        ztap_unit_tests.root_module.addImport("ztap", ztap_dep.module("ztap"));
    }

    const ztap_step = b.step("ztap", "Run tests with ZTAP");
    ztap_step.dependOn(&run_ztap_tests.step);
```
That should do the trick.  See the first link for an example of what to
expect in the way of output.

### Why Though?

Everything speaks TAP.  CI speaks TAP, distros speak TAP, your editor
speaks TAP.  If you find yourself wanting to integrate with some or all
of these things, ZTAP will TAP your Zig.

Also, if you print to stdout, ZTAP will not hang your unit tests.  That
doesn't make it a good idea, TAP harnesses ignore what they don't grok,
but it can't help things, and it can screw them up.

