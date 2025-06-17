//! # App Router Module (Compile-Time)

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const meta = std.meta;
const Allocator = mem.Allocator;

const Stencil = @import("stencil").Stencil;

const http = @import("./server/http.zig");
const Payload = http.Payload;
const Headers = http.Headers;
const Request = http.Request;
const Response = http.Response;

const app_agent = @import("../agent.zig");


const Str = []const u8;
const Target = Str;

pub const Error = error { InternalServerError };

/// # Global Module Pointer
/// - Provides access to the system wide core module instances
pub const Portal = struct {
    heap: Allocator,
    tmpl: *Stencil,
};

const Kind = enum { DataApi, WebPage, WebSocket };

const Get = *const fn (*Portal, *Request, *Headers) Error!Response;
const Post = *const fn (u8, u8) void;
const Tunnel = *const fn (u8, u8, u8) void;

const HandleKind = enum { GET, POST, TUNNEL };

pub const Handle = union(HandleKind) {
    GET: Get,
    POST: Post,
    TUNNEL: Tunnel,

    /// # Method Agnostic `fn` Registration
    pub fn apply(handle: anytype) Handle {
        return switch(@TypeOf(handle)) {
            Get => .{.GET = handle},
            Post => .{.POST = handle},
            Tunnel => .{.TUNNEL = handle},
            else => unreachable
        };
    }
};

pub const Guard = meta.Tuple(&.{ HandleKind, Handle });
pub const Agent = meta.Tuple(&.{ HandleKind, Target, Handle });

fn AppRoute(l: usize) type {
    return struct {
        urls: [l]Str,
        uris: [l]UriEndpoint,

        pub fn lookup(self: *const AppRoute(l), url: Str) ?*const UriEndpoint {
            inline for (self.urls, 0..) |entry, i| {
                if (std.mem.eql(u8, url, entry)) return &self.uris[i];
            }
            return null;
        }
    };
}

/// # Returns the App's Endpoint Structure
pub fn aggregate(l: usize) AppRoute(l) {
    const uris = UriEndpoint.flatten(app_agent, l);

    var urls: [l]Str = undefined;
    for (0..l) |i| { urls[i] = uris[i].url; }

    checkForDuplicatesUrl(&urls);
    return AppRoute(l) {.urls = urls, .uris = uris};
}

pub fn countAll() usize { return UriEndpoint.totalLength(app_agent); }

fn checkForDuplicatesUrl(urls: []const Str) void {
    for (urls, 0..) |url_i, i| {
        for (urls[i + 1..]) |url_j| {
            if (std.mem.eql(u8, url_i, url_j)) {
                const fmt_str = "Found duplicate URL: {s} on `agent.zig`";
                @compileError(fmt.comptimePrint(fmt_str, .{url_j}));
            }
        }
    }
}

/// # Creates a New Routing Endpoint
/// **Remarks:** Bundles similar APIs under shared guards and resource limits.
pub fn lane(kind: Kind, comptime scope: Str) Endpoint {
    return Endpoint {
        .kind = kind,
        .scope = scope
    };
}

/// # High Level URI Endpoint
/// **Remarks:** Simplifies agent declaration and avoids code duplication.
const Endpoint = struct {
    kind: Kind,
    scope: Str,
    guards: ?[]const Guard = null,
    agents: ?[]const Agent = null,
    limit: usize = Option.post_limit,
    capacity: usize = Option.post_capacity,

    // TODO: Add support for timeout on long running task
    // This value should override the keepalive timeout
    const Option  = struct {
        const post_limit = 1024 * 1024 * 32; // Default size: 32MB
        const post_capacity = 1024 * 256;    // Default size: 256KB

        /// **Post Data Limit in Kilobytes**
        /// - Maximum payload data a client can send on this lane
        limit: usize = post_limit,

        /// **Post Data Capacity in Kilobytes**
        /// - Maximum payload data converted to the given structure
        /// - When exceeds the capacity, data will be delivered as stream
        capacity: usize = post_capacity,
    };

    // NOTE: Following functions are order dependent

    /// # Attaches Resource Constraints
    pub fn mount(self: Endpoint, opt: Option) Endpoint {
        // TODO: Restrict mount based on only DataApi

        return .{
            .kind = self.kind,
            .scope = self.scope,
            .limit = 1024 * opt.limit,
            .capacity = 1024 * opt.capacity
        };
    }

    /// # Applies Prefix Guards to Specific Agents
    /// **Remarks:** Guards will execute in the order they are defined.
    pub fn guard(self: Endpoint, list: []const Guard) Endpoint {
        return .{
            .kind = self.kind,
            .scope = self.scope,
            .limit = self.limit,
            .capacity = self.capacity,
            .guards = list
        };
    }

    /// # Registers a Handler to Dispatch a Specific Task
    pub fn agent(self: Endpoint, list: []const Agent) Endpoint {
        return .{
            .kind = self.kind,
            .scope = self.scope,
            .guards = self.guards,
            .limit = self.limit,
            .capacity = self.capacity,
            .agents = list
        };
    }
};

/// # Low Level URI Endpoint
pub const UriEndpoint = struct {
    kind: Kind,
    guards: []const Handle,
    url: Str,
    handle: Handle,
    limit: usize,
    capacity: usize,

    /// # Converts All Raw Endpoint into UriEndpoint
    pub fn flatten(T: type, l: usize) [l]UriEndpoint {
        var i: usize = 0;
        var uris: [l]UriEndpoint = undefined;

        inline for (@typeInfo(T).@"struct".decls) |d| {
            switch (@TypeOf(@field(T, d.name))) {
                Endpoint => {
                    const val: Endpoint = @field(T, d.name);
                    for (getAgents(&val, agentLength(&val))) |agent| {
                        const len = guardLength(&val, agent);
                        const guards = getGuards(&val, agent, len);

                        uris[i] = UriEndpoint {
                            .kind = val.kind,
                            .guards = &guards,
                            .url = val.scope ++ agent[1],
                            .handle = agent[2],
                            .limit = val.limit,
                            .capacity = val.capacity
                        };

                        i += 1;
                    }
                },
                else => {} // NOP
            }
        }

        return uris;
    }

    /// # Returns Guard Handles form a Given Endpoint
    /// **Remarks:** Only the method that matches from the agent is included.
    fn getGuards(endpoint: *const Endpoint, agent: Agent, l: usize) [l]Handle {
        var i: usize = 0;
        var handles: [l]Handle = undefined;

        if (endpoint.guards) |guards| {
            for (guards) |guard| {
                verifyHandle(endpoint, guard[0]);
                if (agent[0] == guard[0]) handles[i] = guard[1];
                i += 1;
            }
        }

        return handles;
    }

    /// # Returns Guard Counts
    /// **Remarks:** Counts all guard entries on a given endpoint.
    fn guardLength(endpoint: *const Endpoint, agent: Agent) usize {
        var count: usize = 0;
        if (endpoint.guards) |guards| {
            for (guards) |guard| {
                if (agent[0] == guard[0]) count += 1;
            }
        }
        return count;
    }

    /// # Returns Agents Tuple form a Given Endpoint
    fn getAgents(endpoint: *const Endpoint, l: usize) [l]Agent {
        var i: usize = 0;
        var agents: [l]Agent = undefined;
        for (endpoint.agents.?) |agent| {
            verifyHandle(endpoint, agent[0]);
            agents[i] = agent;
            i += 1;
        }

        return agents;
    }

    /// # Verifies Agent or Guard Based on `Kind`
    fn verifyHandle(endpoint: *const Endpoint, kind: HandleKind) void {
        switch (endpoint.kind) {
            .DataApi => {
                if (kind == .TUNNEL) {
                    @compileError(fmt.comptimePrint(
                        "`{s}` isn't allowed at {s} lane on `agent.zig`",
                        .{@tagName(kind), endpoint.scope}
                    ));
                }
            },
            .WebPage => {
                if (kind != .GET) {
                    @compileError(fmt.comptimePrint(
                        "`{s}` isn't allowed at {s} lane on `agent.zig`",
                        .{@tagName(kind), endpoint.scope}
                    ));
                }
            },
            .WebSocket => {
                if (kind != .TUNNEL) {
                    @compileError(fmt.comptimePrint(
                        "`{s}` isn't allowed at {s} lane on `agent.zig`",
                        .{@tagName(kind), endpoint.scope}
                    ));
                }
            }
        }
    }

    /// # Returns Agent Counts
    /// **Remarks:** Counts all agent entries on a given endpoint.
    fn agentLength(endpoint: *const Endpoint) usize {
        var count: usize = 0;
        if (endpoint.agents) |agents| {
            for (agents) |_| { count += 1; }
        }
        return count;
    }

    /// # Returns Total Agent Counts
    /// **Remarks:** Counts all entries from top-level `pub` declarations.
    fn totalLength(T: type) usize {
        var count: usize = 0;
        inline for (@typeInfo(T).@"struct".decls) |d| {
            switch (@TypeOf(@field(T, d.name))) {
                Endpoint => {
                    const val: Endpoint = @field(T, d.name);
                    if (val.agents) |agents| count += agents.len;
                },
                else => {} // NOP
            }
        }

        return count;
    }
};
