//! VirelaiOS shared unit test helper library (M41 TS1).
//!
//! Consolidated mock framework for host-side unit testing across kernel
//! and userspace modules. Eliminates redundant synthetic structures and
//! boilerplate implementations.

const std = @import("std");

pub const uaccess = @import("uaccess_mock.zig");
pub const task = @import("task_mock.zig");
pub const event = @import("event_mock.zig");
pub const fb = @import("fb_mock.zig");

test "helpers: root module loads all sub-helpers" {
    _ = uaccess;
    _ = task;
    _ = event;
    _ = fb;
}
