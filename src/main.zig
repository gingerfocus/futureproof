const std = @import("std");

const c = @import("c.zig");
const msgpack = @import("msgpack.zig");
const Tui = @import("Tui.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();

    if (c.glfwInit() != c.GLFW_TRUE) {
        std.debug.panic("Could not initialize glfw", .{});
    }

    var tui = try Tui.init(&alloc);
    defer tui.deinit();

    try tui.run();
}
