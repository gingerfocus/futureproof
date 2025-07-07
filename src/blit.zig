const std = @import("std");

const c = @import("c.zig");
const wgpu = @import("wgpu");
const shaderc = @import("shaderc.zig");

pub const Blit = struct {
    const Self = @This();

    device: wgpu.WGPUDevice,

    bind_group_layout: wgpu.WGPUBindGroupLayout,
    tex_sampler: wgpu.WGPUSampler,
    bind_group: ?wgpu.WGPUBindGroup,

    render_pipeline: wgpu.WGPURenderPipeline,

    pub fn init(alloc: std.mem.Allocator, device: wgpu.WGPUDevice) !Blit {
        var arena = std.heap.ArenaAllocator.init(alloc);
        var all = arena.allocator();
        const tmp_alloc: *std.mem.Allocator = &all;
        defer arena.deinit();

        ////////////////////////////////////////////////////////////////////////////
        // Build the shaders using shaderc
        const vert_spv = shaderc.build_shader_from_file(tmp_alloc, "shaders/blit.vert") catch {
            std.debug.panic("Could not open file", .{});
        };
        const vert_shader = wgpu.wgpu_device_create_shader_module(
            device,
            (wgpu.WGPUShaderSource){
                .bytes = vert_spv.ptr,
                .length = vert_spv.len,
            },
        );
        defer wgpu.wgpu_shader_module_destroy(vert_shader);

        const frag_spv = shaderc.build_shader_from_file(tmp_alloc, "shaders/blit.frag") catch {
            std.debug.panic("Could not open file", .{});
        };
        const frag_shader = wgpu.wgpu_device_create_shader_module(
            device,
            (wgpu.WGPUShaderSource){
                .bytes = frag_spv.ptr,
                .length = frag_spv.len,
            },
        );
        defer wgpu.wgpu_shader_module_destroy(frag_shader);

        ///////////////////////////////////////////////////////////////////////
        // Texture sampler (the texture comes from the Preview struct)
        const tex_sampler = wgpu.wgpu_device_create_sampler(device, &(wgpu.WGPUSamplerDescriptor){
            .next_in_chain = null,
            .label = "font_atlas_sampler",
            .address_mode_u = wgpu.WGPUAddressMode_ClampToEdge,
            .address_mode_v = wgpu.WGPUAddressMode_ClampToEdge,
            .address_mode_w = wgpu.WGPUAddressMode_ClampToEdge,
            .mag_filter = wgpu.WGPUFilterMode_Linear,
            .min_filter = wgpu.WGPUFilterMode_Nearest,
            .mipmap_filter = wgpu.WGPUFilterMode_Nearest,
            .lod_min_clamp = 0.0,
            .lod_max_clamp = std.math.floatMax(f32),
            .compare = wgpu.WGPUCompareFunction_Undefined,
        });

        ////////////////////////////////////////////////////////////////////////////
        // Bind groups (?!)
        const bind_group_layout_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
            (wgpu.WGPUBindGroupLayoutEntry){
                .binding = 0,
                .visibility = wgpu.WGPUShaderStage_FRAGMENT,
                .ty = wgpu.WGPUBindingType_SampledTexture,
                .multisampled = false,
                .view_dimension = wgpu.WGPUTextureViewDimension_D2,
                .texture_component_type = wgpu.WGPUTextureComponentType_Uint,
                .storage_texture_format = wgpu.WGPUTextureFormat_Bgra8Unorm,
                .count = undefined,
                .has_dynamic_offset = undefined,
                .min_buffer_binding_size = undefined,
            },
            (wgpu.WGPUBindGroupLayoutEntry){
                .binding = 1,
                .visibility = wgpu.WGPUShaderStage_FRAGMENT,
                .ty = wgpu.WGPUBindingType_Sampler,
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
            &(wgpu.WGPUBindGroupLayoutDescriptor){
                .label = "bind group layout",
                .entries = &bind_group_layout_entries,
                .entries_length = bind_group_layout_entries.len,
            },
        );
        const bind_group_layouts = [_]wgpu.WGPUBindGroupId{bind_group_layout};

        ////////////////////////////////////////////////////////////////////////////
        // Render pipelines
        const pipeline_layout = wgpu.wgpu_device_create_pipeline_layout(
            device,
            &(wgpu.WGPUPipelineLayoutDescriptor){
                .bind_group_layouts = &bind_group_layouts,
                .bind_group_layouts_length = bind_group_layouts.len,
            },
        );
        defer wgpu.wgpu_pipeline_layout_destroy(pipeline_layout);

        const render_pipeline = wgpu.wgpu_device_create_render_pipeline(
            device,
            &(wgpu.WGPURenderPipelineDescriptor){
                .layout = pipeline_layout,
                .vertex_stage = (wgpu.WGPUProgrammableStageDescriptor){
                    .module = vert_shader,
                    .entry_point = "main",
                },
                .fragment_stage = &(wgpu.WGPUProgrammableStageDescriptor){
                    .module = frag_shader,
                    .entry_point = "main",
                },
                .rasterization_state = &(wgpu.WGPURasterizationStateDescriptor){
                    .front_face = wgpu.WGPUFrontFace_Ccw,
                    .cull_mode = wgpu.WGPUCullMode_None,
                    .depth_bias = 0,
                    .depth_bias_slope_scale = 0.0,
                    .depth_bias_clamp = 0.0,
                },
                .primitive_topology = wgpu.WGPUPrimitiveTopology_TriangleList,
                .color_states = &(wgpu.WGPUColorStateDescriptor){
                    .format = wgpu.WGPUTextureFormat_Bgra8Unorm,
                    .alpha_blend = (wgpu.WGPUBlendDescriptor){
                        .src_factor = wgpu.WGPUBlendFactor_One,
                        .dst_factor = wgpu.WGPUBlendFactor_Zero,
                        .operation = wgpu.WGPUBlendOperation_Add,
                    },
                    .color_blend = (wgpu.WGPUBlendDescriptor){
                        .src_factor = wgpu.WGPUBlendFactor_One,
                        .dst_factor = wgpu.WGPUBlendFactor_Zero,
                        .operation = wgpu.WGPUBlendOperation_Add,
                    },
                    .write_mask = wgpu.WGPUColorWrite_ALL,
                },
                .color_states_length = 1,
                .depth_stencil_state = null,
                .vertex_state = (wgpu.WGPUVertexStateDescriptor){
                    .index_format = wgpu.WGPUIndexFormat_Uint16,
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

    pub fn bind_to_tex(self: *Self, tex_view: wgpu.WGPUTextureViewId) void {
        if (self.bind_group) |b| {
            wgpu.wgpu_bind_group_destroy(b);
        }
        const bind_group_entries = [_]wgpu.WGPUBindGroupEntry{
            (wgpu.WGPUBindGroupEntry){
                .binding = 0,
                .texture_view = tex_view,
                .sampler = 0, // None
                .buffer = 0, // None
                .offset = undefined,
                .size = undefined,
            },
            (wgpu.WGPUBindGroupEntry){
                .binding = 1,
                .sampler = self.tex_sampler,
                .texture_view = 0, // None
                .buffer = 0, // None
                .offset = undefined,
                .size = undefined,
            },
        };
        self.bind_group = wgpu.wgpu_device_create_bind_group(
            self.device,
            &(wgpu.WGPUBindGroupDescriptor){
                .label = "bind group",
                .layout = self.bind_group_layout,
                .entries = &bind_group_entries,
                .entries_length = bind_group_entries.len,
            },
        );
    }

    pub fn deinit(self: *Self) void {
        wgpu.wgpu_sampler_destroy(self.tex_sampler);
        wgpu.wgpu_bind_group_layout_destroy(self.bind_group_layout);
        if (self.bind_group) |b| {
            wgpu.wgpu_bind_group_destroy(b);
        }
    }

    pub fn redraw(
        self: *Self,
        next_texture: wgpu.WGPUSwapChainOutput,
        cmd_encoder: wgpu.WGPUCommandEncoderId,
    ) void {
        const color_attachments = [_]wgpu.WGPURenderPassColorAttachmentDescriptor{
            (wgpu.WGPURenderPassColorAttachmentDescriptor){
                .attachment = next_texture.view_id,
                .resolve_target = 0,
                .channel = (wgpu.WGPUPassChannel_Color){
                    .load_op = wgpu.WGPULoadOp_Load,
                    .store_op = wgpu.WGPUStoreOp_Store,
                    .clear_value = (wgpu.WGPUColor){
                        .r = 0.0,
                        .g = 0.0,
                        .b = 0.0,
                        .a = 1.0,
                    },
                    .read_only = false,
                },
            },
        };

        const rpass = wgpu.wgpu_command_encoder_begin_render_pass(
            cmd_encoder,
            &(wgpu.WGPURenderPassDescriptor){
                .color_attachments = &color_attachments,
                .color_attachments_length = color_attachments.len,
                .depth_stencil_attachment = null,
            },
        );

        wgpu.wgpu_render_pass_set_pipeline(rpass, self.render_pipeline);
        const b = self.bind_group orelse std.debug.panic(
            "Tried to blit preview before texture was bound",
            .{},
        );
        wgpu.wgpu_render_pass_set_bind_group(rpass, 0, b, null, 0);
        wgpu.wgpu_render_pass_draw(rpass, 6, 1, 0, 0);
        wgpu.wgpu_render_pass_end_pass(rpass);
    }
};
