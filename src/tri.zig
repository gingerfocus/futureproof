const std = @import("std");
const wgpu = @import("wgpu");
// const bmp = @import("bmp");
const c = @import("c.zig");

const swap_chain_format = wgpu.TextureFormat.bgra8_unorm_srgb;

// width: u32,
// height: u32,
//
// device: *wgpu.Device,
// surface: *wgpu.Surface,
//
// queue: *wgpu.Queue,

// bind_group: *wgpu.BindGroup,
// uniform_buffer: wgpu.WGPUBuffer,
// char_grid_buffer: wgpu.WGPUBuffer,
//
// render_pipeline: *wgpu.RenderPipeline,
//
// preview: ?*Preview,
// blit: Blit,
//
// // We track the last few preview times; if the media is under 30 FPS,
// // then we switch to tiled rendering
// dt: [5]i64,
// dt_index: usize,

// alloc: std.mem.Allocator,

// pub fn init(alloc: std.mem.Allocator, window: *c.GLFWwindow, font: *const ft.Atlas) !Self {
// pub fn clear_preview(self: *Self, alloc: *std.mem.Allocator) void {
// pub fn update_preview(self: *Self, alloc: *std.mem.Allocator, s: Shader) !void {
// pub fn redraw(self: *Self, total_tiles: u32) void {
//
// pub fn deinit(self: *Self, alloc: *std.mem.Allocator) void {
// pub fn resize_swap_chain(self: *Self, width: u32, height: u32) void {

// const output_extent = wgpu.Extent3D{
//     .width = 640,
//     .height = 480,
//     .depth_or_array_layers = 1,
// };
// const output_bytes_per_row = 4 * output_extent.width;
// const output_size = output_bytes_per_row * output_extent.height;
//
// fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
//     std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
//     const complete: *bool = @ptrCast(@alignCast(userdata1));
//     complete.* = true;
// }

// Based off of headless triangle example from https://github.com/eliemichel/LearnWebGPU-Code/tree/step030-headless

const Data = struct {
    device: *wgpu.Device,
    surface: *wgpu.Surface,
    queue: *wgpu.Queue,
    configured: bool = false,
};

// const width: c_int = 640;
// const height: c_int = 480;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const instance = wgpu.Instance.create(null).?;
    defer instance.release();

    _ = c.glfwInit();

    // c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    // c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

    const window = c.glfwCreateWindow(640, 480, "thing", null, null);

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
    defer device.release();

    const queue = device.getQueue().?;
    defer queue.release();

    const data = try alloc.create(Data);
    defer alloc.destroy(data);
    data.* = Data{
        .device = device,
        .surface = surface,
        .queue = queue,
    };

    _ = c.glfwSetWindowUserPointer(window, data);
    _ = c.glfwSetFramebufferSizeCallback(window, resize);


    // const target_texture = device.createTexture(&wgpu.TextureDescriptor{
    //     .label = wgpu.StringView.fromSlice("Render texture"),
    //     .size = output_extent,
    //     .format = swap_chain_format,
    //     .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.copy_src,
    // }).?;
    // defer target_texture.release();
    //
    // const target_texture_view = target_texture.createView(&wgpu.TextureViewDescriptor{
    //     .label = wgpu.StringView.fromSlice("Render texture view"),
    //     .mip_level_count = 1,
    //     .array_layer_count = 1,
    // }).?;

    const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./tri.wgsl"),
        .label = "tri.wgsl",
    })).?;
    defer shader_module.release();

    // var caps: wgpu.SurfaceCapabilities = undefined;
    // _ = surface.getCapabilities(adapter, &caps);

    const render_pipeline_layout =
        device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("pipeline layout"),
            .bind_group_layouts = &[_]*wgpu.BindGroupLayout{},
            .bind_group_layout_count = 0,
        }).?;

    // const staging_buffer = device.createBuffer(&wgpu.BufferDescriptor{
    //     .label = wgpu.StringView.fromSlice("staging_buffer"),
    //     .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
    //     .size = output_size,
    //     .mapped_at_creation = @as(u32, @intFromBool(false)),
    // }).?;
    // defer staging_buffer.release();

    const color_targets = &[_]wgpu.ColorTargetState{
        wgpu.ColorTargetState{
            .format = swap_chain_format,
            .blend = &wgpu.BlendState.replace,
        },
    };

    const pipeline = device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .vertex = wgpu.VertexState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
        },
        .primitive = wgpu.PrimitiveState{
            .topology = wgpu.PrimitiveTopology.triangle_list,
            .cull_mode = .back,
        },
        .fragment = &wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = color_targets.ptr,
        },
        .multisample = wgpu.MultisampleState{},
        .label = wgpu.StringView.fromSlice("render pipeline"),
        .layout = render_pipeline_layout,
    }).?;
    defer pipeline.release();

    c.glfwShowWindow(window);
    c.glfwFocusWindow(window);

    var wi: c_int = undefined;
    var hi: c_int = undefined;
    c.glfwGetWindowSize(window, &wi, &hi);
    std.log.info("window size {d} {d}\n", .{ wi, hi });

    surface.configure(&(wgpu.SurfaceConfiguration){
        .width = @intCast(wi),
        .height = @intCast(hi),
        .device = device,
        .format = swap_chain_format,
    });

    var textureresult: wgpu.SurfaceTexture = undefined;
    surface.getCurrentTexture(&textureresult);
    const texture = textureresult.texture.?;
    const view = texture.createView(null).?;


    while (true) { // Mock main "loop"
        c.glfwWaitEvents();
        std.log.info("Ticking", .{});

        // if (data.configured) {
        std.log.info("Configured", .{});
        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
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
        const render_pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
            .label = wgpu.StringView.fromSlice("render pass"),
            .color_attachments = &color_attachments,
            .color_attachment_count = color_attachments.len,
            .depth_stencil_attachment = null,
        }).?;

        render_pass.setPipeline(pipeline);
        render_pass.draw(3, 1, 0, 0);
        render_pass.end();
        // render_pass.release(); // needs to be called before finish

        const cmds = encoder.finish(null).?;
        queue.submit(&.{cmds});

        _ = surface.present();

        // --------------------

        // const next_texture = target_texture_view;
        //
        // const color_attachments = &[_]wgpu.ColorAttachment{wgpu.ColorAttachment{
        //     .view = next_texture,
        //     .clear_value = wgpu.Color{},
        // }};
        // const render_pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
        //     .color_attachment_count = color_attachments.len,
        //     .color_attachments = color_attachments.ptr,
        // }).?;
        //
        // render_pass.setPipeline(pipeline);
        // render_pass.draw(3, 1, 0, 0);
        // render_pass.end();
        //
        // // The render pass has to be released after .end() or otherwise we'll crash on queue.submit
        // // https://github.com/gfx-rs/wgpu-native/issues/412#issuecomment-2311719154
        // render_pass.release();
        //
        // defer next_texture.release();

        // const img_copy_src = wgpu.TexelCopyTextureInfo{
        //     .origin = wgpu.Origin3D{},
        //     .texture = target_texture,
        // };
        // const img_copy_dst = wgpu.TexelCopyBufferInfo{
        //     .layout = wgpu.TexelCopyBufferLayout{
        //         .bytes_per_row = output_bytes_per_row,
        //         .rows_per_image = output_extent.height,
        //     },
        //     .buffer = staging_buffer,
        // };
        //
        // encoder.copyTextureToBuffer(&img_copy_src, &img_copy_dst, &output_extent);
        //
        // const command_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{
        //     .label = wgpu.StringView.fromSlice("Command Buffer"),
        // }).?;
        // defer command_buffer.release();
        //
        // queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer});
        //
        // var buffer_map_complete = false;
        // _ = staging_buffer.mapAsync(wgpu.MapModes.read, 0, output_size, wgpu.BufferMapCallbackInfo{
        //     .callback = handleBufferMap,
        //     .userdata1 = @ptrCast(&buffer_map_complete),
        // });
        // instance.processEvents();
        // while (!buffer_map_complete) {
        //     instance.processEvents();
        // }
        // _ = device.poll(true, null);
        //
        // const buf: [*]u8 = @ptrCast(@alignCast(staging_buffer.getMappedRange(0, output_size).?));
        // defer staging_buffer.unmap();
        //
        // const output = buf[0..output_size];
        // try bmp.write24BitBMP("examples/output/triangle.bmp", output_extent.width, output_extent.height, output);
        // }
        std.time.sleep(100000);
    }
}

// -----------------------------------------------------------------------------

export fn resize(w: ?*c.GLFWwindow, width: c_int, hieght: c_int) void {
    const ptr = c.glfwGetWindowUserPointer(w).?;
    const data: *Data = @ptrCast(@alignCast(ptr));

    std.log.info("resize {d} {d}\n", .{ width, hieght });

    data.surface.configure(&(wgpu.SurfaceConfiguration){
        .width = @intCast(width),
        .height = @intCast(hieght),
        .device = data.device,
        .format = swap_chain_format,
    });
    data.configured = true;
}
