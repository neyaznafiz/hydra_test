//! # Http/1.1 Utility Module
//! - Provides common data structure and functionalities

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const meta = std.meta;
const ascii = std.ascii;
const Allocator = mem.Allocator;


const Str = []const u8;

pub const SpecialChar = struct {
    /// # Space Character
    /// Also known as white space, used to separate tokens or fields.
    pub const SP = 0x20;

    /// # Line Feed
    /// `\n` - Also known as new line. used to separate tokens or fields.
    pub const LF = 0x0A;

    /// # Carriage Return
    /// `\r` - Moves the cursor to the beginning of the current line.
    pub const CR = 0x0D;

    /// # Horizontal Tab
    /// `\t` - Moves the cursor to the next tab stop, often every 4 or 8 SPs.
    pub const HT = 0x09;

    /// # Vertical Tab
    /// It's rarely used and often ignored or treated as whitespace.
    pub const VT = 0x0B;

    /// # Form Feed
    /// It's rarely used and often ignored or treated as whitespace.
    pub const FF = 0x0C;
};

/// # Supported HTTP/1.1 Methods
pub const Method = enum { GET, POST };

/// # HTTP/1.1 Request Structure
/// **Remarks:** All slices are pointer to the underlying request buffer!
/// Make sure not to exceed the buffer lifetime or use after buffer overwrite.
pub const Request = struct {
    method: Method,
    url: Str,

    q_offset: usize = 0,
    q_name: [8]Str,
    q_value: [8]Str,
    // ↑ Predefined list of queries, where:
    // - Entries at even indices are query names
    // - Entries at odd indices are the corresponding values.

    h_offset: usize = 0,
    h_name: [24]Str,
    h_value: [24]Str,
    // ↑ Predefined list of headers, where:
    // - Entries at even indices are header names
    // - Entries at odd indices are the corresponding values.

    /// # Returns the Requested Method
    pub fn getMethod(self: *const Request) Method { return self.method; }

    /// # Returns the Requested (Target) URL
    pub fn getUrl(self: *const Request) Str { return self.url; }

    /// # Returns the Total Query Count
    pub fn countQueries(self: *const Request) usize { return self.q_offset; }

    /// # Returns the Query Value
    /// **Remarks:** In cases of duplicate queries, only the first one is
    /// returned and the value of the given `name` is case in-sensitive.
    pub fn getQuery(self: *const Request, name: Str) ?Str {
        for (0..self.q_offset) |i| {
            if (ascii.eqlIgnoreCase(name, self.q_name[i])) {
                return self.q_value[i];
            }
        }
        return null;
    }

    /// # Returns the Duplicate Query Values
    /// - `len` - Return up to the give number of duplicate queries.
    pub fn getDupQueries(
        self: *const Request,
        comptime len: usize,
        name: Str
    ) ?[len]?Str {
        var offset: usize = 0;
        var queries = [_]?Str { null } ** len;

        for (0..self.q_offset) |i| {
            if (ascii.eqlIgnoreCase(name, self.q_name[i])) {
                queries[offset] = self.q_value[i];
                offset += 1;
            }
        }

        return if (offset == 0) null
        else queries;
    }

    /// # Returns All Query Names
    pub fn getQueryNames(self: *const Request) []const Str {
        return self.q_name[0..self.q_offset];
    }

    /// # Returns the Total Header Count
    pub fn countHeaders(self: *const Request) usize { return self.h_offset; }

    /// # Returns the Header Value
    /// **Remarks:** In cases of duplicate headers, only the first one is
    /// returned and the value of the given `name` is case in-sensitive.
    pub fn getHeader(self: *const Request, name: Str) ?Str {
        for (0..self.h_offset) |i| {
            if (ascii.eqlIgnoreCase(name, self.h_name[i])) {
                return self.h_value[i];
            }
        }
        return null;
    }

    /// # Returns the Duplicate Header Values
    /// - `len` - Return up to the give number of duplicate headers.
    pub fn getDupHeaders(
        self: *const Request,
        comptime len: usize,
        name: Str
    ) ?[len]?Str {
        var offset: usize = 0;
        var headers = [_]?Str { null } ** len;

        for (0..self.h_offset) |i| {
            if (ascii.eqlIgnoreCase(name, self.h_name[i])) {
                headers[offset] = self.h_value[i];
                offset += 1;
            }
        }

        return if (offset == 0) null
        else headers;
    }

    /// # Returns All Header Names
    pub fn getHeaderNames(self: *const Request) []const Str {
        return self.h_name[0..self.h_offset];
    }
};

const SrcKind = enum { Static, Dynamic, Empty };
const SrcData = union(SrcKind) { Static: Str, Dynamic: Str, Empty: void };

/// # HTTP/1.1 Response Structure
pub const Response = struct {
    status: ResponseStatus,
    offset: usize = 0,
    src: SrcData,
    len: usize,

    /// # Returns HTTP/1.1 Formatted Head Payload String
    pub fn headStr(buff: []u8, status: ResponseStatus, headers: *Headers) !Str {
        const status_line = try status.toString(buff);
        const header_fields = try headers.toString(buff[status_line.len..]);

        const len = status_line.len + header_fields.len;
        mem.copyForwards(u8, buff[len..], "\r\n");
        return buff[0..len + 2];
    }
};

pub const ResponseStatus = struct {
    code: u16,
    msg: []const u8,

    /// # Returns Formatted HTTP/1.1 Response Status Line
    pub fn toString(self: *const ResponseStatus, buff: []u8) ![]u8 {
        return try fmt.bufPrint(
            buff, "HTTP/1.1 {d} {s}\r\n", .{self.code, self.msg}
        );
    }

    /// # 1xx: Informational Responses
    /// - Server received the request headers, client should send the body.
    pub fn continueRequest() ResponseStatus {
        return .{.code = 100, .msg = "Continue"};
    }

    /// # 1xx: Informational Responses
    /// - Server is acknowledging that it will switch to the requested protocol.
    pub fn switchingProtocol() ResponseStatus {
        return .{.code = 101, .msg = "Switching Protocols"};
    }

    /// # 2xx: Successful Responses
    /// - The request has succeeded.
    pub fn ok() ResponseStatus {
        return .{.code = 200, .msg = "OK"};
    }

    /// # 2xx: Successful Responses
    /// - The request has been fulfilled, and a new resource has been created.
    pub fn created() ResponseStatus {
        return .{.code = 201, .msg = "Created"};
    }

    /// # 2xx: Successful Responses
    /// - The request has been accepted for processing, but not completed yet.
    pub fn accepted() ResponseStatus {
        return .{.code = 202, .msg = "Accepted"};
    }

    /// # 2xx: Successful Responses
    /// - The request has been processed, but there's no content to be returned.
    pub fn noContent() ResponseStatus {
        return .{.code = 204, .msg = "No Content"};
    }

    /// # 3xx: Redirection Messages
    /// - The URL of the requested resource has been changed permanently.
    pub fn movedPermanently() ResponseStatus {
        return .{.code = 301, .msg = "Moved Permanently"};
    }

    /// # 3xx: Redirection Messages
    /// - The URL of the requested resource has been changed temporarily.
    pub fn found() ResponseStatus {
        return .{.code = 302, .msg = "Found"};
    }

    /// # 3xx: Redirection Messages
    /// - The resource has not been modified since the last request.
    /// - Client can use the cached version.
    pub fn notModified() ResponseStatus {
        return .{.code = 304, .msg = "Not Modified"};
    }

    /// # 3xx: Redirection Messages
    /// - Responding with the requested resource from a different URI.
    /// - Future requests should still use the original URI.
    pub fn temporaryRedirect() ResponseStatus {
        return .{.code = 307, .msg = "Temporary Redirect"};
    }

    /// # 3xx: Redirection Messages
    /// - Responding with the requested resource from a different URI
    /// - Future requests should use the new URI.
    pub fn permanentRedirect() ResponseStatus {
        return .{.code = 308, .msg = "Permanent Redirect"};
    }

    /// # 4xx: Client Error Responses
    /// - Server could not understand the request due to invalid syntax.
    pub fn badRequest() ResponseStatus {
        return .{.code = 400, .msg = "Bad Request"};
    }

    /// # 4xx: Client Error Responses
    /// - The client must authenticate itself to get the requested response.
    pub fn unauthorized() ResponseStatus {
        return .{.code = 401, .msg = "Unauthorized"};
    }

    /// # 4xx: Client Error Responses
    /// - The client does not have access rights to the requested content.
    pub fn forbidden() ResponseStatus {
        return .{.code = 403, .msg = "Forbidden"};
    }

    /// # 4xx: Client Error Responses
    /// - Server can not find the requested resource / URL is not recognized.
    pub fn notFound() ResponseStatus {
        return .{.code = 404, .msg = "Not Found"};
    }

    /// # 4xx: Client Error Responses
    /// - The request method is not supported by the target resource.
    pub fn methodNotAllowed() ResponseStatus {
        return .{.code = 405, .msg = "Method Not Allowed"};
    }

    /// # 4xx: Client Error Responses
    /// - Server would like to shut down this unused connection.
    pub fn requestTimeout() ResponseStatus {
        return .{.code = 408, .msg = "Request Timeout"};
    }

    /// # 4xx: Client Error Responses
    /// - The request conflicts with the current state of the server.
    pub fn conflict() ResponseStatus {
        return .{.code = 409, .msg = "Conflict"};
    }

    /// # 4xx: Client Error Responses
    /// - The requested resource is no longer available.
    pub fn gone() ResponseStatus {
        return .{.code = 410, .msg = "Gone"};
    }

    /// # 4xx: Client Error Responses
    /// - The request entity is larger than limits defined by the server.
    pub fn payloadTooLarge() ResponseStatus {
        return .{.code = 413, .msg = "Payload Too Large"};
    }

    /// # 4xx: Client Error Responses
    /// - The URI requested is longer than the server is willing to interpret.
    pub fn uriTooLong() ResponseStatus {
        return .{.code = 414, .msg = "URI Too Long"};
    }

    /// # 4xx: Client Error Responses
    /// - The client has sent too many requests in a given amount of time.
    pub fn tooManyRequest() ResponseStatus {
        return .{.code = 429, .msg = "Too Many Requests"};
    }

    /// # 5xx: Server Error Responses
    /// - Server has encountered a situation it doesn’t know how to handle.
    pub fn internalServerError() ResponseStatus {
        return .{.code = 500, .msg = "Internal Server Error"};
    }

    /// # 5xx: Server Error Responses
    /// - The request method isn't supported by the server and can't be handled.
    pub fn notImplemented() ResponseStatus {
        return .{.code = 501, .msg = "Not Implemented"};
    }

    /// # 5xx: Server Error Responses
    /// - Server received an invalid response from the upstream server.
    pub fn badGateway() ResponseStatus {
        return .{.code = 502, .msg = "Bad Gateway"};
    }

    /// # 5xx: Server Error Responses
    /// - Server is not ready to handle the request i.e., down for maintenance.
    pub fn serviceUnavailable() ResponseStatus {
        return .{.code = 503, .msg = "Service Unavailable"};
    }

    /// # 5xx: Server Error Responses
    /// - Server did not get a response in time from the upstream server.
    pub fn gatewayTimeout() ResponseStatus {
        return .{.code = 504, .msg = "Gateway Timeout"};
    }

    /// # 5xx: Server Error Responses
    /// - The HTTP version used in the request is not supported by the server.
    pub fn httpVersionNotSupported() ResponseStatus {
        return .{.code = 505, .msg = "HTTP Version Not Supported"};
    }
};

// Make sure to insert variants in alphabetic order.
pub const HeaderProperty = struct {
    pub const Name = enum {
        Connection,
        @"Content-Type",
        @"Content-Length"
    };

    pub const Value = enum {
        Closed,
        @"Keep-Alive"
    };
};

const HeaderValue = union(enum) { Number: usize, Static: Str, Dynamic: Str };

/// # HTTP/1.1 Response Header Structure
pub const Headers = struct {
    /// # Http Header of a `name` and `value` Pair
    pub const Property = meta.Tuple(&.{[]const u8, []const u8});

    offset: usize = 0,
    name: [24]Str,
    value: [24]HeaderValue,
    // ↑ Predefined list of headers, where:
    // - Entries at even indices are header names
    // - Entries at odd indices are the corresponding values.

    /// # Returns the Total Header Count
    pub fn count(self: *const Headers) usize { return self.offset; }

    /// # Frees Heap Allocated Header Values
    pub fn free(self: *const Headers, heap: Allocator) void {
        for (0..self.offset) |i| {
            switch(self.value[i]) {
                .Number => {}, .Static => {}, .Dynamic => |v| heap.free(v)
            }
        }
    }

    /// # Returns Formatted HTTP/1.1 Response Response Header Fields
    /// **Remarks:** Since we fully control the generated headers, a buffer
    /// overflow indicates that we are exceeding the `~12KB` header limits.
    pub fn toString(self: *const Headers, buff: []u8) ![]u8 {
        var offset: usize = 0;
        const fmt_str = "{s}: {s}\r\n";
        const fmt_num = "{s}: {d}\r\n";

        for (0..self.offset) |i| {
            const n = self.name[i];
            const src = buff[offset..];

            offset += blk: {
                switch(self.value[i]) {
                    .Number => |v| {
                        const prop = try fmt.bufPrint(src, fmt_num, .{n, v});
                        break :blk prop.len;
                    },
                    .Static, .Dynamic => |v| {
                        const prop = try fmt.bufPrint(src, fmt_str, .{n, v});
                        break :blk prop.len;
                    }
                }
            };
        }

        return buff[0..offset];
    }

    /// # Returns the Header Value
    /// **Remarks:** In cases of duplicate headers, only the first one is
    /// returned and the value of the given `name` is case in-sensitive.
    pub fn get(self: *const Headers, name: Str) ?Str {
        for (0..self.offset) |i| {
            if (ascii.eqlIgnoreCase(name, self.name[i])) {
                return switch(self.value[i]) {
                    .Static => |v| v, .Dynamic => |v| v
                };
            }
        }
        return null;
    }

    // pub fn set() void {}

    // pub fn setAt() void {}

    /// # Adds a New Header Field
    /// **Remarks:** Use `addDyn()` when `value` is a heap allocated slice.
    ///
    /// - `name` - Either one of `HeaderProperty.Name` or `[]const u8`
    /// - `value` - Either one of `HeaderProperty.Value` or `[]const u8`
    pub fn add(self: *Headers, name: anytype, value: anytype) void {
        switch (@TypeOf(name)) {
            HeaderProperty.Name => self.name[self.offset] = @tagName(name),
            else => {
                switch (@typeInfo(@TypeOf(name))) {
                    .pointer => |p| {
                        const child_info = @typeInfo(p.child);
                        if (p.size == .one
                            and p.is_const == true
                            and child_info == .array
                            and child_info.array.child == u8)
                        {
                            self.name[self.offset] = name[0..];
                        } else {
                            @compileError("Invalid Header Name");
                        }
                    },
                    else => @compileError("Invalid Header Name")
                }
            }
        }

        switch (@TypeOf(value)) {
            usize => {
                const v = HeaderValue {.Number = value};
                self.value[self.offset] = v;
            },
            HeaderProperty.Value => {
                const v = HeaderValue {.Static = @tagName(value)};
                self.value[self.offset] = v;
            },
            else => {
                switch (@typeInfo(@TypeOf(value))) {
                    .pointer => |p| {
                        const child_info = @typeInfo(p.child);
                        if (p.size == .one
                            and p.is_const == true
                            and child_info == .array
                            and child_info.array.child == u8)
                        {
                            const v = HeaderValue {.Static = value[0..]};
                            self.value[self.offset] = v;
                        } else {
                            @compileError("Invalid Header Value");
                        }
                    },
                    else => @compileError("Invalid Header Value")
                }
            }
        }

        self.offset += 1;
    }

    /// # Adds a New Header Field
    /// **Remarks:** Pointer to the `value` will be freed automatically.
    pub fn addDyn(self: *Headers, name: Str, value: Str) void {
        self.name[self.offset] = name;
        self.value[self.offset] = HeaderValue {.Dynamic = value};
        self.offset += 1;
    }

    /// # Multiple Header Properties
    /// **Remarks:** Make sure to only pass static slices.
    pub fn addMany(self: *Headers, properties: []const Property) !void {
        for (properties) |property| {
            self.name[self.offset] = property.@"0";
            self.value[self.offset] = HeaderValue {.Static = property.@"1"};
            self.offset += 1;
        }
    }

    // pub fn remove() void {}

    // pub fn removeAt() void {}

    /// # Returns the Duplicate Header Values
    /// - `len` - Return up to the give number of duplicate headers.
    pub fn getDup(
        self: *const Request,
        comptime len: usize,
        name: Str
    ) ?[len]?Str {
        var offset: usize = 0;
        var headers = [_]?Str { null } ** len;

        for (0..self.offset) |i| {
            if (ascii.eqlIgnoreCase(name, self.name[i])) {
                headers[offset] = switch(self.value[i]) {
                    .Static => |v| v, .Dynamic => |v| v
                };

                offset += 1;
            }
        }

        return if (offset == 0) null
        else headers;
    }

    /// # Returns All Header Names
    pub fn getHeaderNames(self: *const Request) []const Str {
        return self.name[0..self.offset];
    }
};

pub const Payload = struct {
    pub fn static(status: ResponseStatus, data: ?Str) Response {
        return .{
            .status = status,
            .src = if (data) |d| SrcData {.Static = d} else .Empty,
            .len = if (data) |d| d.len else 0,
        };
    }

    pub fn dynamic(status: ResponseStatus, data: ?Str) Response {
        return .{
            .status = status,
            .src = if (data) |d| SrcData {.Dynamic = d} else .Empty,
            .len = if (data) |d| d.len else 0,
        };
    }
};
