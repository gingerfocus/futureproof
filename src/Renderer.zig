const std = @import("std");
const wgpu = @import("wgpu");
const c = @import("c.zig");
const FtAtlas = @import("FtAtlas.zig");

width: u32,
height: u32,

instance: *wgpu.Instance,

device: *wgpu.Device,
surface: *wgpu.Surface,

queue: *wgpu.Queue,

// bind_group: *wgpu.BindGroup,
// uniform_buffer: wgpu.WGPUBuffer,
// char_grid_buffer: wgpu.WGPUBuffer,

pipeline: ?*wgpu.RenderPipeline,
shader: ?*wgpu.ShaderModule,
// preview: ?*Preview,
// blit: Blit,

// We track the last few preview times; if the media is under 30 FPS,
// then we switch to tiled rendering
// dt: [5]i64,
// dt_index: usize,

configured: bool = false,
alloc: std.mem.Allocator,


const Self = @This();

pub fn init(alloc: std.mem.Allocator, window: *c.GLFWwindow, font: *const FtAtlas) !Self {
    _ = font;
    const instance = wgpu.Instance.create(null).?;

    const wayland_display = c.glfwGetWaylandDisplay();
    const wayland_surface = c.glfwGetWaylandWindow(window);

    const fromWaylandSurface: wgpu.SurfaceSourceWaylandSurface = .{
        .display = @ptrCast(wayland_display.?),
        .surface = @ptrCast(wayland_surface.?),
    };

    const surfaceDescriptor: wgpu.SurfaceDescriptor = .{
        .next_in_chain = &fromWaylandSurface.chain,
        .label = wgpu.StringView.fromSlice("wayland surface"),
    };
    const surface = instance.createSurface(&surfaceDescriptor).?;

    const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
        .compatible_surface = surface,
    }, 0);
    const adapter: *wgpu.Adapter = switch (adapter_request.status) {
        .success => adapter_request.adapter.?,
        else => return error.NoAdapter,
    };
    defer adapter.release();

    const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
        .required_limits = null,
    }, 0);
    const device: *wgpu.Device = switch (device_request.status) {
        .success => device_request.device.?,
        else => return error.NoDevice,
    };

    const queue = device.getQueue().?;

    var renderer =Self{
        .instance = instance,

        // .window = window,
        .device = device,
        .surface = surface,
        .queue = queue,

        .pipeline = null,
        .shader = null,

        // .font = font,
        .width = undefined,
        .height = undefined,

        .alloc = alloc,
    };

    var wi: c_int = undefined;
    var hi: c_int = undefined;
    c.glfwGetWindowSize(window, &wi, &hi);

    // std.log.info("window size {d} {d}\n", .{ wi, hi });
    renderer.resize(@intCast(wi), @intCast(hi));

    return renderer;
}

pub fn redraw(self: *Self, total_tiles: u32) void {
    _ = total_tiles;

    // only redraw if we have a pipeline
    const pipeline = self.pipeline orelse return;

    var textureresult: wgpu.SurfaceTexture = undefined;
    self.surface.getCurrentTexture(&textureresult);
    const texture = textureresult.texture.?;
    defer texture.release();
    defer texture.destroy();

    const view = texture.createView(null).?;
    defer view.release();

    const encoder = self.device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
        .label = wgpu.StringView.fromSlice("Command Encoder"),
    }).?;
    defer encoder.release();

    const color_attachments = [_]wgpu.ColorAttachment{
        wgpu.ColorAttachment{
            .view = view,
            .load_op = wgpu.LoadOp.load,
            .clear_value = wgpu.Color{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 },
            .store_op = wgpu.StoreOp.store,
        },
    };
    const rpass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
        .label = wgpu.StringView.fromSlice("render pass"),
        .color_attachments = &color_attachments,
        .color_attachment_count = color_attachments.len,
        .depth_stencil_attachment = null,
    }).?;
    defer rpass.release();

    rpass.setPipeline(pipeline);
    rpass.draw(3, 1, 0, 0);
    rpass.end();

    const cmds = encoder.finish(null).?;
    self.queue.submit(&.{cmds});

    _ = self.surface.present();

    // std.time.sleep(100000);
}

pub fn deinit(self: Self) void {
    if (self.pipeline) |p| p.release();
    if (self.shader) |s| s.release();

    self.surface.release();
    self.queue.release();
    self.device.release();
    self.instance.release();
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    std.log.info("resize {d} {d}\n", .{ width, height });

    self.surface.configure(&(wgpu.SurfaceConfiguration){
        .width = @intCast(width),
        .height = @intCast(height),
        .device = self.device,
        .format = .bgra8_unorm_srgb,
    });
    self.configured = true;
}

pub fn clearPreview(self: *Self) void {
    if (self.pipeline) |p| p.release();
    if (self.shader) |s| s.release();
    self.pipeline = null;
    self.shader = null;
}

// const Shader = @import("shaderc.zig").Shader;

pub fn setPreview(self: *Self) !void {
    self.clearPreview();

    const shader = self.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./tri.wgsl"),
        .label = "tri.wgsl",
    })).?;

    // var caps: wgpu.SurfaceCapabilities = undefined;
    // _ = surface.getCapabilities(adapter, &caps);

    const render_pipeline_layout =
        self.device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("pipeline layout"),
            .bind_group_layouts = &[_]*wgpu.BindGroupLayout{},
            .bind_group_layout_count = 0,
        }).?;

    const color_targets = &[_]wgpu.ColorTargetState{
        wgpu.ColorTargetState{
            .format = .bgra8_unorm_srgb,
            .blend = &wgpu.BlendState.replace,
        },
    };

    const pipeline = self.device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .vertex = wgpu.VertexState{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
        },
        .primitive = wgpu.PrimitiveState{
            .topology = wgpu.PrimitiveTopology.triangle_list,
            .cull_mode = .back,
        },
        .fragment = &wgpu.FragmentState{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = color_targets.ptr,
        },
        .multisample = wgpu.MultisampleState{},
        .label = wgpu.StringView.fromSlice("render pipeline"),
        .layout = render_pipeline_layout,
    }).?;

    self.pipeline = pipeline;
    self.shader = shader;
}
