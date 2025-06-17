//! # HTTP/1.1 Request Parser
//! **Provides a set of utilities for parsing raw HTTP request**
//!
//! - See - https://datatracker.ietf.org/doc/html/rfc9110
//! - See - https://datatracker.ietf.org/doc/html/rfc9111
//! - See - https://datatracker.ietf.org/doc/html/rfc9112

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;

const parser = @import("../../parser.zig");

const common = @import("./common.zig");
const Method = common.Method;
const Request = common.Request;
const SpecialChar = common.SpecialChar;


const Error = error {
    UriTooLong,
    Unsupported,
    LimitExceeded,
    HeaderTooLong,
    MalformedRequest,
    InvalidMethodName,
};

pub fn parseRequest(buff: []const u8, req: *Request) !void {
    var p = parser.init(buff);
    try PeerRequest.method(&p, req);
    try PeerRequest.splitTarget(try PeerRequest.target(&p), req);
    try PeerRequest.version(&p);
    try PeerRequest.headers(&p, req);
}

pub const PeerRequest = struct {
    const max_url_len = 4000;          // Size: ~4KB
    const max_header_name_len = 256;   // Size: 256 Bytes
    const max_header_value_len = 4096; // Size: 4KB

    /// # Request Method Parser
    fn method(p: *parser, req: *Request) !void {
        const begin = p.cursor();
        while (p.peek() != null) {
            const char = p.next() catch return Error.MalformedRequest;
            switch (char) {
                SpecialChar.SP => {
                    const end = p.cursor() - 1;
                    const token = p.peekStr(begin, end) catch {
                        return Error.MalformedRequest;
                    };

                    if (mem.eql(u8, token, "GET")) {
                        req.method = .GET;
                        return;
                    }
                    else if (mem.eql(u8, token, "POST")) {
                        req.method = .POST;
                        return;
                    }
                    else if (mem.eql(u8, token, "HEAD")
                        or mem.eql(u8, token, "DELETE")
                        or mem.eql(u8, token, "CONNECT")
                        or mem.eql(u8, token, "OPTIONS")
                        or mem.eql(u8, token, "TRACE")
                        or mem.eql(u8, token, "PUT"))
                    {
                        return Error.Unsupported;
                    }
                    else {
                        return Error.InvalidMethodName;
                    }
                },
                else => {}
            }
        }

        return Error.MalformedRequest;
    }

    test method {
        const good_1 = "GET / HTTP/1.1";
        var g1 = parser.init(good_1);
        try testing.expectEqual(.GET, try method(&g1));

        const bad_1 = "";
        var b1 = parser.init(bad_1);
        try testing.expectError(Error.MalformedRequest, method(&b1));

        const bad_2 = "GTE / HTTP/1.1";
        var b2 = parser.init(bad_2);
        try testing.expectError(Error.InvalidMethodName, method(&b2));

        const bad_3 = "Some_malformed_request_buffer_by_the_hacker";
        var b3 = parser.init(bad_3);
        try testing.expectError(Error.MalformedRequest, method(&b3));

        const edge_1 = "PUT / HTTP/1.1";
        var e1 = parser.init(edge_1);
        try testing.expectError(Error.Unsupported, method(&e1));
    }

    /// # Request Target URL Parser
    /// **Remarks:** Returns the underlying buffer slice - Make sure not to
    /// exceed the buffer lifetime. Since we do not support `%` encoded URL
    /// (to keep URLs clean and readable) and all URLs are directly mapped,
    /// extensive character validation is intentionally omitted (safe).
    fn target(p: *parser) ![]const u8 {
        const begin = p.cursor();
        while (p.peek() != null) {
            const char = p.next() catch return Error.MalformedRequest;
            switch (char) {
                SpecialChar.SP => {
                    const end = p.cursor() - 1;
                    const token = p.peekStr(begin, end) catch {
                        return Error.MalformedRequest;
                    };

                    return if (token.len <= max_url_len) token
                    else Error.UriTooLong;
                },
                else => {}
            }
        }

        return Error.MalformedRequest;
    }

    test target {
        const good_1 = "/ HTTP/1.1";
        var g1 = parser.init(good_1);
        try testing.expect(mem.eql(u8, "/", try target(&g1)));

        const good_2 = "/foo/bar HTTP/1.1";
        var g2 = parser.init(good_2);
        try testing.expect(mem.eql(u8, "/foo/bar", try target(&g2)));

        const edge_1 = "/foo\tbar HTTP/1.1";
        var e1 = parser.init(edge_1);
        try testing.expect(mem.eql(u8, "/foo\tbar", try target(&e1)));

        const bad_1 = "/foo-bar";
        var b1 = parser.init(bad_1);
        try testing.expectError(Error.MalformedRequest, try target(&b1));
    }

    /// # Splits a Target into the URL and Query Parts
    /// **Remarks:** Malformed query parameters are not sanitized.
    fn splitTarget(data: []const u8, req: *Request) !void {
        if (mem.indexOf(u8, data, "?")) |pos| {
            req.url = data[0..pos];

            var iter = mem.splitAny(u8, data[pos + 1..], "&");
            while (iter.next()) |token| {
                if (req.q_offset == req.q_name.len) return Error.LimitExceeded;

                if (mem.indexOf(u8, token, "=")) |i| {
                    req.q_name[req.q_offset] = token[0..i];
                    req.q_value[req.q_offset] = token[i + 1..];
                } else {
                    return Error.MalformedRequest;
                }

                req.q_offset += 1;
            }
        } else {
            req.url = data;
        }
    }

    /// # Request Version Parser
    fn version(p: *parser) !void {
        const begin = p.cursor();
        while (p.peek() != null) {
            const char = p.next() catch return Error.MalformedRequest;
            switch (char) {
                SpecialChar.LF => {
                    const end = p.cursor() - 2;
                    if (p.peekAt(end).? != SpecialChar.CR) {
                        return Error.MalformedRequest;
                    }

                    const token = p.peekStr(begin, end) catch {
                        return Error.MalformedRequest;
                    };

                    if (mem.eql(u8, token, "HTTP/1.1")) return
                    else return Error.Unsupported;
                },
                else => {}
            }
        }

        return Error.MalformedRequest;
    }

    test version {
        const good_1 = "HTTP/1.1\r\n";
        var g1 = parser.init(good_1);
        try version(&g1);

        const edge_1 = "HTTP/1.0\n";
        var e1 = parser.init(edge_1);
        try testing.expectError(Error.Unsupported, version(&e1));

        const bad_1 = "HTTP/1.1";
        var b1 = parser.init(bad_1);
        try testing.expectError(Error.MalformedRequest, version(&b1));

        const bad_2 = "HTTP/1.1\n";
        var b2 = parser.init(bad_2);
        try testing.expectError(Error.MalformedRequest, version(&b2));

        const bad_3 = "\n";
        var b3 = parser.init(bad_3);
        try testing.expectError(Error.MalformedRequest, version(&b3));

        const bad_4 = "\r\n";
        var b4 = parser.init(bad_4);
        try testing.expectError(Error.MalformedRequest, version(&b4));
    }

    /// # Request Header Fields Parser
    pub fn headers(p: *parser, req: *Request) !void {
        var begin = p.cursor();
        while (p.peek() != null) {
            const char = p.next() catch return Error.MalformedRequest;
            switch (char) {
                SpecialChar.LF => {
                    const end = p.cursor() - 2;
                    if (p.peekAt(end).? != SpecialChar.CR) {
                        return Error.MalformedRequest;
                    }
                    const token = p.peekStr(begin, end) catch {
                        return Error.MalformedRequest;
                    };

                    try fieldLine(token, req);
                    if (try lastField(p, end)) return;

                    if (req.h_offset <= req.h_name.len) begin = p.cursor()
                    else return Error.LimitExceeded;
                },
                else => {}
            }
        }

        return Error.MalformedRequest;
    }

    fn lastField(p: *parser, offset: usize) !bool {
        const token = p.peekStr(offset, offset + 4) catch {
            return Error.MalformedRequest;
        };

        return if(mem.eql(u8, token, "\r\n\r\n")) true else false;
    }

    fn fieldLine(data: []const u8, req: *Request) !void {
        req.h_offset += 1;
        var tokens = mem.tokenizeAny(u8, data, ":");

        if (tokens.next()) |v| {
            if (v.len > max_header_name_len) return Error.HeaderTooLong;
            req.h_name[req.h_offset - 1] = mem.trim(u8, v, &ascii.whitespace);
        } else {
            return Error.MalformedRequest;
        }

        if (tokens.next()) |v| {
            if (v.len > max_header_value_len) return Error.HeaderTooLong;
            req.h_value[req.h_offset - 1] = mem.trim(u8, v, &ascii.whitespace);
        } else {
            return Error.MalformedRequest;
        }
    }

    test headers {
        const good_1 = "Host: example.com\r\nConnection: keep-alive\r\nCache-Control: max-age=0\r\nUpgrade-Insecure-Requests: 1\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7\r\nAccept-Encoding: gzip, deflate\r\nAccept-Language: en-US,en;q=0.9,bn;q=0.8\r\n\r\n";
        var g1 = parser.init(good_1);
        var rd1: Request = undefined;
        try headers(&g1, &rd1);

        std.log.warn("{d}\n", .{rd1.h_offset});

        try testing.expect(rd1.h_offset == 61);

        const bad_2 = "Host example.com\r\nCONNECTION: closed\r\nConnection: keep-alive\r\nAccept-Encoding: gzip,deflate\r\n\r\n";
        var b1 = parser.init(bad_2);
        var rd2: Request = undefined;

        try testing.expectError(
            Error.MalformedRequest, try headers(&b1, &rd2)
        );
    }
};

test { testing.refAllDecls(@This()); } // Only references public declarations
