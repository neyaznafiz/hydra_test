//! # Environment Paths Module

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const builtin = @import("builtin");

const Cfp = @import("cfp").Cfp;


const Str = []const u8;

/// # Returns Executable Directory Path (POSIX only)
/// **WARNING:** Return value must be freed by the caller
pub fn exeDir(heap: Allocator) !Str {
    return fs.selfExeDirPathAlloc(heap) catch unreachable;
}

const ExecMode = enum { Dev, Release };

/// # Detects App Execution Mode
fn execMode(heap: Allocator) !ExecMode {
    const exe_dir = try exeDir(heap);
    defer heap.free(exe_dir);

    const out = try resolve(heap, &.{"zig-out", "bin"});
    defer heap.free(out);

    const zig_out = mem.count(u8, exe_dir, out);
    return if (zig_out == 1) .Dev else .Release;
}

/// # Resolves Path from Path Fragments
/// - Evaluates any given relative path against the parent directory path
pub fn resolve(heap: Allocator, path: []const Str) !Str {
    return try fs.path.resolve(heap, path);
}

/// # Returns Projects Child Directory or File Path (Absolute Path)
/// - Resolves to the project directory as parent on development stage
/// - Resolves to `Resources` directory as parent on production bundle
///
/// **WARNING:** Return value must be freed by the caller
pub fn appDir(heap: Allocator, child: Str) !Str {
    const exe_dir = try exeDir(heap);
    defer heap.free(exe_dir);

    const dyn_path = blk: switch (try execMode(heap)) {
        .Dev => break :blk "../../", .Release => break :blk "./"
    };

    return try resolve(heap, &.{exe_dir, dyn_path, child});

    // Toggle this for quick testing
    // const uri = try resolve(heap, &.{exe_dir, dyn_path, child});
    // std.debug.print("AppDir: {s}\n", .{uri});
    // return uri;
}

/// # Config File Environment
pub const Env = enum { Dev, Release };

/// # Returns Configuration Options
/// This is a chicken and egg situation because we are trying to load
/// app `.conf` itself, therefore the following brute force approach.
///
/// **WARNING** Return value must be freed by the caller
pub fn appConfPath(heap: Allocator, file: Str) !Cfp.Option {
    var env = @intFromEnum(Env.Dev);
    const path = try appDir(heap, file);

    if (try execMode(heap) == .Release) env = @intFromEnum(Env.Release);

    return Cfp.Option {.env = env, .abs_path = path };
}
