//! # Logging Manager (Singleton) - v1.0.0
//! - Provides a set of utilities for application level logging and debugging

const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const mem = std.mem;
const File = fs.File;
const linux = std.os.linux;
const ArrayList = std.ArrayList;
const SrcLoc = std.builtin.SourceLocation;

const Cfp = @import("cfp").Cfp;
const AsyncIo = @import("../main.zig").AsyncIo;

const utils = @import("./utils.zig");
const Hemloc = @import("./hemloc.zig");
const DateTime = @import("./datetime.zig");


const Error = error { InvalidLogLevel, FailedToOpenLogFile };

const DEBUG = 1 << 0;
const INFO = 1 << 1;
const WARN = 1 << 2;
const ERROR = 1 << 3;
const FATAL = 1 << 4;

const Str = []const u8;

const OutputType = enum { Console, File };

const LogData = struct { data: []const u8 };

const CtxData = struct { name: []const u8, value: []const u8 };

const SingletonObject = struct { output: OutputType, level: u8, fd: ?i32 };

var so = SingletonObject {
    .output = OutputType.Console,
    .level = DEBUG | INFO | WARN | ERROR | FATAL,
    .fd = null,
};

const Self = @This();

pub fn init() !void {
    const sop = Self.iso();
    if (Self.so.fd != null) @panic("Initialize Only Once Per Process!");

    const log_file = Cfp.getStr("preset.log_file") catch null;

    if (log_file) |file_path| {
        const heap = Hemloc.heap();
        const path = try heap.dupeZ(u8, file_path);
        defer heap.free(path);

        const res: isize = @bitCast(linux.openat(fs.cwd().fd, path,
            linux.O {.ACCMODE = .WRONLY, .CREAT = true, .APPEND = true},
            0o644 // Octal literal for setting file permission
        ));

        if (res <= 0) {
            utils.syscallError(@truncate(res), @src());
            return Error.FailedToOpenLogFile;
        }

        sop.fd = @truncate(res);
        sop.output = OutputType.File;
    }

    sop.level = 0;
    const levels = try Cfp.getList("preset.log_levels");

    for (levels) |level| {
        if (mem.eql(u8, level.string, "DEBUG")) sop.level |= DEBUG
        else if (mem.eql(u8, level.string, "INFO")) sop.level |= INFO
        else if (mem.eql(u8, level.string, "WARN")) sop.level |= WARN
        else if (mem.eql(u8, level.string, "ERROR")) sop.level |= ERROR
        else if (mem.eql(u8, level.string, "FATAL")) sop.level |= FATAL
        else return Error.InvalidLogLevel;
    }
}

pub fn deinit() void {
    const sop = Self.iso();
    if (sop.fd) |fd| {
        sop.output = OutputType.Console;
        std.debug.assert(linux.close(fd) == 0);
    }
}

/// # Returns Internal Static Object
pub fn iso() *SingletonObject { return &Self.so; }

pub fn debug(
    comptime msg: Str,
    args: anytype,
    ctx: ?[]CtxData,
    src: SrcLoc
) void {
    if (Self.iso().level & DEBUG == DEBUG) {
        const heap = Hemloc.heap();
        const data = fmt.allocPrint(heap, msg, args) catch {
            utils.oom(@src());
        };
        defer heap.free(data);

        const out = format("DEBUG", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, false) catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn info(
    comptime msg: Str,
    args: anytype,
    ctx: ?[]CtxData,
    src: SrcLoc
) void {
    if (Self.iso().level & INFO == INFO) {
        const heap = Hemloc.heap();
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("INFO", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
            return;
        };

        log(out, false) catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn warn(
    comptime msg: Str,
    args: anytype,
    ctx: ?[]CtxData,
    src: SrcLoc
) void {
    if (Self.iso().level & WARN == WARN) {
        const heap = Hemloc.heap();
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("WARN", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, false)  catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn err(
    comptime msg: Str,
    args: anytype,
    ctx: ?[]CtxData,
    src: SrcLoc
) void {
    if (Self.iso().level & ERROR == ERROR) {
        const heap = Hemloc.heap();
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("ERROR", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, false)  catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn fatal(
    comptime msg: Str,
    args: anytype,
    ctx: ?[]CtxData,
    src: SrcLoc
) void {
    if (Self.iso().level & FATAL == FATAL) {
        const heap = Hemloc.heap();
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("FATAL", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, true) catch |e| utils.unrecoverable(e, @src());
    }
}

fn log(data: Str, blocking: bool) !void {
    const heap = Hemloc.heap();

    if (blocking or AsyncIo.evlStatus() == .closed) {
        defer heap.free(data);

        if (Hemloc.which() == .testing) return;
        // Raw printing e.g., `StdOut` in unit tests is currently illegal
        // ↑ skips the following code when running on unit testing

        var std_out = std.io.getStdOut().writer();
        try std_out.print("{s}", .{data});
        return;
    }

    const sop = Self.iso();
    const fd = switch (sop.output) {.Console => 2, .File => sop.fd.?};

    const log_data = try heap.create(LogData);
    log_data.* = LogData { .data = data };

    try AsyncIo.write(cleanUp, @as(*anyopaque, log_data), .{
        .fd = fd, .buff = data, .count = data.len, .offset = 0
    });
}

fn cleanUp(cqe_res: i32, userdata: ?*anyopaque) void {
    _ = cqe_res;
    const heap = Hemloc.heap();

    const log_data: *LogData = @ptrCast(@alignCast(userdata)); 
    heap.free(log_data.data);
    heap.destroy(log_data);
}

fn format(level: Str, msg: Str, data: ?[]CtxData, src: SrcLoc) !Str {
    const heap = Hemloc.heap();
    const datetime = DateTime.now().toLocal(.BST);

    return blk: {
        if (data) |ctx_data| {
            const out_str = try ctxFormat(ctx_data);
            defer heap.free(out_str);

            const fmt_str = "{s} [{s}] {s} at {d}:{d}\n{s}\n~{s}\n";
            break :blk try fmt.allocPrint(heap, fmt_str, .{
                datetime, level, src.file, src.line, src.column, out_str, msg
            });
        } else {
            const fmt_str = "{s} [{s}] {s} at {d}:{d}\n~{s}\n";
            break :blk try fmt.allocPrint(heap, fmt_str, .{
                datetime, level, src.file, src.line, src.column, msg
            });
        }
    };
}

/// # Formats the Additional User Defined Data
/// **Remarks:** Return value must be freed by the caller.
fn ctxFormat(data: []CtxData) !Str {
    const heap = Hemloc.heap();
    var list = std.ArrayList(u8).init(heap);

    try list.append('{');

    for (data) |ctx| {
        const fmt_str = "{s}: {s},";
        const out = try fmt.allocPrint(heap, fmt_str, .{ctx.name, ctx.value});
        defer heap.free(out);

        try list.appendSlice(out);
    }

    _ = list.pop();
    try list.append('}');

    return try list.toOwnedSlice();
}
