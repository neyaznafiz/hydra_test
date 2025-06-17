//! # App Endpoints - Declare all your URL endpoints here
//! - See - `docs/agent.html` to get an in-depth overview

const std = @import("std");

const route = @import("./core/route.zig");
const apply = route.Handle.apply;


//##############################################################################
//# CAUTION: ONLY PUBLIC DECLARATIONS ARE EXPOSED AS APP ENDPOINTS AT COMPILE! #
//##############################################################################

/// # Serves Generic Web Pages
pub const generic = route.lane(.WebPage, "/")
    .mount(.{.capacity = 512})
    .guard(&[_]route.Guard {
        .{.GET, apply(&@import("./backend/api/foo.zig").foo)},
        .{.GET, apply(&@import("./backend/api/foo.zig").foo)},
    })
    .agent(&[_]route.Agent {
        .{
            .GET, "",
            apply(&@import("./builtins/webpage.zig").serve)
        },
        .{
            .GET, "home2",
            apply(&@import("./builtins/webpage.zig").serve)
        },
        .{
            .GET, "home",
            apply(&@import("./builtins/webpage.zig").serve)
        },
    });

/// # Serves App Data
pub const api = route.lane(.DataApi, "/api/")
    .mount(.{.capacity = 512})
    .guard(&[_]route.Guard {
        .{.GET, apply(&@import("./backend/api/foo.zig").foo)},
    })
    .agent(&[_]route.Agent {
        .{
            .POST, "user/add",
            apply(&@import("./backend/api/foo.zig").foo)
        },
    });
