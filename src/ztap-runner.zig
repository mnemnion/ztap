const std = @import("std");
const builtin = @import("builtin");
const ztap = @import("ztap");

// This gives TAP-compatible panic handling
pub const panic = std.debug.FullPanic(ztap.ztap_panic);

pub fn main() !void {
    ztap.ztap_test(builtin);
    std.process.exit(0);
}
