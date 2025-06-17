//! # Delivers Web Pages Generated from Templates

const Log = @import("../core/logger.zig");

const route = @import("../core/route.zig");
const Error = route.Error;
const Portal = route.Portal;

const http = @import("../core/server/http.zig");
const Headers = http.Headers;
const Payload = http.Payload;
const Request = http.Request;
const Response = http.Response;
const Header = http.HeaderProperty;
const Status = http.ResponseStatus;

// ↓  Start writing your custom agent code from here!

const std = @import("std");

pub fn serve(p: *Portal, r: *Request, h: *Headers) Error!Response {
    return serveZ(p, r, h) catch |err| {
        Log.err("{s}", .{@errorName(err)}, null, @src());
        return Error.InternalServerError;
    };
}

fn serveZ(p: *Portal, r: *Request, h: *Headers) !Response {
    const data = p.tmpl.read(r.url);

    h.add(Header.Name.@"Content-Type", "text/html; charset=utf-8");
    h.add(Header.Name.@"Content-Length", data.?.len);

    return Payload.static(Status.ok(), data.?);
}
