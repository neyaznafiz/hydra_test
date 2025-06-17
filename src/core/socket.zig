//! # High Level Socket Interface
//! - Handles multiple types of socket connections

const std = @import("std");
const net = std.net;
const log = std.log;
const debug = std.debug;
const linux = std.os.linux;
const Address = net.Address;

const utils = @import("./utils.zig");


const AddrFamily = enum(u32) {
  	/// Local communication
  	UNIX = linux.AF.UNIX,
  	/// IPv4 Internet protocols
  	INET = linux.AF.INET,
  	/// IPv6 Internet protocols
  	INET6 = linux.AF.INET6
};

const SockType = enum(u32) {
  	/// Sequenced, reliable, connection-oriented byte streams
  	STREAM = linux.SOCK.STREAM,
  	/// Connection less, unreliable datagrams of fixed max length
  	DGRAM = linux.SOCK.DGRAM,
  	/// Raw protocol interface
  	RAW = linux.SOCK.RAW
};

const Protocol = enum(u32) {
	///  Specifies the TCP protocol
	TCP = linux.IPPROTO.TCP,
	///  Specifies the UDP protocol
	UDP = linux.IPPROTO.UDP
};

pub const Socket = struct {
  	fd: linux.socket_t,

	/// # Creates a new socket connection
  	pub fn new(domain: AddrFamily, @"type": SockType, proto: Protocol) Socket {
		const d = @intFromEnum(domain);
		const t = @intFromEnum(@"type");
		const p = @intFromEnum(proto);

    	// See - https://man7.org/linux/man-pages/man2/socket.2.html
    	const socket_fd = linux.socket(d, t, p);
		return .{.fd = @intCast(socket_fd)};
  	}

  	pub fn close(self: *const Socket) void {
    	debug.assert(linux.close(self.fd) == 0);
  	}

	/// # Creates an IPv4 Address
  	pub fn Ipv4(host: []const u8, port: u16) !Address {
    	const address = try Address.parseIp4(host, port);
    	return address;
  	}

	/// # Creates an IPv6 Address
  	pub fn Ipv6(host: []const u8, port: u16) !Address {
    	const address = try Address.parseIp6(host, port);
    	return address;
  	}

	/// # TCP Socket Handler
	pub const Tcp = struct {
		const KeepAlive = struct { count: u32, idle: u32, interval: u32 };

		/// # Creates a server on a newly created TCP socket
		/// - `backlog` - Maximum number of queued (pending) connections
  		pub fn serveOn(
			tcp: *const Socket,
			addr: Address,
			backlog: u31,
			keepalive: KeepAlive
		) !void {
			// See - https://man7.org/linux/man-pages/man7/socket.7.html
			//
			// Debug Example:
			//
			// const value = @as(u32, 0);
			// var opt_val = std.mem.toBytes(value);
			// var opt_len = @as(u32, @sizeOf(u32));
			// const sock_opt = linux.getsockopt(
			//     tcp.fd,
            //     linux.SOL.SOCKET,
			//     linux.SO.KEEPALIVE,
			//     &opt_val,
			//     &opt_len
			// );
			// if (sock_opt != 0) {
			//     utils.syscallError(
			//         @bitCast(@as(u32, @truncate(sock_opt))),
			//         @src()
			//     );
			// }
			//
			// debug.print(
			//     "Socket option value: {any} len: {}\n",
			//     .{opt_val, opt_len}
			// );

			// Enable sending of keep-alive messages (connection-oriented)
			const so_keepalive = linux.setsockopt(
				tcp.fd,
				linux.SOL.SOCKET,
				linux.SO.KEEPALIVE,
				&std.mem.toBytes(@as(u32, 1)),
                @sizeOf(u32)
			);
			debug.assert(so_keepalive == 0);

			// Sets the following socket option for this socket
			// - cat /proc/sys/net/ipv4/tcp_keepalive_probes
			// - cat /proc/sys/net/ipv4/tcp_keepalive_time
			// - cat /proc/sys/net/ipv4/tcp_keepalive_intvl
			// Above options shouldn't be used in code intended to be portable!

			// The maximum number of keep-alive probes
			// TCP should send before dropping the connection
			const tcp_keepcnt = linux.setsockopt(
				tcp.fd,
				linux.IPPROTO.TCP,
				linux.TCP.KEEPCNT,
                &std.mem.toBytes(keepalive.count),
                @sizeOf(u32)
			);
			debug.assert(tcp_keepcnt == 0);

			// The connection needs to remain idle (in seconds)
			// Before TCP starts sending keepalive probes
			const tcp_keepidle = linux.setsockopt(
				tcp.fd,
				linux.IPPROTO.TCP,
				linux.TCP.KEEPIDLE,
				&std.mem.toBytes(keepalive.idle),
                @sizeOf(u32)
			);
			debug.assert(tcp_keepidle == 0);

			// The Time between individual keepalive probes (in seconds)
			const tcp_keepintvl = linux.setsockopt(
				tcp.fd,
				linux.IPPROTO.TCP,
				linux.TCP.KEEPINTVL,
				&std.mem.toBytes(keepalive.interval),
                @sizeOf(u32)
			);
			debug.assert(tcp_keepintvl == 0);

			// Allows reuse of local addresses supplied in a `bind()`
			const so_reuseaddr = linux.setsockopt(
				tcp.fd,
				linux.SOL.SOCKET,
				linux.SO.REUSEADDR,
				&std.mem.toBytes(@as(u32, 1)),
                @sizeOf(u32)
			);
			debug.assert(so_reuseaddr == 0);

            // Allows multiple sockets to be bound to an identical address
			// const so_reuseport = linux.setsockopt(
			// tcp.fd,
			//     linux.SOL.SOCKET,
			//     linux.SO.REUSEPORT,
			//     &std.mem.toBytes(@as(u32, 1)),
            //     @sizeOf(u32)
			// );
			// debug.assert(so_reuseport == 0);

			// Disables Nagle's algorithm
			const tcp_nodelay = linux.setsockopt(
				tcp.fd,
				linux.IPPROTO.TCP,
				linux.TCP.NODELAY,
				&std.mem.toBytes(@as(u32, 1)),
                @sizeOf(u32)
			);
			debug.assert(tcp_nodelay == 0);

            // `l_linger` in seconds
            const Lingure = struct { l_onoff: i32, l_linger: i32 };
            const lingure = Lingure {.l_onoff = 1, .l_linger = 15};

			// Waits until all queued messages for the socket have been -
			// Successfully sent or the `l_linger` timeout has been reached
        	const so_linger = linux.setsockopt(
            	tcp.fd,
				linux.SOL.SOCKET,
				linux.SO.LINGER,
				&std.mem.toBytes(@as(Lingure, lingure)),
                @sizeOf(Lingure)
			);
			debug.assert(so_linger == 0);

    		// See - https://man7.org/linux/man-pages/man2/bind.2.html
    		const rv_1 = linux.bind(tcp.fd, &addr.any, addr.getOsSockLen());
    		if (rv_1 != 0) {
      			const err_code = @as(u32, @truncate(rv_1));
      			utils.syscallError(@bitCast(err_code), @src());
      			std.process.exit(1);
    		}

    		// See - https://man7.org/linux/man-pages/man2/listen.2.html
    		const rv_2 = linux.listen(tcp.fd, backlog);
    		if (rv_2 != 0) {
      			const err_code = @as(u32, @truncate(rv_2));
      			utils.syscallError(@bitCast(err_code), @src());
      			std.process.exit(1);
    		}
  		}

		// TODO: for connecting client to remote TCP server
  		// pub fn connectTo() void { }
	};
};
