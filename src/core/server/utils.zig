//! # Utility Module

const std = @import("std");
const net = std.net;
const linux = std.os.linux;


/// # Converts Raw Peer Socket Address
pub fn peerAddress(addr: linux.sockaddr) net.Address {
    return net.Address {.any = addr};
}
