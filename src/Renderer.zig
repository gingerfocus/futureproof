const std = @import("std");
const builtin = @import("builtin");
const wgpu = @import("wgpu");

const c = @import("c.zig");
const FtAtlas = @import("FtAtlas.zig");
const util = @import("util.zig");

// const Preview = @import("Preview.zig");
const Self = @This();
width: u32,
height: u32,

instance: *wgpu.Instance,

device: *wgpu.Device,
surface: *wgpu.Surface,

queue: *wgpu.Queue,

bind_group: *wgpu.BindGroup,
uniform_buffer: *wgpu.Buffer,
char_grid_buffer: *wgpu.Buffer,

pipeline: ?*wgpu.RenderPipeline,

shader: ?*wgpu.ShaderModule,
// preview: ?*Preview,
// blit: Blit,

// We track the last few preview times; if the media is under 30 FPS,
// then we switch to tiled rendering
dt: [5]i64,
dt_index: usize,

alloc: std.mem.Allocator,

// tex: wgpu.WGPUTexture,
// tex_view: wgpu.WGPUTextureView,
// tex_sampler: wgpu.WGPUSampler,

fn getSurface(instance: *wgpu.Instance, window: *c.GLFWwindow) *wgpu.Surface {
    // Extract the WGPU Surface from the platform-specific window
    const platform = builtin.os.tag;
    if (platform == .macos) {
        // Time to do hilarious Objective-C runtime hacks, equivalent to
        //  [ns_window.contentView setWantsLayer:YES];
        //  id metal_layer = [CAMetalLayer layer];
        //  [ns_window.contentView setLayer:metal_layer];
        const objc = @import("objc.zig");

        const cocoa_window = objc.glfwGetCocoaWindow(window);
        const ns_window = @as(wgpu.id, @ptrCast(@as(8, @alignCast(cocoa_window))));

        const cv = objc.call(ns_window, "contentView");
        _ = objc.callarg(cv, "setWantsLayer:", true);

        const ca_metal = objc.class("CAMetalLayer");
        const metal_layer = objc.call(ca_metal, "layer");

        _ = objc.callarg(cv, "setLayer:", metal_layer);

        return wgpu.wgpu_create_surface_from_metal_layer(metal_layer);
    } else {
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
        return instance.createSurface(&surfaceDescriptor).?;
    }
}
pub const init = initOld;

const required_features = [_]wgpu.FeatureName{
    .vertex_writable_storage, // VERTEX_WRITABLE_STORAGE
};

pub fn initOld(alloc: std.mem.Allocator, window: *c.GLFWwindow, font: *const FtAtlas) !Self {
    const instance = wgpu.Instance.create(null).?;
    const surface: *wgpu.Surface = getSurface(instance, window);
    ////////////////////////////////////////////////////////////////////////////
    // WGPU initial setup
    const adapterreq = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
        .compatible_surface = surface,
        .power_preference = .high_performance,
        .feature_level = .compatibility,
        // .backend_type = .opengl, // .vulkan,
        // 2 | 4 | 8, false,
    }, 0);
    const adapter: *wgpu.Adapter = switch (adapterreq.status) {
        .success => adapterreq.adapter.?,
        else => return error.NoAdapter,
    };
    defer adapter.release();

    const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
        .required_limits = null,
        .required_features = &required_features,
        .required_feature_count = required_features.len,
    }, 0);
    const device: *wgpu.Device = switch (device_request.status) {
        .success => device_request.device.?,
        else => return error.NoDevice,
    };
    ////////////////////////////////////////////////////////////////////////////

    const vert_shader = try util.makeShader(
        alloc,
        device,
        "shaders/grid.vert.glsl",
        wgpu.ShaderStages.vertex,
    );
    defer vert_shader.release();

    const frag_shader = try util.makeShader(
        alloc,
        device,
        "shaders/grid.frag.glsl",
        wgpu.ShaderStages.fragment,
    );
    defer frag_shader.release();

    ////////////////////////////////////////////////////////////////////////////
    // Upload the font atlas texture
    const tex_size = (wgpu.Extent3D){
        .width = @as(u32, font.tex_size),
        .height = @as(u32, font.tex_size),
        .depth_or_array_layers = 1,
    };

    const tex = device.createTexture(&wgpu.TextureDescriptor{
        .size = tex_size,
        .mip_level_count = 1,
        .sample_count = 1,
        .dimension = .@"2d",
        .format = .rgba8_unorm,
        // SAMPLED tells wgpu that we want to use this texture in shaders
        // COPY_DST means that we want to copy data to this texture
        .usage = wgpu.TextureUsages.texture_binding |
            wgpu.TextureUsages.copy_dst,
        .label = wgpu.StringView.fromSlice("font_atlas"),
    }).?;
    // defer tex.release();

    const tex_view = tex.createView(&(wgpu.TextureViewDescriptor){
        .label = wgpu.StringView.fromSlice("font_atlas_view"),
        .dimension = .@"2d",
        .format = .rgba8_unorm,
        .aspect = .all,
        .base_mip_level = 0,
        .mip_level_count = 1,
        .base_array_layer = 0,
        .array_layer_count = 1,
    }).?;
    // defer tex_view.release();

    const tex_sampler = device.createSampler(&(wgpu.SamplerDescriptor){
        // .next_in_chain = null,
        // .label = "font_atlas_sampler",
        // .address_mode_u = wgpu.WGPUAddressMode_ClampToEdge,
        // .address_mode_v = wgpu.WGPUAddressMode_ClampToEdge,
        // .address_mode_w = wgpu.WGPUAddressMode_ClampToEdge,
        // .mag_filter = wgpu.WGPUFilterMode_Linear,
        // .min_filter = wgpu.WGPUFilterMode_Nearest,
        // .mipmap_filter = wgpu.WGPUFilterMode_Nearest,
        // .lod_min_clamp = 0.0,
        // .lod_max_clamp = std.math.floatMax(f32),
        // .compare = wgpu.WGPUCompareFunction_Undefined,
    }).?;

    ////////////////////////////////////////////////////////////////////////////
    // Uniform buffers
    const uniform_buffer = device.createBuffer(&(wgpu.BufferDescriptor){
        .label = wgpu.StringView.fromSlice("Uniforms"),
        .size = @sizeOf(c.fpUniforms),
        .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
    }).?;
    const char_grid_buffer = device.createBuffer(&(wgpu.BufferDescriptor){
        .label = wgpu.StringView.fromSlice("Character grid"),
        .size = @sizeOf(u32) * 512 * 512,
        .usage = wgpu.BufferUsages.storage | wgpu.BufferUsages.copy_dst,
    }).?;

    ////////////////////////////////////////////////////////////////////////////
    // Bind groups (?!)
    const bind_group_layout_entries = [_]wgpu.BindGroupLayoutEntry{
        wgpu.BindGroupLayoutEntry{
            .binding = 0,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = wgpu.TextureBindingLayout{
                .sample_type = wgpu.SampleType.float,
            },
            // .sampler = wgpu.SamplerBindingLayout{ .type = wgpu.SamplerBindingType.filtering },
            //
            // .ty = wgpu.WGPUBindingType_SampledTexture,
            // .multisampled = false,
            // .view_dimension = wgpu.WGPUTextureViewDimension_D2,
            // .texture_component_type = wgpu.WGPUTextureComponentType_Uint,
            // .storage_texture_format = wgpu.WGPUTextureFormat_Rgba8Unorm,
            // .count = undefined,
            // .has_dynamic_offset = undefined,
            // .min_buffer_binding_size = undefined,
        },
        wgpu.BindGroupLayoutEntry{
            .binding = 1,
            .visibility = wgpu.ShaderStages.fragment,
            .sampler = wgpu.SamplerBindingLayout{
                .type = wgpu.SamplerBindingType.filtering,
                // .ty = wgpu.WGPUBindingType_Sampler,
            },
            // .multisampled = undefined,
            // .view_dimension = undefined,
            // .texture_component_type = undefined,
            // .storage_texture_format = undefined,
            // .count = undefined,
            // .has_dynamic_offset = undefined,
            // .min_buffer_binding_size = undefined,
        },
        (wgpu.BindGroupLayoutEntry){
            .binding = 2,
            .visibility = wgpu.ShaderStages.vertex | wgpu.ShaderStages.fragment,
            .buffer = wgpu.BufferBindingLayout{
                .type = wgpu.BufferBindingType.uniform,
            },
            // .has_dynamic_offset = false,
            // .min_buffer_binding_size = 0,
            // .multisampled = undefined,
            // .view_dimension = undefined,
            // .texture_component_type = undefined,
            // .storage_texture_format = undefined,
            // .count = undefined,
        },
        (wgpu.BindGroupLayoutEntry){
            .binding = 3,
            .visibility = wgpu.ShaderStages.vertex,
            // TODO: storage_texture and try removing feature flag
            .buffer = wgpu.BufferBindingLayout{
                .type = wgpu.BufferBindingType.storage,
            },
            // .ty = wgpu.WGPUBindingType_StorageBuffer,
            // .has_dynamic_offset = false,
            // .multisampled = undefined,
            // .view_dimension = undefined,
            // .texture_component_type = undefined,
            // .storage_texture_format = undefined,
            // .count = undefined,
        },
    };
    const bind_group_layout = device.createBindGroupLayout(&(wgpu.BindGroupLayoutDescriptor){
        .label = wgpu.StringView.fromSlice("bind group layout"),
        .entries = &bind_group_layout_entries,
        .entry_count = bind_group_layout_entries.len,
    }).?;
    defer bind_group_layout.release();

    const bind_group_entries = [_]wgpu.BindGroupEntry{
        (wgpu.BindGroupEntry){
            .binding = 0,
            .texture_view = tex_view,
            // .sampler = 0, // None
            // .buffer = 0, // None
            // .offset = undefined,
            // .size = undefined,
        },
        (wgpu.BindGroupEntry){
            .binding = 1,
            .sampler = tex_sampler,
            // .texture_view = 0, // None
            // .buffer = 0, // None
            // .offset = undefined,
            // .size = undefined,
        },
        (wgpu.BindGroupEntry){
            .binding = 2,
            .buffer = uniform_buffer,
            // .offset = 0,
            .size = @sizeOf(c.fpUniforms),
            // .sampler = 0, // None
            // .texture_view = 0, // None
        },
        (wgpu.BindGroupEntry){
            .binding = 3,
            .buffer = char_grid_buffer,
            // .offset = 0,
            .size = @sizeOf(u32) * 512 * 512,
            // .sampler = 0, // None
            // .texture_view = 0, // None
        },
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
            .module = vert_shader,
            .entry_point = wgpu.StringView.fromSlice("main"),
            // .index_format = wgpu.WGPUIndexFormat_Uint16,
            // .vertex_buffers = null,
            // .vertex_buffers_length = 0,
        },
        .fragment = &(wgpu.FragmentState){
            .module = frag_shader,
            .entry_point = wgpu.StringView.fromSlice("main"),
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

    var out = Self{
        .instance = instance,

        // .tex = tex,
        // .tex_view = tex_view,
        // .tex_sampler = tex_sampler,

        .width = undefined,
        .height = undefined,

        .device = device,
        .surface = surface,

        .queue = device.getQueue().?,

        .bind_group = bind_group,
        .uniform_buffer = uniform_buffer,
        .char_grid_buffer = char_grid_buffer,

        .pipeline = render_pipeline,

        .shader = null,
        // .preview = null,
        // .blit = try Blit.init(alloc, device),

        .dt = undefined,
        .dt_index = 0,

        .alloc = alloc,
    };

    out.resetTime();
    // out.update_font_tex(font);
    return out;
}

fn resetTime(self: *Self) void {
    var i: usize = 0;
    while (i < self.dt.len) : (i += 1) {
        self.dt[i] = 0;
    }
    self.dt_index = 0;
}

pub fn initNew(alloc: std.mem.Allocator, window: *c.GLFWwindow, font: *const FtAtlas) !Self {
    _ = font;
    const instance = wgpu.Instance.create(null).?;

    const surface = getSurface(instance, window);

    ////////////////////////////////////////////////////////////////////////////
    // WGPU initial setup
    const adapterreq = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
        .compatible_surface = surface,
        .power_preference = .high_performance,
        .feature_level = .compatibility,
        // .backend_type = .opengl, // .vulkan,
        // 2 | 4 | 8, false,
    }, 0);
    const adapter: *wgpu.Adapter = switch (adapterreq.status) {
        .success => adapterreq.adapter.?,
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
    ////////////////////////////////////////////////////////////////////////////

    const queue = device.getQueue().?;

    var renderer = Self{
        .instance = instance,

        // .window = window,
        .device = device,
        .surface = surface,
        .queue = queue,

        .pipeline = null,
        .shader = null,

        // .font = font,

        // set below
        .width = undefined,
        .height = undefined,

        // unused
        .bind_group = undefined,
        .uniform_buffer = undefined,
        .char_grid_buffer = undefined,
        .dt = undefined,
        .dt_index = undefined,

        .alloc = alloc,
    };

    var wi: c_int = undefined;
    var hi: c_int = undefined;
    c.glfwGetWindowSize(window, &wi, &hi);
    renderer.resize(@intCast(wi), @intCast(hi));

    return renderer;
}

pub const redraw = redrawNew;

fn redrawOld(self: *Self, total_tiles: u32) void {
    const start_ms = std.time.milliTimestamp();

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

    const end_ms = std.time.milliTimestamp();
    self.dt[self.dt_index] = end_ms - start_ms;
    self.dt_index = (self.dt_index + 1) % self.dt.len;

    var dt_local = self.dt;
    const asc = comptime std.sort.asc(i64);
    std.mem.sort(i64, dt_local[0..], {}, asc);
    const dt = dt_local[self.dt.len / 2];

    if (dt > 33) {
        if (self.preview) |p| {
            p.adjust_tiles(dt);
            self.resetTime();
        }
    }
}

fn redrawNew(self: *Self, total_tiles: u32) void {
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
            .load_op = wgpu.LoadOp.clear,
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
    // rpass.setVertexBuffer()
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

pub fn resize(self: *Self, width: u32, height: u32) void {
    // TODO: long term, wait for size to not be changed for over a second then
    // do this
    std.log.info("newsize={d}x{d}", .{ width, height });

    self.surface.configure(&(wgpu.SurfaceConfiguration){
        .width = @intCast(width),
        .height = @intCast(height),
        .device = self.device,
        .format = .bgra8_unorm_srgb,
    });

    // self.surface.configure()

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
    // self.width = width;
    // self.height = height;
    // if (self.preview) |p| {
    //     p.set_size(width, height);
    //     // self.blit.bind_to_tex(p.tex_view[1]);
    // }
}

// pub fn clear_preview(self: *Self) void {
//     if (self.preview) |p| {
//         p.deinit();
//         self.alloc.destroy(p);
//         self.preview = null;
//     }
// }
pub fn clearPreview(self: *Self) void {
    if (self.pipeline) |p| p.release();
    if (self.shader) |s| s.release();
    self.pipeline = null;
    self.shader = null;
}

// pub fn setPreview(self: *Self) !void {
//     self.clear_preview();
//
//     // Construct a new Preview with our current state
//     var p = try self.alloc.create(Preview);
//     p.* = try Preview.init(self.alloc, self.device, s.spirv, s.has_time);
//     p.set_size(self.width, self.height);
//
//     self.preview = p;
//     self.blit.bind_to_tex(p.tex_view[1]);
//     self.resetTime();
// }

pub fn setPreview(self: *Self, text: []const u8) !void {
    self.clearPreview();
    std.log.info("Setting preview", .{});

    const shader = self.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = text, // @embedFile("./tri.wgsl"),
        .label = "thing.wgsl",
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

    // const buf = self.device.createBuffer(&wgpu.BufferDescriptor{}).?;
    // buf.mapAsync(wgpu.MapModes.write, 0, 0, wgpu.BufferMapCallbackInfo{});

    const pipeline = self.device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .vertex = wgpu.VertexState{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
            // TODO: this is how you add input buffers
            // .buffers = &[_]wgpu.VertexBufferLayout{},
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

pub fn update_font_tex(self: *Self, font: *const FtAtlas) void {
    const tex_size = (wgpu.Extent3D){
        .width = @as(u32, font.tex_size),
        .height = @as(u32, font.tex_size),
        .depth = 1,
    };
    self.queue.writeTexture(
        &(wgpu.TexelCopyTextureInfo){
            .texture = self.tex,
            .mip_level = 0,
            .origin = (wgpu.Origin3D){ .x = 0, .y = 0, .z = 0 },
        },
        @as([*]const u8, @ptrCast(font.tex.ptr)),
        font.tex.len * @sizeOf(u32),
        &(wgpu.TexelCopyBufferLayout){
            .offset = 0,
            .bytes_per_row = @as(u32, font.tex_size) * @sizeOf(u32),
            .rows_per_image = @as(u32, font.tex_size) * @sizeOf(u32),
        },
        &tex_size,
    );
}

pub fn update_uniforms(self: *Self, u: *const c.fpUniforms) void {
    self.queue.writeBuffer(
        self.uniform_buffer,
        0,
        @ptrCast(u),
        @sizeOf(c.fpUniforms),
    );
}

pub fn update_grid(self: *Self, char_grid: []u32) void {
    self.queue.writeBuffer(
        self.char_grid_buffer,
        0,
        @ptrCast(char_grid.ptr),
        char_grid.len * @sizeOf(u32),
    );
}
