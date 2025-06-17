//! # Application Entry Point
//! - Please do not write any app-specific code here!

const std = @import("std");
const linux = std.os.linux;

const Cfp = @import("cfp").Cfp;
const Stencil = @import("stencil").Stencil;

const saturn = @import("saturn");
const Signal = saturn.Signal;
pub const AsyncIo = saturn.AsyncIo(512);
pub const Executor = saturn.TaskExecutor(512);

const route = @import("./core/route.zig");
const Portal = route.Portal;

const Log = @import("./core/logger.zig");
const Hemloc = @import("./core/hemloc.zig");
const HttpServer = @import("./core/server/http.zig");

const utils = @import("./core/utils.zig");
const paths = @import("./core/paths.zig");

pub const app_route = route.aggregate(route.countAll());


pub fn main() !void {
    Hemloc.init();
    defer Hemloc.deinit();

    const heap = Hemloc.heap();

    // Server Configuration File
    const cf_opt = try paths.appConfPath(heap, "app.conf");
    defer heap.free(cf_opt.abs_path);

    try Cfp.init(heap, cf_opt);
    defer Cfp.deinit();

    // More efficient then Zig's GPA (memory leaks are ignored)
    const allocator_interface = try Cfp.getInt(u8, "preset.allocator");
    if (allocator_interface == 1) Hemloc.setMalloc();

    try Signal.init();
    Signal.Linux.signal(linux.SIG.INT, Signal.register);
    Signal.Linux.signal(linux.SIG.TERM, Signal.register);

    const debug_mode = try Cfp.getBool("preset.debug");

    try Executor.init(null, debug_mode);
    defer Executor.deinit();

    try AsyncIo.init(debug_mode);
    defer AsyncIo.deinit();

    try Log.init();
    defer Log.deinit();

    // Page template evaluation
    const page_dir = try Cfp.getStr("preset.page_dir");
    const page_limit = try Cfp.getInt(usize, "preset.page_limit");

    const dir = try paths.appDir(Hemloc.heap(), page_dir);
    defer Hemloc.heap().free(dir);

    var template = try Stencil.init(Hemloc.heap(), dir, page_limit);
    defer template.deinit();

    try utils.PageTemplate.evaluate(Hemloc.heap(), &template, &app_route.uris);
    defer utils.PageTemplate.destroy(Hemloc.heap());

    try HttpServer.init(Portal {.heap = heap, .tmpl = &template });
    defer HttpServer.deinit();

    try AsyncIo.eventLoop(1, .{HttpServer.unbind});

    Signal.terminate(Executor);
}
