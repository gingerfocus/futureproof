const std = @import("std");
const wgpu = @import("wgpu");

// Returns the file contents, loaded from the file in debug builds and
// compiled in with release builds.  alloc must be an arena allocator,
// because otherwise there will be a leak.
pub fn file_contents(alloc: std.mem.Allocator, comptime name: []const u8) ![]const u8 {
    // switch (std.builtin.mode) {
    //     .Debug => {
    const file = try std.fs.cwd().openFile(name, .{});
    const size = try file.getEndPos();
    const buf = try alloc.alloc(u8, size);
    _ = try file.readAll(buf);
    return buf;
    //     },
    //     .ReleaseSafe, .ReleaseFast, .ReleaseSmall => {
    //         const f = comptime @embedFile("../" ++ name);
    //         return f[0..];
    //     },
    // }
}

pub fn makeShader(
    alloc: std.mem.Allocator,
    device: *wgpu.Device,
    comptime file: []const u8,
    stage: wgpu.ShaderStage,
) !*wgpu.ShaderModule {
    return device.createShaderModule(&wgpu.shaderModuleGLSLDescriptor(wgpu.ShaderModuleGLSLMergedDescriptor{
        .code = try file_contents(alloc, file),
        .label = file,
        .stage = stage,
    })).?;
}
