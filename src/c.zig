const builtin = @import("builtin");

pub usingnamespace @cImport({
    // GLFW
    @cInclude("GLFW/glfw3.h");

    // FreeType
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");

    @cInclude("wgpu/wgpu.h");
    @cInclude("shaderc/shaderc.h");

    @cInclude("extern/futureproof.h");
    @cInclude("extern/preview.h");

    if (builtin.os.tag == .macos) {
        @cInclude("objc/message.h");
    }

    // if (builtin.os.tag == .linux) {
        @cInclude("wayland-client-core.h");
        @cInclude("wayland-client-protocol.h");
        @cInclude("wayland-client.h");
        // @cInclude("wayland-egl.h");

        // @cInclude("xkbcommon/xkbcommon.h");

        // @cInclude("xdg-shell-protocol.h");
    // }
});
