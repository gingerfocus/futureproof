const std = @import("std");

// const wgpu = @import("c.zig");
const shaderc = @import("shaderc.zig");
const wgpu = @import("wgpu");

const ext = @import("ext.zig");

const Self = @This();

device: *wgpu.Device,
queue: *wgpu.Queue,

// We render into tex[0] in tiles to keep up a good framerate, then
// copy to tex[1] to render the complete image without tearing
tex: [2]*wgpu.Texture,
tex_view: [2]*wgpu.TextureView,
// tex_size: c.WGPUExtent3d,
//
bind_group: *wgpu.BindGroup,
uniform_buffer: *wgpu.Buffer,
render_pipeline: *wgpu.RenderPipeline,
//
start_time: i64,
previewuniforms: ext.PreviewUniforms,
draw_continuously: bool,

pub fn init(
    alloc: std.mem.Allocator,
    device: *wgpu.Device,
    frag: []const u32,
    draw_continuously: bool,
) !Self {
    // var arena = std.heap.ArenaAllocator.init(alloc.*);
    // var all = arena.allocator();
    // const tmp_alloc: *std.mem.Allocator = &all;
    // defer arena.deinit();

    // Build the shaders using shaderc
    const vert_spv = shaderc.build_shader_from_file(alloc, "shaders/preview.vert") catch {
        std.debug.panic("Could not build preview.vert", .{});
    };
    const vert_shader = device.createShaderModuleSpirV(&.{
        .source = vert_spv.ptr,
        .source_size = @intCast(vert_spv.len),
    }).?;
    defer vert_shader.release();

    const frag_shader = device.createShaderModuleSpirV(&.{
        .source = frag.ptr,
        .source_size = @intCast(frag.len),
    }).?;
    defer frag_shader.release();

    ////////////////////////////////////////////////////////////////////////////////
    // Uniform buffers
    const uniform_buffer = device.createBuffer(
        &(wgpu.BufferDescriptor){
            .label = wgpu.StringView.fromSlice("Uniforms"),
            .size = @sizeOf(ext.PreviewUniforms),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            // .mapped_at_creation = false,
        },
    ).?;

    ////////////////////////////////////////////////////////////////////////////////
    const bind_group_layout_entries = [_]wgpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = wgpu.ShaderStages.vertex | wgpu.ShaderStages.fragment,
            // .ty = wgpu.WGPUBindingType_UniformBuffer,
            // .has_dynamic_offset = false,
            // .min_buffer_binding_size = 0,
            // .multisampled = undefined,
            // .view_dimension = undefined,
            // .texture_component_type = undefined,
            // .storage_texture_format = undefined,
            // .count = undefined,
        },
    };
    const bind_group_layout = device.createBindGroupLayout(&.{
        .label = wgpu.StringView.fromSlice("bind group layout"),
        .entries = &bind_group_layout_entries,
        .entry_count = bind_group_layout_entries.len,
    }).?;
    defer bind_group_layout.release();

    const bind_group_entries = [_]wgpu.BindGroupEntry{
        (wgpu.BindGroupEntry){
            .binding = 0,
            .buffer = uniform_buffer,
            .offset = 0,
            .size = @sizeOf(ext.PreviewUniforms),
            // .sampler = 0, // None
            // .texture_view = 0, // None
        },
    };
    const bind_group = device.createBindGroup(
        &(wgpu.BindGroupDescriptor){
            .label = wgpu.StringView.fromSlice("bind group"),
            .layout = bind_group_layout,
            .entries = &bind_group_entries,
            .entry_count = bind_group_entries.len,
        },
    ).?;
    const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};

    // Render pipelines (?!?)
    const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("pipeline layout"),
        .bind_group_layouts = &bind_group_layouts,
        .bind_group_layout_count = bind_group_layouts.len,
    }).?;
    defer pipeline_layout.release();

    const render_pipeline = device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .layout = pipeline_layout,
        .vertex = (wgpu.VertexState){
            .module = vert_shader,
            .entry_point = wgpu.StringView.fromSlice("main"),
        },
        .fragment = &(wgpu.FragmentState){
            .module = frag_shader,
            .entry_point = wgpu.StringView.fromSlice("main"),
            .target_count = 1,
            .targets = &[1]wgpu.ColorTargetState{
                wgpu.ColorTargetState{
                    .format = wgpu.TextureFormat.rgba8_unorm,
                    // .color_states = &(wgpu.WGPUColorStateDescriptor){
                    //     .format = wgpu.WGPUTextureFormat_Bgra8Unorm,
                    //     .alpha_blend = (wgpu.WGPUBlendDescriptor){
                    //         .src_factor = wgpu.WGPUBlendFactor_One,
                    //         .dst_factor = wgpu.WGPUBlendFactor_Zero,
                    //         .operation = wgpu.WGPUBlendOperation_Add,
                    //     },
                    //     .color_blend = (wgpu.WGPUBlendDescriptor){
                    //         .src_factor = wgpu.WGPUBlendFactor_One,
                    //         .dst_factor = wgpu.WGPUBlendFactor_Zero,
                    //         .operation = wgpu.WGPUBlendOperation_Add,
                    //     },
                    //     .write_mask = wgpu.WGPUColorWrite_ALL,
                    // },
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
        .primitive = wgpu.PrimitiveState{},
        .multisample = wgpu.MultisampleState{},
        // .color_states_length = 1,
        // .depth_stencil_state = null,
        // .sample_count = 1,
        // .sample_mask = 0,
        // .alpha_to_coverage_enabled = false,
    }).?;

    const start_time = std.time.milliTimestamp();
    return Self{
        .device = device,
        .queue = device.getQueue().?,

        .render_pipeline = render_pipeline,
        .uniform_buffer = uniform_buffer,
        .bind_group = bind_group,

        .start_time = start_time,
        .draw_continuously = draw_continuously,

        // Assigned in set_size below
        .tex = undefined,
        .tex_view = undefined,
        // .tex_size = undefined,

        .previewuniforms = .{
            .iResolution = .{ .x = 0, .y = 0, .z = 0 },
            .iTime = 0.0,
            .iMouse = .{ .x = 0, .y = 0, .z = 0, .w = 0 },
            ._tiles_per_side = 1,
            ._tile_num = 0,
        },
    };
}

fn destroy_textures(self: *const Self) void {
    _ = self;
    // If the texture was created, then destroy it
    // if (self.uniforms.iResolution.x != 0) {
    //     for (self.tex) |t| {
    //         wgpu.wgpu_texture_destroy(t);
    //     }
    //     for (self.tex_view) |t| {
    //         wgpu.wgpu_texture_view_destroy(t);
    //     }
    // }
}

pub fn adjust_tiles(self: *Self, dt: i64) void {
    // What's the total render time, approximately?
    const dt_est = std.math.pow(i64, self.previewuniforms._tiles_per_side, 2) * dt;

    // We'd like to keep the UI running at 60 FPS, approximately
    const t = std.math.ceil(std.math.sqrt(@as(f32, @floatFromInt(dt_est))));

    std.debug.print(
        "Switching from {?} to {} tiles per side\n",
        .{ self.previewuniforms._tiles_per_side, t },
    );
    var t_ = @as(u32, @intFromFloat(t));
    if (t_ > 5) {
        t_ = 5;
    }
    self.previewuniforms._tiles_per_side = t_;
    self.previewuniforms._tile_num = 0;
}

pub fn deinit(self: *const Self) void {
    _ = self;
    // wgpu.wgpu_bind_group_destroy(self.bind_group);
    // wgpu.wgpu_buffer_destroy(self.uniform_buffer);
    // wgpu.wgpu_render_pipeline_destroy(self.render_pipeline);
    // self.destroy_textures();
}

pub fn set_size(self: *Self, width: u32, height: u32) void {
    _ = width;
    _ = height;
    self.destroy_textures();

    // self.tex_size = (wgpu.WGPUExtent3d){
    //     .width = @as(u32, width / 2),
    //     .height = @as(u32, height),
    //     .depth = 1,
    // };

    // var i: u8 = 0;
    // while (i < 2) : (i += 1) {
    //     self.tex[i] = wgpu.wgpu_device_create_texture(
    //         self.device,
    //         &(wgpu.WGPUTextureDescriptor){
    //             .size = self.tex_size,
    //             .mip_level_count = 1,
    //             .sample_count = 1,
    //             .dimension = wgpu.WGPUTextureDimension_D2,
    //             .format = wgpu.WGPUTextureFormat_Bgra8Unorm,
    //
    //             // We render to this texture, then use it as a source when
    //             // blitting into the final UI image
    //             .usage = if (i == 0)
    //                 (wgpu.WGPUTextureUsage_OUTPUT_ATTACHMENT |
    //                     wgpu.WGPUTextureUsage_COPY_SRC)
    //             else
    //                 (wgpu.WGPUTextureUsage_OUTPUT_ATTACHMENT |
    //                     wgpu.WGPUTextureUsage_COPY_SRC |
    //                     wgpu.WGPUTextureUsage_SAMPLED |
    //                     wgpu.WGPUTextureUsage_COPY_DST),
    //             .label = "preview_tex",
    //         },
    //     );
    //
    //     self.tex_view[i] = wgpu.wgpu_texture_create_view(
    //         self.tex[i],
    //         &(wgpu.WGPUTextureViewDescriptor){
    //             .label = "preview_tex_view",
    //             .dimension = wgpu.WGPUTextureViewDimension_D2,
    //             .format = wgpu.WGPUTextureFormat_Bgra8Unorm,
    //             .aspect = wgpu.WGPUTextureAspect_All,
    //             .base_mip_level = 0,
    //             .level_count = 1,
    //             .base_array_layer = 0,
    //             .array_layer_count = 1,
    //         },
    //     );
    // }
    //
    // self.uniforms.iResolution.x = @as(f32, @floatFromInt(width)) / 2;
    // self.uniforms.iResolution.y = @as(f32, @floatFromInt(height));
}

pub fn redraw(self: *Self) void {
    const cmd_encoder = self.device.createCommandEncoder(&(wgpu.CommandEncoderDescriptor){
        .label = wgpu.StringView.fromSlice("preview encoder"),
    }).?;

    // Set the time in the uniforms array
    if (self.previewuniforms._tile_num == 0) {
        const time_ms = std.time.milliTimestamp() - self.start_time;
        self.previewuniforms.iTime = @as(f32, @floatFromInt(time_ms)) / 1000.0;
    }

    self.queue.writeBuffer(
        self.uniform_buffer,
        0,
        @as(*anyopaque, @ptrCast(&self.previewuniforms)),
        @sizeOf(ext.PreviewUniforms),
    );

    const load_op = if (self.previewuniforms._tile_num == 0)
        wgpu.LoadOp.clear
    else
        wgpu.LoadOp.load;

    const color_attachments = [_]wgpu.ColorAttachment{
        (wgpu.ColorAttachment){
            .view = if (self.previewuniforms._tiles_per_side == 1) self.tex_view[1] else self.tex_view[0],
            .load_op = load_op,
            .store_op = wgpu.StoreOp.store,
            .clear_value = (wgpu.Color){
                .r = 0.0,
                .g = 0.0,
                .b = 0.0,
                .a = 1.0,
            },
        },
    };

    const rpass = cmd_encoder.beginRenderPass(&(wgpu.RenderPassDescriptor){
        .color_attachments = &color_attachments,
        .color_attachment_count = color_attachments.len,
    }).?;

    rpass.setPipeline(self.render_pipeline);
    rpass.setBindGroup(0, self.bind_group, 0, null); // wgpu.wgpu_render_pass_set_bind_group(rpass, 0, self.bind_group, null, 0);
    rpass.draw(6, 1, 0, 0);
    rpass.end();

    // Move on to the next tile
    // if (self.previewuniforms._tiles_per_side > 1) {
    //     self.previewuniforms._tile_num += 1;
    // }
    //
    // // If we just finished rendering every tile, then also copy
    // // to the deployment tex
    // if (self.previewuniforms._tile_num == std.math.pow(u32, self.previewuniforms._tiles_per_side, 2)) {
    //     const src = (wgpu.TextureCopyView){
    //         .texture = self.tex[0],
    //         .mip_level = 0,
    //         .origin = (wgpu.WGPUOrigin3d){ .x = 0, .y = 0, .z = 0 },
    //     };
    //     const dst = (wgpu.WGPUTextureCopyView){
    //         .texture = self.tex[1],
    //         .mip_level = 0,
    //         .origin = (wgpu.WGPUOrigin3d){ .x = 0, .y = 0, .z = 0 },
    //     };
    //     wgpu.wgpu_command_encoder_copy_texture_to_texture(
    //         cmd_encoder,
    //         &src,
    //         &dst,
    //         &self.tex_size,
    //     );
    //     self.previewuniforms._tile_num = 0;
    // }

    const cmd_buf = cmd_encoder.finish(null).?;
    self.queue.submit(&.{cmd_buf});
}
