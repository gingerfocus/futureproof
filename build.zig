const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "futureproof",
        // .root_source_file = b.path("src/main.zig"),
        .root_source_file = b.path("src/tri.zig"),
        .target = target,
        .optimize = optimize,
    });
    // exe.addCSourceFile(.{
    //     .file = b.path("vendor/glfw3webgpu/glfw3webgpu.c"),
    // });
    // exe.addIncludePath(b.path("vendor/glfw3webgpu"));

    exe.linkLibC();
    exe.linkLibCpp();

    // Libraries!
    exe.linkSystemLibrary2("glfw3", .{});
    exe.linkSystemLibrary2("freetype2", .{});
    exe.linkSystemLibrary2("stdc++", .{}); // needed for shaderc

    // --------- wgpu -----------------------------------------
    // exe.addLibraryPath(b.path("vendor/wgpu"));
    // exe.linkSystemLibrary("wgpu_native");
    // exe.addIncludePath(b.path("vendor"));

    const wgpu = b.dependency("wgpu-native", .{
        .target = target,
        .optimize = optimize,
        .link_mode = .static,
    });
    // exe.root_module.addImport("wgpu", wgpu.module("wgpu-c"));
    exe.root_module.addImport("wgpu", wgpu.module("wgpu"));
    // ------------------------------------------------------

    // exe.addLibraryPath(b.path("vendor/shaderc/lib"));
    // exe.linkSystemLibrary("shaderc_combined");
    // exe.addIncludePath(b.path("vendor/shaderc/include/"));
    exe.linkSystemLibrary2("shaderc", .{});

    exe.addIncludePath(b.path(".")); // for "extern/futureproof.h"

    // This must come before the install_name_tool call below
    b.installArtifact(exe);

    // if (exe.target.isDarwin()) {
    //     exe.addFrameworkDir("/System/Library/Frameworks");
    //     exe.linkFramework("Foundation");
    //     exe.linkFramework("AppKit");
    // }

    // ------------------------------------------------------

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step("run", "Run the app");
    step.dependOn(&run.step);

    // ------------------------------------------------------

    const check = b.step("check", "Lsp Check Step");
    check.dependOn(&exe.step);
}
