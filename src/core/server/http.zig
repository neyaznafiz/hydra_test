//! # Barebones HTTP/1.1 Server

const std = @import("std");
const mem = std.mem;
const net = std.net;
const linux = std.os.linux;

const Cfp = @import("cfp").Cfp;
const Portal = @import("../route.zig").Portal;
const Socket = @import("../socket.zig").Socket;

const Hemloc = @import("../../core/hemloc.zig");

const Log = @import("../logger.zig");
const AsyncIo = @import("../../main.zig").AsyncIo;
const Executor = @import("../../main.zig").Executor;

const utils = @import("../utils.zig");
const parser = @import("./http/parser.zig");
const server_utils = @import("./utils.zig");

const common = @import("./http/common.zig");
pub const Payload = common.Payload;
pub const Headers = common.Headers;
pub const Request = common.Request;
pub const Response = common.Response;
pub const HeaderProperty = common.HeaderProperty;
pub const ResponseStatus = common.ResponseStatus;

const app_route = @import("../../main.zig").app_route;


/// # Returned Op Code
const IO = enum(i32) {
    /// Timer expired
    Expired  = -62,
    /// Operation Canceled
    Canceled = -125
};

const SingletonObject = struct {
    tcp: Socket,
    portal: Portal,
    keepalive: i64,
    peer: Peer.Address,
    mio_accept: u64 = undefined,
};

var so: ?SingletonObject = null;

/// - Req/Res buffer size for a connection
/// - Default size in Linux, used by the kernel when a socket is created.
const buff_sz: usize = 1024 * 16; // 16KB

const Self = @This();

/// # Initializes and Runs the HTTP Server
pub fn init(portal: Portal) !void {
    if (Self.so != null) @panic("Initialize Only Once Per Process!");

    const host = try Cfp.getStr("server.http.ip_address");
    const port = try Cfp.getInt(u16, "server.http.port");
    const backlog = try Cfp.getInt(u31, "server.http.backlog");
    const keepalive = try Cfp.getInt(i64, "server.http.keepalive");

    var tcp_sock = Socket.new(.INET, .STREAM, .TCP);
    const ip_addr = try Socket.Ipv4(host, port);
    try Socket.Tcp.serveOn(&tcp_sock, ip_addr, backlog, .{
        .count = 10, .idle = 120, .interval = 60
    });

    const addr = linux.sockaddr{.family = 2, .data = [_]u8{ 0 } ** 14};
    const peer = Peer.Address {.addr = addr, .len = @sizeOf(linux.sockaddr)};

    Self.so = SingletonObject {
        .tcp = tcp_sock,
        .portal = portal,
        .keepalive = keepalive,
        .peer = peer
    };

    Self.so.?.mio_accept = try Peer.connection(tcp_sock.fd, &Self.iso().peer);
    Log.info("HTTP Server is running on {s}:{d}", .{host, port}, null, @src());
}

/// # Destroys the Http Server
pub fn deinit() void { Self.iso().tcp.close(); }

/// # Unbinds Listening Socket
/// **Remarks:** Intended to be invoked when termination signal is issued.
pub fn unbind() void {
    const sop = Self.iso();
    AsyncIo.cancel(null, null, .{.userdata = sop.mio_accept}) catch |err| {
        utils.unrecoverable(err, @src());
    };
}

/// # Returns Internal Static Object
pub fn iso() *SingletonObject { return &Self.so.?; }

const Peer = struct {
    const Address = struct { addr: linux.sockaddr, len: u32 };

    const Data = struct {
        fd: i32,
        timeout: u64 = 0,
        peer: net.Address,
        buff: [buff_sz]u8,
        stale: bool = false,
        req: Request = mem.zeroes(Request),
        headers: Headers = undefined,
        res: ?Response = null
    };

    /// # Accepts Incoming TCP Socket Connections
    fn connection(fd: i32, peer: *Address) !u64 {
        return try AsyncIo.accept(handle, @as(?*anyopaque, peer), .{
            .fd = fd, .addr = &peer.addr, .len = &peer.len
        });
    }

    /// # Incoming Peer Connection Handler
    fn handle(cqe_res: i32, data: ?*anyopaque) void {
        // Extracts the address of the new peer connection
        const peer_addr: *Address = @ptrCast(@alignCast(data));

        if (cqe_res > 0) {
            const req_data = Hemloc.heap().create(Data) catch |err| {
                utils.unrecoverable(err, @src());
            };

            req_data.* = Data {
                .fd = cqe_res,
                .peer = server_utils.peerAddress(peer_addr.addr),
                .buff = [_]u8 {0} ** buff_sz
            };

            // Default is undefined, therefore offset could have garbage value.
            req_data.headers.offset = 0;

            // Dispatching task to worker via executor
            Executor.submit(handleW, @as(?*anyopaque, req_data)) catch |err| {
                utils.unrecoverable(err, @src());
            };

            return;
        }

        if (cqe_res == @intFromEnum(IO.Canceled)) return;
        utils.syscallError(cqe_res, @src());
    }

    fn handleW(args: ?*anyopaque) void {
        const data: *Data = @ptrCast(@alignCast(args));
        data.timeout = setTimeout(data);

        AsyncIo.recv(Connection.handle, args, .{
            .fd = data.fd, .buff = &data.buff, .len = data.buff.len
        }) catch |err| utils.unrecoverable(err, @src());
    }

    /// # Sets Keepalive Timeout for a Peer Connection
    fn setTimeout(data: ?*anyopaque) u64 {
        return AsyncIo.timeout(Connection.close, data, .{
            .ts = linux.timespec {.sec = Self.iso().keepalive, .nsec = 0}
        }) catch |err| utils.unrecoverable(err, @src());
    }

    /// # Resets Keepalive Timeout for a Peer Connection
    fn resetTimeout(data: u64) void {
        AsyncIo.timeopt(null, null, .{
            .timeout_data = data,
            .ts = linux.timespec {.sec = Self.iso().keepalive, .nsec = 0}
        }) catch |err| utils.unrecoverable(err, @src());
    }

    // fn clearTimeout()
};

const Connection = struct {
    fn handle(cqe_res: i32, args: ?*anyopaque) void {
        const data: *Peer.Data = @ptrCast(@alignCast(args));
        switch (cqe_res) {
            0 => { // The peer has performed an orderly shutdown
                if (!data.stale) data.stale = true
                else {
                    AsyncIo.close(free, args, .{.fd = data.fd}) catch |err| {
                        utils.unrecoverable(err, @src());
                    };
                }
            },
            else => {
                // Dispatching task to worker via executor
                Executor.submit(handleW, args) catch |err| {
                    utils.unrecoverable(err, @src());
                };
            }
        }
    }

    fn parseRequest(args: ?*anyopaque) bool {
        const data: *Peer.Data = @ptrCast(@alignCast(args));
        const req: *Request = &data.req;

        parser.parseRequest(&data.buff, req) catch |err| {
            const status = switch (err) {
                error.LimitExceeded => ResponseStatus.payloadTooLarge(),
                else => ResponseStatus.internalServerError()
            };

            Log.err("{s}", .{@errorName(err)}, null, @src());
            resError(status, args);
            return false;
        };

        return true;
    }

    fn resError(status: ResponseStatus, args: ?*anyopaque) void {
        const data: *Peer.Data = @ptrCast(@alignCast(args));

        const res = status.toString(&data.buff) catch unreachable;
        AsyncIo.send(Connection.terminate, args, .{
            .buff = res, .fd = data.fd, .len = res.len
        }) catch |err2| utils.unrecoverable(err2, @src());
    }

    fn getHandle(route: anytype, args: ?*anyopaque) void {
        const data: *Peer.Data = @ptrCast(@alignCast(args));
        const h: *Headers = &data.headers;
        const r: *Request = &data.req;
        const p = &Self.iso().portal;

        data.res = route.handle.GET(p, r, h) catch |err| {
            Log.err("{s}", .{@errorName(err)}, null, @src());
            const status = ResponseStatus.internalServerError();
            return resError(status, args);
        };

        const stat = data.res.?.status;
        const head = Response.headStr(&data.buff, stat, h) catch unreachable;

        AsyncIo.send(Connection.chunk, args, .{
            .buff = head, .fd = data.fd, .len = head.len
        }) catch |err2| utils.unrecoverable(err2, @src());
    }

    // should process the large payload
    fn chunk(cqe_res: i32, args: ?*anyopaque) void {
        _ = cqe_res;
        const data: *Peer.Data = @ptrCast(@alignCast(args));
        const res: *Response = &data.res.?;

        // std.debug.print("response: off: {} len: {}\n", .{res.*.offset, res.*.len});

        // will will handle any empty body response here
        if (res.len == 0) {
            std.debug.print("should not be here\n", .{});
            return;
        }

        if (res.offset < res.len) {
            const size = res.len - res.offset;
            const len = if (size <= buff_sz) size else buff_sz;
            res.offset += len;

            const data2 = switch (res.src) {
                .Static => |x| x,
                .Dynamic => |x| x,
                .Empty => ""
            };

            AsyncIo.send(Connection.chunk, args, .{
                .buff = data2, .fd = data.fd, .len = len
            }) catch |err2| utils.unrecoverable(err2, @src());
        } else {
            // for now just drop the connection
            Connection.terminate(0, data);



            // Here we will either close the connection or keep going
            // what happends to the earlier structure?

            // data.req = mem.zeroes(Request);
            // data.headers = undefined;
            // data.res = null;


            // Peer.resetTimeout(data.timeout);
            // AsyncIo.recv(Connection.handle, args, .{
            //     .fd = data.fd, .buff = &data.buff, .len = data.buff.len
            // }) catch |err| utils.unrecoverable(err, @src());
        }

        
    }

    // fn lastChunk(args: ?*anyopaque) void {

    // }

    fn handleW(args: ?*anyopaque) void {
        const data: *Peer.Data = @ptrCast(@alignCast(args));
        const req: *Request = &data.req;

        if (!Connection.parseRequest(args)) return;

        if (app_route.lookup(req.getUrl())) |route| {
            const method = req.getMethod();

            switch (route.handle) {
                .GET => {
                    if (method == .GET) {
                        // call all available guards here
                        // if all succeed then call the handle

                        getHandle(route, args);
                        return;
                    }
                },
                .POST => {
                    if (method == .POST) {
                        const status = ResponseStatus.serviceUnavailable();
                        const res = status.toString(&data.buff) catch unreachable;
                        AsyncIo.send(Connection.terminate, args, .{
                            .buff = res, .fd = data.fd, .len = res.len
                        }) catch |err2| utils.unrecoverable(err2, @src());
                        return;
                    }
                },
                .TUNNEL => {
                    if (method == .GET) {
                        const status = ResponseStatus.serviceUnavailable();
                        const res = status.toString(&data.buff) catch unreachable;
                        AsyncIo.send(Connection.terminate, args, .{
                            .buff = res, .fd = data.fd, .len = res.len
                        }) catch |err2| utils.unrecoverable(err2, @src());
                        return;
                    }
                }
            }
            

            const status = ResponseStatus.methodNotAllowed();
            const res = status.toString(&data.buff) catch unreachable;
            AsyncIo.send(Connection.terminate, args, .{
                .buff = res, .fd = data.fd, .len = res.len
            }) catch |err2| utils.unrecoverable(err2, @src());

            return;
        }

        // TODO: here rather then sending not found send custom page
        const status = ResponseStatus.notFound();
        const res = status.toString(&data.buff) catch unreachable;
        AsyncIo.send(Connection.terminate, args, .{
            .buff = res, .fd = data.fd, .len = res.len
        }) catch |err2| utils.unrecoverable(err2, @src());


        // TODO: check this url: http://192.168.64.36:8080/en-us/home
        // to see if still panics




        // 

        // std.debug.print("working {s}\n", .{data.req.getUrl()});

        // for (data.req.getQueryNames()) |name| {
        //     const val = data.req.getQuery(name);
        //     std.debug.print("Query - {s}: {s}\n", .{name, val.?});
        // }

        // // const val = data.req.getDupQueries(2, "foo");
        // // std.debug.print("Header - {s}\n", .{val.?[0].?});

        // // TODO: serve the actual response and then receive again


        // Peer.resetTimeout(data.timeout);
        // AsyncIo.recv(Connection.handle, args, .{
        //     .fd = data.fd, .buff = &data.buff, .len = data.buff.len
        // }) catch |err| utils.unrecoverable(err, @src());
    }

    // should process the next request
    fn next() void {

    }

    /// # Shuts Down or Closes an Expired Connection
    fn close(cqe_res: i32, args: ?*anyopaque) void {
        switch (cqe_res) {
            @intFromEnum(IO.Expired) => {
                const data: *Peer.Data = @ptrCast(@alignCast(args));
                if (data.stale) {
                    AsyncIo.close(free, args, .{.fd = data.fd}) catch |err| {
                        utils.unrecoverable(err, @src());
                    };
                }
                else {
                    data.stale = true;
                    AsyncIo.shutdown(null, null, .{
                        .fd = data.fd, .channel = .Write
                    }) catch |err| utils.unrecoverable(err, @src());
                }
            },
            else => utils.syscallError(cqe_res, @src())
        }
    }

    /// # Shuts Down an Established Connection
    fn terminate(cqe_res: i32, args: ?*anyopaque) void {
        if (cqe_res >= 0) {
            const data: *Peer.Data = @ptrCast(@alignCast(args));
            data.stale = true;

            AsyncIo.shutdown(null, null, .{
                .fd = data.fd, .channel = .Duplex
            }) catch |err| utils.unrecoverable(err, @src());
        } else {
            utils.syscallError(cqe_res, @src());
        }
    }

    /// # Releases Allocated `Request.Data` from the Heap
    fn free(ceq_res: i32, args: ?*anyopaque) void {
        std.debug.assert(ceq_res == 0);
        const data: *Peer.Data = @ptrCast(@alignCast(args));
        Hemloc.heap().destroy(data);
    }
};