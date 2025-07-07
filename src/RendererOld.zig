const builtin = @import("builtin");
const std = @import("std");

const c = @import("c.zig");
// const shaderc = @import("shaderc.zig");
const FtAtlas = @import("FtAtlas.zig");

const wgpu = @import("wgpu");

const Blit = @import("blit.zig").Blit;
const Preview = @import("Preview.zig");
const Shader = @import("shaderc.zig").Shader;

const Renderer = @This();
const Self = @This();

// tex: wgpu.WGPUTexture,
// tex_view: wgpu.WGPUTextureView,
// tex_sampler: wgpu.WGPUSampler,

// swap_chain: wgpu.WGPUSwapChain,
width: u32,
height: u32,

device: *wgpu.Device,
surface: *wgpu.Surface,

queue: *wgpu.Queue,

bind_group: *wgpu.BindGroup,
// uniform_buffer: wgpu.WGPUBuffer,
// char_grid_buffer: wgpu.WGPUBuffer,

render_pipeline: *wgpu.RenderPipeline,

preview: ?*Preview,
// blit: Blit,
//
// // We track the last few preview times; if the media is under 30 FPS,
// // then we switch to tiled rendering
// dt: [5]i64,
// dt_index: usize,

alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator, window: *c.GLFWwindow, font: *const FtAtlas) !Self {
    _ = font;
    const instance = wgpu.Instance.create(null).?;

    // Extract the WGPU Surface from the platform-specific window
    const platform = builtin.os.tag;
    const surface = if (platform == .macos) surf: {
        // Time to do hilarious Objective-C runtime hacks, equivalent to
        //  [ns_window.contentView setWantsLayer:YES];
        //  id metal_layer = [CAMetalLayer layer];
        //  [ns_window.contentView setLayer:metal_layer];
        const objc = @import("objc.zig");
        const darwin = @import("darwin.zig");

        const cocoa_window = darwin.glfwGetCocoaWindow(window);
        const ns_window = @as(wgpu.id, @ptrCast(@as(8, @alignCast(cocoa_window))));

        const cv = objc.call(ns_window, "contentView");
        _ = objc.call_(cv, "setWantsLayer:", true);

        const ca_metal = objc.class("CAMetalLayer");
        const metal_layer = objc.call(ca_metal, "layer");

        _ = objc.call_(cv, "setLayer:", metal_layer);

        break :surf wgpu.wgpu_create_surface_from_metal_layer(metal_layer);
    } else surf: {
        const wayland_display = c.glfwGetWaylandDisplay();
        const wayland_surface = c.glfwGetWaylandWindow(window);
        // break :surf wgpu.wgpu_create_surface_from_wayland(wayland_surface, wayland_display);

        const fromWaylandSurface: wgpu.SurfaceSourceWaylandSurface = .{
            .display = @ptrCast(wayland_display.?),
            .surface = @ptrCast(wayland_surface.?),
        };

        const surfaceDescriptor: wgpu.SurfaceDescriptor = .{
            .next_in_chain = &fromWaylandSurface.chain,
            .label = wgpu.StringView.fromSlice("wayland surface"),
        };

        break :surf instance.createSurface(&surfaceDescriptor).?;
        // break :surf wgpu.wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
    };

    std.debug.print("surface: {any}\n", .{surface});

    ////////////////////////////////////////////////////////////////////////////
    // WGPU initial setup
    const result = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
        .power_preference = .high_performance,
        .compatible_surface = surface,
        .feature_level = .compatibility,
        // .backend_type = .opengl, // .vulkan,
    }, 10000);
    const adapter = result.adapter.?;
    defer adapter.release();

    // // wgpu.wgpu_request_adapter_async(&(wgpu.WGPURequestAdapterOptions){},
    // //      2 | 4 | 8, false, adapter_cb, &adapter);

    const required_features = [_]wgpu.FeatureName{
        // wgpu.FeatureName.spirv_shader_passthrough,
        // wgpu.FeatureName.multi_draw_indirect,
    };
    const deviceresult = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
        .required_limits = null,
        // .required_limits = &.{
        //     .max_bind_groups = 1,
        // },
        .required_feature_count = required_features.len,
        .required_features = &required_features,
    }, 10000);
    if (deviceresult.message) |msg| {
        std.log.warn("Request device failed: {s}\n", .{msg});
    }
    const device = deviceresult.device orelse return error.DeviceRequestFailed;

    ////////////////////////////////////////////////////////////////////////////
    // Build the shaders using shaderc
    // const vert_spv = try shaderc.build_shader_from_file(alloc, "shaders/grid.vert");
    //
    // const descriptor = wgpu.shaderModuleWGSLDescriptor(wgpu.ShaderModuleWGSLMergedDescriptor{
    //     .code = vert_spv.ptr,
    //     .label = "vert",
    // });
    // const vert_shader = device.createShaderModule(&descriptor).?;
    // // const vert_shader = device.createShaderModuleSpirV(&.{
    // //     .source = vert_spv.ptr,
    // //     .source_size = @intCast(vert_spv.len),
    // // }).?;
    // defer vert_shader.release();
    //
    // const frag_spv = try shaderc.build_shader_from_file(alloc, "shaders/grid.frag");
    // const frag_shader = device.createShaderModuleSpirV(&.{
    //     .source = frag_spv.ptr,
    //     .source_size = @intCast(frag_spv.len),
    // }).?;
    // defer frag_shader.release();
    const text = try @import("util.zig").file_contents(alloc, "shaders/grid.wgsl");
    const shader = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = text,
        .label = "frag",
    })).?;

    ////////////////////////////////////////////////////////////////////////////
    // Upload the font atlas texture
    // const tex_size = (wgpu.Extent3D){
    //     .width = @as(u32, font.tex_size),
    //     .height = @as(u32, font.tex_size),
    //     .depth_or_array_layers = 1,
    // };
    //
    // const tex = device.createTexture(&wgpu.TextureDescriptor{
    //     .size = tex_size,
    //     .mip_level_count = 1,
    //     .sample_count = 1,
    //     .dimension = .@"2d",
    //     .format = .rgba8_unorm,
    //     // SAMPLED tells wgpu that we want to use this texture in shaders
    //     // COPY_DST means that we want to copy data to this texture
    //     .usage = 0, // .{ .sampled = true, .copy_dst = true },
    //     .label = wgpu.StringView.fromSlice("font_atlas"),
    // }).?;
    // tex.release();
    //
    // const tex_view = wgpu.wgpu_texture_create_view(
    //     tex,
    //     &(wgpu.WGPUTextureViewDescriptor){
    //         .label = "font_atlas_view",
    //         .dimension = wgpu.WGPUTextureViewDimension_D2,
    //         .format = wgpu.WGPUTextureFormat_Rgba8Unorm,
    //         .aspect = wgpu.WGPUTextureAspect_All,
    //         .base_mip_level = 0,
    //         .level_count = 1,
    //         .base_array_layer = 0,
    //         .array_layer_count = 1,
    //     },
    // );
    //
    // const tex_sampler = wgpu.wgpu_device_create_sampler(
    //     device,
    //     &(wgpu.WGPUSamplerDescriptor){
    //         .next_in_chain = null,
    //         .label = "font_atlas_sampler",
    //         .address_mode_u = wgpu.WGPUAddressMode_ClampToEdge,
    //         .address_mode_v = wgpu.WGPUAddressMode_ClampToEdge,
    //         .address_mode_w = wgpu.WGPUAddressMode_ClampToEdge,
    //         .mag_filter = wgpu.WGPUFilterMode_Linear,
    //         .min_filter = wgpu.WGPUFilterMode_Nearest,
    //         .mipmap_filter = wgpu.WGPUFilterMode_Nearest,
    //         .lod_min_clamp = 0.0,
    //         .lod_max_clamp = std.math.floatMax(f32),
    //         .compare = wgpu.WGPUCompareFunction_Undefined,
    //     },
    // );
    //
    // ////////////////////////////////////////////////////////////////////////////
    // // Uniform buffers
    // const uniform_buffer = wgpu.wgpu_device_create_buffer(
    //     device,
    //     &(wgpu.WGPUBufferDescriptor){
    //         .label = "Uniforms",
    //         .size = @sizeOf(wgpu.fpUniforms),
    //         .usage = wgpu.WGPUBufferUsage_UNIFORM | wgpu.WGPUBufferUsage_COPY_DST,
    //         .mapped_at_creation = false,
    //     },
    // );
    // const char_grid_buffer = wgpu.wgpu_device_create_buffer(
    //     device,
    //     &(wgpu.WGPUBufferDescriptor){
    //         .label = "Character grid",
    //         .size = @sizeOf(u32) * 512 * 512,
    //         .usage = wgpu.WGPUBufferUsage_STORAGE | wgpu.WGPUBufferUsage_COPY_DST,
    //         .mapped_at_creation = false,
    //     },
    // );
    //
    ////////////////////////////////////////////////////////////////////////////
    // Bind groups (?!)
    const bind_group_layout_entries = [_]wgpu.BindGroupLayoutEntry{
        // .{
        //     .binding = 0,
        //     .visibility = wgpu.ShaderStages.fragment,
        //     // .ty = wgpu.WGPUBindingType_SampledTexture,
        //     .multisampled = false,
        //     .view_dimension = wgpu.WGPUTextureViewDimension_D2,
        //     .texture_component_type = wgpu.WGPUTextureComponentType_Uint,
        //     .storage_texture_format = wgpu.WGPUTextureFormat_Rgba8Unorm,
        //     .count = undefined,
        //     .has_dynamic_offset = undefined,
        //     .min_buffer_binding_size = undefined,
        // },
        // .{
        //     .binding = 1,
        //     .visibility = wgpu.WGPUShaderStage_FRAGMENT,
        //     .ty = wgpu.WGPUBindingType_Sampler,
        //     .multisampled = undefined,
        //     .view_dimension = undefined,
        //     .texture_component_type = undefined,
        //     .storage_texture_format = undefined,
        //     .count = undefined,
        //     .has_dynamic_offset = undefined,
        //     .min_buffer_binding_size = undefined,
        // },
        // (wgpu.WGPUBindGroupLayoutEntry){
        //     .binding = 2,
        //     .visibility = wgpu.WGPUShaderStage_VERTEX | wgpu.WGPUShaderStage_FRAGMENT,
        //     .ty = wgpu.WGPUBindingType_UniformBuffer,
        //     .has_dynamic_offset = false,
        //     .min_buffer_binding_size = 0,
        //     .multisampled = undefined,
        //     .view_dimension = undefined,
        //     .texture_component_type = undefined,
        //     .storage_texture_format = undefined,
        //     .count = undefined,
        // },
        // (wgpu.WGPUBindGroupLayoutEntry){
        //     .binding = 3,
        //     .visibility = wgpu.WGPUShaderStage_VERTEX,
        //     .ty = wgpu.WGPUBindingType_StorageBuffer,
        //     .has_dynamic_offset = false,
        //     .min_buffer_binding_size = 0,
        //     .multisampled = undefined,
        //     .view_dimension = undefined,
        //     .texture_component_type = undefined,
        //     .storage_texture_format = undefined,
        //     .count = undefined,
        // },
    };
    const bind_group_layout = device.createBindGroupLayout(&(wgpu.BindGroupLayoutDescriptor){
        .label = wgpu.StringView.fromSlice("bind group layout"),
        .entries = &bind_group_layout_entries,
        .entry_count = bind_group_layout_entries.len,
    }).?;
    defer bind_group_layout.release();

    const bind_group_entries = [_]wgpu.BindGroupEntry{
        // (wgpu.WGPUBindGroupEntry){
        //     .binding = 0,
        //     .texture_view = tex_view,
        //     .sampler = 0, // None
        //     .buffer = 0, // None
        //     .offset = undefined,
        //     .size = undefined,
        // },
        // (wgpu.WGPUBindGroupEntry){
        //     .binding = 1,
        //     .sampler = tex_sampler,
        //     .texture_view = 0, // None
        //     .buffer = 0, // None
        //     .offset = undefined,
        //     .size = undefined,
        // },
        // (wgpu.WGPUBindGroupEntry){
        //     .binding = 2,
        //     .buffer = uniform_buffer,
        //     .offset = 0,
        //     .size = @sizeOf(wgpu.fpUniforms),
        //     .sampler = 0, // None
        //     .texture_view = 0, // None
        // },
        // (wgpu.WGPUBindGroupEntry){
        //     .binding = 3,
        //     .buffer = char_grid_buffer,
        //     .offset = 0,
        //     .size = @sizeOf(u32) * 512 * 512,
        //     .sampler = 0, // None
        //     .texture_view = 0, // None
        // },
    };
    const bind_group = device.createBindGroup(&(wgpu.BindGroupDescriptor){
        .label = wgpu.StringView.fromSlice("bind group"),
        .layout = bind_group_layout,
        .entries = &bind_group_entries,
        .entry_count = bind_group_entries.len,
    }).?;
    const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};

    ////////////////////////////////////////////////////////////////////////////
    // Render pipelines (?!?)
    const pipeline_layout = device.createPipelineLayout(
        &(wgpu.PipelineLayoutDescriptor){
            .bind_group_layouts = &bind_group_layouts,
            .bind_group_layout_count = bind_group_layouts.len,
        },
    ).?;
    defer pipeline_layout.release();

    const render_pipeline = device.createRenderPipeline(&(wgpu.RenderPipelineDescriptor){
        .layout = pipeline_layout,
        .vertex = (wgpu.VertexState){
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
            // .index_format = wgpu.WGPUIndexFormat_Uint16,
            // .vertex_buffers = null,
            // .vertex_buffers_length = 0,
        },
        .fragment = &(wgpu.FragmentState){
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = &[1]wgpu.ColorTargetState{
                .{
                    .format = wgpu.TextureFormat.rgba8_unorm,
                    .blend = &(wgpu.BlendState){
                        .alpha = wgpu.BlendComponent{
                            //         .src_factor = wgpu.WGPUBlendFactor_One,
                            //         .dst_factor = wgpu.WGPUBlendFactor_Zero,
                            //         .operation = wgpu.WGPUBlendOperation_Add,
                        },
                        .color = wgpu.BlendComponent{
                            //         .src_factor = wgpu.WGPUBlendFactor_One,
                            //         .dst_factor = wgpu.WGPUBlendFactor_Zero,
                            //         .operation = wgpu.WGPUBlendOperation_Add,
                        },
                    },
                    .write_mask = wgpu.ColorWriteMasks.all,
                },
            },
        },
        // .rasterization_state = &(wgpu.WGPURasterizationStateDescriptor){
        //     .front_face = wgpu.WGPUFrontFace_Ccw,
        //     .cull_mode = wgpu.WGPUCullMode_None,
        //     .depth_bias = 0,
        //     .depth_bias_slope_scale = 0.0,
        //     .depth_bias_clamp = 0.0,
        // },
        .primitive = wgpu.PrimitiveState{
            .topology = wgpu.PrimitiveTopology.triangle_list,
        },
        // .color_states_length = 1,
        // .depth_stencil_state = null,
        // .sample_count = 1,
        // .sample_mask = 0,
        // .alpha_to_coverage_enabled = false,
        .multisample = wgpu.MultisampleState{},
    }).?;

    var out = Renderer{
        // .tex = tex,
        // .tex_view = tex_view,
        // .tex_sampler = tex_sampler,

        .width = undefined,
        .height = undefined,

        .device = device,
        .surface = surface,

        .queue = device.getQueue().?,

        .bind_group = bind_group,
        // .uniform_buffer = uniform_buffer,
        // .char_grid_buffer = char_grid_buffer,

        .render_pipeline = render_pipeline,

        .preview = null,
        // .blit = try Blit.init(alloc, device),

        // .dt = undefined,
        // .dt_index = 0,

        .alloc = alloc,
    };

    out.reset_dt();
    // out.update_font_tex(font);
    return out;
}

pub fn clear_preview(self: *Self) void {
    if (self.preview) |p| {
        p.deinit();
        self.alloc.destroy(p);
        self.preview = null;
    }
}

fn reset_dt(self: *Self) void {
    _ = self;
    // var i: usize = 0;
    // while (i < self.dt.len) : (i += 1) {
    //     self.dt[i] = 0;
    // }
    // self.dt_index = 0;
}

pub fn setPreview(self: *Self) !void {
    self.clear_preview();


    // Construct a new Preview with our current state
    // var p = try self.alloc.create(Preview);
    // p.* = try Preview.init(self.alloc, self.device, s.spirv, s.has_time);
    // p.set_size(self.width, self.height);

    // self.preview = p;
    // self.blit.bind_to_tex(p.tex_view[1]);
    self.reset_dt();

    unreachable;
}

// pub fn update_font_tex(self: *Self, font: *const ft.Atlas) void {
//     const tex_size = (wgpu.WGPUExtent3d){
//         .width = @as(u32, font.tex_size),
//         .height = @as(u32, font.tex_size),
//         .depth = 1,
//     };
//     wgpu.wgpu_queue_write_texture(
//         self.queue,
//         &(wgpu.WGPUTextureCopyView){
//             .texture = self.tex,
//             .mip_level = 0,
//             .origin = (wgpu.WGPUOrigin3d){ .x = 0, .y = 0, .z = 0 },
//         },
//         @as([*]const u8, @ptrCast(font.tex.ptr)),
//         font.tex.len * @sizeOf(u32),
//         &(wgpu.WGPUTextureDataLayout){
//             .offset = 0,
//             .bytes_per_row = @as(u32, font.tex_size) * @sizeOf(u32),
//             .rows_per_image = @as(u32, font.tex_size) * @sizeOf(u32),
//         },
//         &tex_size,
//     );
// }

pub fn redraw(self: *Self, total_tiles: u32) void {
    const start_ms = std.time.milliTimestamp();
    _ = start_ms;

    // Render the preview to its internal texture, then blit from that
    // texture to the main swap chain.  This lets us render the preview
    // at a different resolution from the rest of the UI.
    if (self.preview) |p| {
        p.redraw();
        if ((p.previewuniforms._tiles_per_side > 1 and p.previewuniforms._tile_num != 0) or
            p.draw_continuously)
        {
            c.glfwPostEmptyEvent();
        }
    }

    // Begin the main render operation
    // self.surface.configure(&(wgpu.SurfaceConfiguration){ });
    // self.surface.getCurrentTexture(&wgpu.SurfaceTexture{ }).?;
    // const next_texture = wgpu.wgpu_swap_chain_get_next_texture(self.swap_chain);
    // if (next_texture.view_id == 0) {
    //     std.debug.panic("Cannot acquire next swap chain texture", .{});
    // }
    const cmd_encoder = self.device.createCommandEncoder(&.{
        .label = wgpu.StringView.fromSlice("main encoder"),
    }).?;

    const color_attachments = [_]wgpu.ColorAttachment{
        // (wgpu.ColorAttachment){
        //     .attachment = next_texture.view_id,
        //     .resolve_target = 0,
        //     .load_op = wgpu.WGPULoadOp_Clear,
        //     .store_op = wgpu.WGPUStoreOp_Store,
        //     .clear_value = (wgpu.WGPUColor){
        //         .r = 0.0,
        //         .g = 0.0,
        //         .b = 0.0,
        //         .a = 1.0,
        //     },
        // },
    };

    const rpass = cmd_encoder.beginRenderPass(&(wgpu.RenderPassDescriptor){
        .color_attachments = &color_attachments,
        .color_attachment_count = color_attachments.len,
    }).?;

    rpass.setPipeline(self.render_pipeline);
    rpass.setBindGroup(0, self.bind_group, 0, null);
    rpass.draw(total_tiles * 6, 1, 0, 0);
    rpass.end();
    // if (self.preview != null) {
    //     self.blit.redraw(next_texture, cmd_encoder);
    // }

    const cmd_buf = cmd_encoder.finish(null).?;
    self.queue.submit(&.{cmd_buf});

    _ = self.surface.present(); // wgpu.wgpu_swap_chain_present(self.swap_chain);

    // const end_ms = std.time.milliTimestamp();
    // self.dt[self.dt_index] = end_ms - start_ms;
    // self.dt_index = (self.dt_index + 1) % self.dt.len;
    //
    // var dt_local = self.dt;
    // const asc = comptime std.sort.asc(i64);
    // std.mem.sort(i64, dt_local[0..], {}, asc);
    // const dt = dt_local[self.dt.len / 2];
    //
    // if (dt > 33) {
    //     if (self.preview) |p| {
    //         p.adjust_tiles(dt);
    //         self.reset_dt();
    //     }
    // }
}

pub fn deinit(self: *Self) void {
    _ = self;
    // wgpu.wgpu_texture_destroy(self.tex);
    // wgpu.wgpu_texture_view_destroy(self.tex_view);
    // wgpu.wgpu_sampler_destroy(self.tex_sampler);
    //
    // wgpu.wgpu_bind_group_destroy(self.bind_group);
    // wgpu.wgpu_buffer_destroy(self.uniform_buffer);
    // wgpu.wgpu_buffer_destroy(self.char_grid_buffer);
    //
    // wgpu.wgpu_render_pipeline_destroy(self.render_pipeline);
    //
    // if (self.preview) |p| {
    //     p.deinit();
    //     alloc.destroy(p);
    // }
    // self.blit.deinit();
}

pub fn update_grid(self: *Self, char_grid: []u32) void {
    wgpu.wgpu_queue_write_buffer(
        self.queue,
        self.char_grid_buffer,
        0,
        @as([*c]const u8, @ptrCast(char_grid.ptr)),
        char_grid.len * @sizeOf(u32),
    );
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    // self.surface.configure(&wgpu.SurfaceConfiguration{
    //     .ne
    // })
    // self.swap_chain = wgpu.wgpu_device_create_swap_chain(
    //     self.device,
    //     self.surface,
    //     &(wgpu.WGPUSwapChainDescriptor){
    //         .usage = wgpu.WGPUTextureUsage_OUTPUT_ATTACHMENT,
    //         .format = wgpu.WGPUTextureFormat_Bgra8Unorm,
    //         .width = width,
    //         .height = height,
    //         .present_mode = wgpu.WGPUPresentMode_Fifo,
    //     },
    // );

    // Track width and height so that we can set them in a Preview
    // (even if one isn't loaded right now)
    self.width = width;
    self.height = height;
    if (self.preview) |p| {
        p.set_size(width, height);
        // self.blit.bind_to_tex(p.tex_view[1]);
    }
}

// pub fn update_uniforms(self: *Self, u: *const wgpu.fpUniforms) void {
//     wgpu.wgpu_queue_write_buffer(
//         self.queue,
//         self.uniform_buffer,
//         0,
//         @as([*c]const u8, @ptrCast(u)),
//         @sizeOf(wgpu.fpUniforms),
//     );
// }

fn adapter_cb(received: wgpu.WGPUAdapterId, data: ?*anyopaque) callconv(.C) void {
    @as(*wgpu.WGPUAdapterId, @ptrCast(@alignCast(data))).* = received;
}
