const std = @import("std");

const c = @import("c.zig");

const Window = @This();
const Self = @This();

window: *c.GLFWwindow,

pub fn init(width: c_int, height: c_int, name: [*c]const u8) !Self {
    // c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    // c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

    const window = c.glfwCreateWindow(width, height, name, null, null);
    // c.glfwSetWindowSizeLimits(window, 640, 480, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);

    // Open the window!
    if (window) |w| {
        return Window{ .window = w };
    } else {
        var err_str: [*c]u8 = null;
        const err = c.glfwGetError(@ptrCast(&err_str));
        std.debug.panic("Failed to open window: {?} ({*})", .{ err, err_str });
    }
}

pub fn deinit(self: *Self) void {
    c.glfwDestroyWindow(self.window);
}

pub fn closing(self: *Self) bool {
    return c.glfwWindowShouldClose(self.window) != 0;
}

pub fn getWidth(self: *Self) u32 {
    var w_width: c_int = undefined;
    c.glfwGetWindowSize(self.window, &w_width, null);
    return @as(u32, @intCast(w_width));
}

pub fn set_callbacks(
    self: *Self,
    size_cb: c.GLFWframebuffersizefun,
    key_cb: c.GLFWkeyfun,
    mouse_button_cb: c.GLFWmousebuttonfun,
    mouse_pos_cb: c.GLFWcursorposfun,
    scroll_cb: c.GLFWscrollfun,
    data: ?*anyopaque,
) void {
    // Attach the TUI handle to the window so we can extract it
    _ = c.glfwSetWindowUserPointer(self.window, data);

    // Resizing the window
    _ = c.glfwSetFramebufferSizeCallback(self.window, size_cb);

    // User input
    _ = c.glfwSetKeyCallback(self.window, key_cb);
    _ = c.glfwSetMouseButtonCallback(self.window, mouse_button_cb);
    _ = c.glfwSetCursorPosCallback(self.window, mouse_pos_cb);
    _ = c.glfwSetScrollCallback(self.window, scroll_cb);
}
