//! # Describe Your Agent
//! - Add additional remarks gere

const Log = @import("../../core/logger.zig");

const route = @import("../../core/route.zig");
const Error = route.Error;
const Portal = route.Portal;

const http = @import("../../core/server/http.zig");
const Headers = http.Headers;
const Request = http.Request;
const Response = http.Response;

// ↓  Start writing your custom agent code from here!

const std = @import("std");


pub fn foo(p: *Portal, r: *Request, h: *Headers) Error!Response {
    return fooZ(p, r, h) catch |err| {
        Log.err("{s}", .{@errorName(err)}, null, @src());
        return Error.InternalServerError;
    };
}

fn fooZ(p: *Portal, r: *Request, h: *Headers) !Response {
    _ = p;
    _ = h;

    std.debug.print("Got: {s}\n", .{r.url});

    return error.notimpl;
}

