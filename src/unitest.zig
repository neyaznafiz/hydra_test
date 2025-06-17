//! # Unit Testing for Entire Codebase
//! **Remarks:** Following imports have one or more unit tests.
//! For code coverage keep this updated and follow the instructions.
//!
//! - `@import("dir/file.zig")` will run top-level unit tests within that file
//! - Add `test { testing.refAllDecls(@This()); }` at the bottom of a `file.zig`
//! - This ↑ will run nested unit tests that are defined in the submodules of ↑
//! - Comment out imported module ↓ to skip unit tests for any specific reason!

const Mem = @import("./core/hemloc.zig");
test "Testing Allocator Initialization" {
    Mem.init();                // Instantiating singleton memory allocator
    defer Mem.deinit();        // Detects any memory leaks on exit
    Mem.setTestingAllocator(); // Resets to testing allocator
}

comptime {
    //##########################################################################
    //# CORE CODE COVERAGE ----------------------------------------------------#
    //##########################################################################
    _ = @import("./core/server/http/parser.zig");

    //##########################################################################
    //# App CODE COVERAGE -----------------------------------------------------#
    //##########################################################################
    
}
