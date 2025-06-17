//! # Global Heap Memory Allocator
//! - Provides a singleton memory allocator for general use cases

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const process = std.process;

const Interface = enum { gpa, malloc, testing };

const SingletonObject = struct {
    gpa_mem: std.heap.GeneralPurposeAllocator(.{}),
    allocator: ?mem.Allocator = null,
    interface: Interface = .gpa
};

var so: ?SingletonObject = null;

const Self = @This();

/// # Initializes the Global Allocator
pub fn init() void {
    if (Self.so != null) @panic("Initialize Only Once Per Process!");
    Self.so = .{.gpa_mem = std.heap.DebugAllocator(.{}).init};
    Self.so.?.allocator = Self.so.?.gpa_mem.allocator();
}

/// # Destroys the Global Allocator
pub fn deinit() void {
    switch (Self.iso().gpa_mem.deinit()) {
        .ok => process.exit(0), .leak => process.exit(1)
    }
}

/// # Returns Internal Static Object
pub fn iso() *SingletonObject { return &Self.so.?; }

/// # Resets Memory Allocator
/// - Overwrites to default GPA allocator
pub fn setDefault() void {
    const sop = Self.iso();
    sop.allocator = sop.gpa_mem.allocator();
    sop.interface = .gpa;
}

/// # Resets Memory Allocator
/// - Overwrites to Zig's testing allocator for unit test
pub fn setTestingAllocator() void {
    const sop = Self.iso();
    sop.allocator = std.testing.allocator;
    sop.interface = .testing;
}

/// # Resets Memory Allocator
/// - Overwrites to C's Standard Library allocator `malloc`
pub fn setMalloc() void {
    const sop = Self.iso();
    sop.allocator = std.heap.c_allocator;
    sop.interface = .malloc;
}

/// # Returns Allocator Interface
pub fn heap() mem.Allocator { return Self.so.?.allocator.?; }

/// # Returns the Allocator Interface Pointer
pub fn heapPtr() *mem.Allocator { return &Self.so.?.allocator.?; }

/// # Returns Underlying Allocator Interface Name
pub fn which() Interface { return Self.so.?.interface; }
