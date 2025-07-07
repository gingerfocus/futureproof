pub const vec3 = extern struct { x: f32, y: f32, z: f32 };
pub const vec4 = extern struct { x: f32, y: f32, z: f32, w: f32 };

pub const PreviewUniforms = extern struct {
    iResolution: vec3,
    iTime: f32,
    iMouse: vec4,
    _tiles_per_side: u32,
    _tile_num: u32,
};
