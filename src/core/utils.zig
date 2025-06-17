//! # Utility Module

const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const linux = std.os.linux;
const Allocator = mem.Allocator;
const SrcLoc = std.builtin.SourceLocation;

const Cfp = @import("cfp").Cfp;
const Stencil = @import("stencil").Stencil;

const Log = @import("./logger.zig");
const paths = @import("./paths.zig");
const route = @import("./route.zig");
const DateTime = @import("./datetime.zig");


/// # Logs Syscall Error Number
/// - e.g., `utils.syscallError(9, @src());`
pub fn syscallError(code: i32, src: SrcLoc) void {
    const err: linux.E = @enumFromInt(@as(u16, @truncate(@abs(code))));
    const fmt_str = "Syscall - Errno {d} E{s} occurred in {s} at line {d}";
    log.err(fmt_str, .{code, @tagName(err), src.file, src.line});
}

/// # Out of Memory Error
/// **Remarks:** Exhausting memory means that all bets are off. Handling
/// fallible memory allocations often leads to code complexity and sometimes
/// not worth the effort. However, be cautious about the potential data lose!
pub fn oom(src: SrcLoc) noreturn {
    const datetime = DateTime.now().toLocal(.BST);
    const fmt_str = "{s} [FATAL] {s} at {d}:{d}\n~";
    log.info(fmt_str, .{datetime, src.file, src.line, src.column});
    log.err("Out Of Memory", .{});
    std.process.exit(255);
}

/// # App Abruptly Exits
///
/// **Remarks:** `@panic()` and `std.debug.panic()` has inconstancy.
/// Process doesn't exit completely when calling from detached threads.
pub fn panic(comptime format: []const u8, args: anytype, src: SrcLoc) noreturn {
    const datetime = DateTime.now().toLocal(.BST);
    const fmt_str = "{s} [FATAL] {s} at {d}:{d}\n~";
    log.info(fmt_str, .{datetime, src.file, src.line, src.column});
    log.err(format, args);
    std.process.exit(254);
}

/// # Unrecoverable Error Handle
/// **Remarks:** Prevents unnecessary code repetition when needed multiple times
pub fn unrecoverable(err: anyerror, src: SrcLoc) noreturn {
    panic("{s}", .{@errorName(err)}, src);
}

//##############################################################################
//# PAGE TEMPLATING FUNCTIONALITIES ------------------------------------------ #
//##############################################################################

pub const PageTemplate = struct {
    const Str = []const u8;
    const Uris = []const route.UriEndpoint;

    fn debug() !bool { return try Cfp.getBool("preset.debug"); }

    /// # Evaluates All WebPage Templates
    /// **Remarks:** Evaluates only once and the pages are caches on the memory.
    /// When in `debug` mode, generated pages are saved on the `.tmp` directory.
    pub fn evaluate(heap: Allocator, template: *Stencil, uris: Uris) !void {
        if (try debug()) { try TempPageDirectory.create(heap); }

        for (uris) |uri| {
            if (uri.kind != .WebPage) continue;

            const url = if (mem.eql(u8, uri.url, "/")) "/index" else uri.url;
            var ctx = try template.new(uri.url);

            const page = try std.fmt.allocPrint(heap, "{s}.html", .{url[1..]});
            defer heap.free(page);

            ctx.load(page) catch |err| {
                panic("{s}", .{@errorName(err)}, @src());
            };
            defer ctx.free();

            try ctx.expand();
            const data = try ctx.read();

            if (try debug()) { try writeToTemp(heap, page, data.?); }
        }
    }

    /// # Destroys the Evaluated Pages
    /// **Remarks:** `NOP` when debug is disabled in the `app.conf`.
    pub fn destroy(heap: Allocator) void {
        if (debug() catch unreachable) { TempPageDirectory.remove(heap); }
    }

    fn writeToTemp(heap: Allocator, page: Str, content: Str) !void {
        const page_dir = try Cfp.getStr("preset.page_dir");

        const dir = try paths.appDir(heap, page_dir);
        defer heap.free(dir);

        // File name sanitization for nested page e.g., public/index.html
        const sp = try mem.replaceOwned(u8, heap, page, "/", "_");
        defer heap.free(sp);

        const f_path = try fmt.allocPrint(heap, "{s}/.tmp/{s}", .{dir, sp});
        defer heap.free(f_path);

        const fd = fs.cwd().openFile(f_path, .{}) catch {
            var file = try fs.cwd().createFile(f_path, .{});
            defer file.close();

            try file.writeAll(content);
            return;
        };

        fd.close();
    }
};

/// # Generated Runtime Directory for Dynamic Pages
const TempPageDirectory = struct {
    const DirFlag = enum { Create, Remove };

    /// # Creates the Page Cache Directory
    fn create(heap: Allocator) !void {
        const tpd = try tmpDirPath(heap);
        defer heap.free(tpd);

        var tmp = fs.cwd().openDir(tpd, .{.iterate = true}) catch {
            try fs.cwd().makeDir(tpd);
            return;
        };
        defer tmp.close();

        var iter = tmp.iterate();
        try removePages(heap, &iter);
    }

    /// # Removes the Page Cache Directory and All of It's Pages
    fn remove(heap: Allocator) void {
        removeZ(heap) catch |err| {
            Log.err("{s}", .{@errorName(err)}, null, @src());
        };
    }

    fn removeZ(heap: Allocator) !void {
        const tpd = try tmpDirPath(heap);
        defer heap.free(tpd);

        var tmp = try fs.cwd().openDir(tpd, .{.iterate = true});
        defer tmp.close();

        var iter = tmp.iterate();
        try removePages(heap, &iter);
        try fs.cwd().deleteDir(tpd);
    }

    /// # Removes Individual Pages with in the Cache Directory
    fn removePages(heap: Allocator, iter: *fs.Dir.Iterator) !void {
        const tpd = try tmpDirPath(heap);
        defer heap.free(tpd);

        while (true) {
            const entry = try iter.next();
            if (entry) |item| {
                if (item.kind == .file) {
                    const f_path = try fmt.allocPrintZ(
                        heap, "{s}/{s}", .{tpd, item.name}
                    );
                    defer heap.free(f_path);
                    try fs.cwd().deleteFile(f_path);
                }
            } else {
                break;
            }
        }
    }

    /// # Returns Temporary Page Directory
    /// **WARNING:** Return value must be freed by the caller.
    fn tmpDirPath(heap: Allocator) ![]const u8 {
        const page_dir = try Cfp.getStr("preset.page_dir");
        const app_dir = try paths.appDir(heap, page_dir);
        defer heap.free(app_dir);

        return try paths.resolve(heap, &.{app_dir, ".tmp"});
    }
};
