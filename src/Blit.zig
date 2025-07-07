const std = @import("std");

const c = @import("c.zig");
const wgpu = @import("wgpu");

const Blit = @This();
const Self = @This();
const util = @import("util.zig");

device: *wgpu.Device,

bind_group_layout: *wgpu.BindGroupLayout,
tex_sampler: *wgpu.Sampler,
bind_group: ?*wgpu.BindGroup,

render_pipeline: *wgpu.RenderPipeline,

pub fn init(
    alloc: std.mem.Allocator,
    device: wgpu.Device,
) !Blit {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    ////////////////////////////////////////////////////////////////////////////
    // Build the shaders
    const vert_shader = try util.makeShader(
        arena.allocator(),
        device,
        "shaders/blit.vert",
        wgpu.ShaderStages.vertex,
    );
    defer vert_shader.release();

    const frag_shader = try util.makeShader(
        arena.allocator(),
        device,
        "shaders/blit.frag",
        wgpu.ShaderStages.fragment,
    );
    defer frag_shader.release();

    ///////////////////////////////////////////////////////////////////////
    // Texture sampler (the texture comes from the Preview struct)
    const tex_sampler = wgpu.wgpu_device_create_sampler(device, &(wgpu.SamplerDescriptor){
        .next_in_chain = null,
        .label = "font_atlas_sampler",
        .address_mode_u = wgpu.AddressMode_ClampToEdge,
        .address_mode_v = wgpu.AddressMode_ClampToEdge,
        .address_mode_w = wgpu.AddressMode_ClampToEdge,
        .mag_filter = wgpu.FilterMode_Linear,
        .min_filter = wgpu.FilterMode_Nearest,
        .mipmap_filter = wgpu.FilterMode_Nearest,
        .lod_min_clamp = 0.0,
        .lod_max_clamp = std.math.floatMax(f32),
        .compare = wgpu.CompareFunction_Undefined,
    });

    ////////////////////////////////////////////////////////////////////////////
    // Bind groups (?!)
    const bind_group_layout_entries = [_]wgpu.BindGroupLayoutEntry{
        (wgpu.BindGroupLayoutEntry){
            .binding = 0,
            .visibility = wgpu.ShaderStage_FRAGMENT,
            .ty = wgpu.BindingType_SampledTexture,
            .multisampled = false,
            .view_dimension = wgpu.TextureViewDimension_D2,
            .texture_component_type = wgpu.TextureComponentType_Uint,
            .storage_texture_format = wgpu.TextureFormat_Bgra8Unorm,
            .count = undefined,
            .has_dynamic_offset = undefined,
            .min_buffer_binding_size = undefined,
        },
        (wgpu.BindGroupLayoutEntry){
            .binding = 1,
            .visibility = wgpu.ShaderStage_FRAGMENT,
            .ty = wgpu.BindingType_Sampler,
            .multisampled = undefined,
            .view_dimension = undefined,
            .texture_component_type = undefined,
            .storage_texture_format = undefined,
            .count = undefined,
            .has_dynamic_offset = undefined,
            .min_buffer_binding_size = undefined,
        },
    };
    const bind_group_layout = wgpu.wgpu_device_create_bind_group_layout(
        device,
        &(wgpu.BindGroupLayoutDescriptor){
            .label = "bind group layout",
            .entries = &bind_group_layout_entries,
            .entries_length = bind_group_layout_entries.len,
        },
    );
    const bind_group_layouts = [_]wgpu.BindGroupId{bind_group_layout};

    ////////////////////////////////////////////////////////////////////////////
    // Render pipelines
    const pipeline_layout = wgpu.wgpu_device_create_pipeline_layout(
        device,
        &(wgpu.PipelineLayoutDescriptor){
            .bind_group_layouts = &bind_group_layouts,
            .bind_group_layouts_length = bind_group_layouts.len,
        },
    );
    defer wgpu.wgpu_pipeline_layout_destroy(pipeline_layout);

    const render_pipeline = wgpu.wgpu_device_create_render_pipeline(
        device,
        &(wgpu.RenderPipelineDescriptor){
            .layout = pipeline_layout,
            .vertex_stage = (wgpu.ProgrammableStageDescriptor){
                .module = vert_shader,
                .entry_point = "main",
            },
            .fragment_stage = &(wgpu.ProgrammableStageDescriptor){
                .module = frag_shader,
                .entry_point = "main",
            },
            .rasterization_state = &(wgpu.RasterizationStateDescriptor){
                .front_face = wgpu.FrontFace_Ccw,
                .cull_mode = wgpu.CullMode_None,
                .depth_bias = 0,
                .depth_bias_slope_scale = 0.0,
                .depth_bias_clamp = 0.0,
            },
            .primitive_topology = wgpu.PrimitiveTopology_TriangleList,
            .color_states = &(wgpu.ColorStateDescriptor){
                .format = wgpu.TextureFormat_Bgra8Unorm,
                .alpha_blend = (wgpu.BlendDescriptor){
                    .src_factor = wgpu.BlendFactor_One,
                    .dst_factor = wgpu.BlendFactor_Zero,
                    .operation = wgpu.BlendOperation_Add,
                },
                .color_blend = (wgpu.BlendDescriptor){
                    .src_factor = wgpu.BlendFactor_One,
                    .dst_factor = wgpu.BlendFactor_Zero,
                    .operation = wgpu.BlendOperation_Add,
                },
                .write_mask = wgpu.ColorWrite_ALL,
            },
            .color_states_length = 1,
            .depth_stencil_state = null,
            .vertex_state = (wgpu.VertexStateDescriptor){
                .index_format = wgpu.IndexFormat_Uint16,
                .vertex_buffers = null,
                .vertex_buffers_length = 0,
            },
            .sample_count = 1,
            .sample_mask = 0,
            .alpha_to_coverage_enabled = false,
        },
    );

    return Self{
        .device = device,
        .tex_sampler = tex_sampler,
        .render_pipeline = render_pipeline,
        .bind_group_layout = bind_group_layout,
        .bind_group = null, // Not assigned until bind_to_tex is called
    };
}

pub fn bind_to_tex(self: *Self, tex_view: *wgpu.TextureView) void {
    if (self.bind_group) |b| b.release();

    const bind_group_entries = [_]wgpu.BindGroupEntry{
        (wgpu.BindGroupEntry){
            .binding = 0,
            .texture_view = tex_view,
            .sampler = 0, // None
            .buffer = 0, // None
        },
        (wgpu.BindGroupEntry){
            .binding = 1,
            .sampler = self.tex_sampler,
            .texture_view = 0, // None
            .buffer = 0, // None
        },
    };
    self.bind_group = self.device.createBindGroup(&(wgpu.BindGroupDescriptor){
        // .label = "bind group",
        .layout = self.bind_group_layout,
        .entries = &bind_group_entries,
        .entries_length = bind_group_entries.len,
    });
}

pub fn deinit(self: *Self) void {
    self.tex_sampler.release();
    self.bind_group_layout.release();
    if (self.bind_group) |b| b.release();
}

pub fn redraw(
    self: *Self,
    next_texture: *wgpu.TextureView,
    cmd_encoder: *wgpu.CommandEncoder,
) void {
    const color_attachments = [_]wgpu.ColorAttachment{
        (wgpu.ColorAttachment){
            .view = next_texture,
            .load_op = wgpu.LoadOp.load,
            .store_op = wgpu.StoreOp.store,
            .clear_value = (wgpu.Color){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        },
    };

    const rpass = cmd_encoder.beginComputePass(&(wgpu.RenderPassDescriptor){
        .color_attachments = &color_attachments,
        .color_attachment_count = color_attachments.len,
    }).?;

    rpass.setPipeline(self.render_pipeline);

    const b = self.bind_group orelse std.debug.panic(
        "Tried to blit preview before texture was bound",
        .{},
    );

    rpass.setBindGroup(0, b, 0, null);
    rpass.draw(6, 1, 0, 0);
    rpass.end();
}
