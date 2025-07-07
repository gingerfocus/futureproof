#version 450
#pragma shader_stage(fragment)
#extension GL_EXT_scalar_block_layout : require

// ----------------------------------------------------------------------------

#define uint32_t uint
#define int32_t int
#define MEMBER_STRUCT

struct fpGlyph {
    uint32_t x0, y0, width, height;
    int32_t x_offset, y_offset;
};
struct fpAtlasUniforms {
    MEMBER_STRUCT fpGlyph glyphs[256];
    uint32_t glyph_height;
    uint32_t glyph_advance;
};

#define FP_FLAG_BOLD          (1 << 0)
#define FP_FLAG_ITALIC        (1 << 1)
#define FP_FLAG_REVERSE       (1 << 2)
#define FP_FLAG_UNDERCURL     (1 << 3)
#define FP_FLAG_UNDERLINE     (1 << 4)
#define FP_FLAG_STRIKETHROUGH (1 << 5)
#define FP_FLAG_STANDOUT      (1 << 6)

struct fpHlAttrs {
    uint32_t foreground;
    uint32_t background;
    uint32_t special;
    uint32_t flags; // Set of FP_FLAGs above
};
#define FP_CURSOR_BLOCK 0
#define FP_CURSOR_VERTICAL 1
#define FP_CURSOR_HORIZONTAL 2
struct fpMode {
    uint32_t cursor_shape; // One of the FP_CURSORs above
    uint32_t cell_percentage;

    uint32_t blinkwait;
    uint32_t blinkon;
    uint32_t blinkoff;

    uint32_t attr_id;
};

#define FP_MAX_MODES 32
#define FP_MAX_ATTRS 256
struct fpUniforms {
    uint32_t width_px;
    uint32_t height_px;
    fpAtlasUniforms font;
    fpHlAttrs attrs[FP_MAX_ATTRS];
    fpMode modes[FP_MAX_MODES];
};

// ----------------------------------------------------------------------------

layout(location=0) in vec2 v_tex_coords;
layout(location=1) in vec2 v_cell_coords;
layout(location=2) in flat uint v_ascii;
layout(location=3) in flat uint v_hl_attr;
layout(location=4) in flat  int v_cursor;

layout(location=0) out vec4 out_color;

layout(set=0, binding=0) uniform texture2D font_tex;
layout(set=0, binding=1) uniform sampler font_sampler;
layout(set=0, binding=2) uniform fpUniforms u;

const vec3 GAMMA = vec3(1/2.2);

vec3 to_vec3(uint u) {
    return vec3(((u >> 16) & 0xFF) / 255.0,
                ((u >> 8)  & 0xFF) / 255.0,
                ((u >> 0)  & 0xFF) / 255.0);
}

vec3 to_vec3_linear(uint u) {
    return pow(to_vec3(u), 1/GAMMA);
}

mat3 get_colors_linear(uint attr_id) {
    fpHlAttrs attrs = u.attrs[attr_id];
#define GET(NAME) (attrs.NAME == 0xFFFFFFFF ? u.attrs[0].NAME : attrs.NAME)
    vec3 fg = to_vec3_linear(GET(foreground));
    vec3 bg = to_vec3_linear(GET(background));
    vec3 sp = to_vec3_linear(GET(special));
    return mat3(fg, bg, sp);
}

void main() {
    fpGlyph glyph = u.font.glyphs[v_ascii];
    fpHlAttrs attrs = u.attrs[v_hl_attr];

    mat3 colors = get_colors_linear(v_hl_attr);

    if ((attrs.flags & (FP_FLAG_REVERSE | FP_FLAG_STANDOUT)) != 0) {
        // Swap foreground and background (rows 0 and 1 respectively)
        colors = colors * mat3(0, 1, 0, 1, 0, 0, 0, 0, 1);
    }

    // In some cases, cells are stretched to deal with a window that isn't
    // an integral number of grid tiles.  If that's the case, then we
    // don't draw the cursor over the stretched region.
    if (v_cursor != -1 && v_cell_coords.x >= 0.0 && v_cell_coords.x <= 1.0 &&
                          v_cell_coords.y >= 0.0 && v_cell_coords.y <= 1.0)
    {
        fpMode mode = u.modes[v_cursor];
        fpHlAttrs attrs = u.attrs[mode.attr_id];

        // Get cursor colors
        mat3 cursor_colors = get_colors_linear(mode.attr_id);

        // The BLOCK cursor simply modifies the usual fg / bg values
        if (mode.cursor_shape == FP_CURSOR_BLOCK) {
            colors[0] = cursor_colors[1];
            colors[1] = cursor_colors[0];
        } else if (mode.cursor_shape == FP_CURSOR_VERTICAL) {
            const float fade = 1.0 / u.font.glyph_advance;
            float p = mode.cell_percentage / 100.0;
            float t = -1.0;
            if (v_cell_coords.x < fade) {
                t = v_cell_coords.x / fade;
            } else if (v_cell_coords.x < p - fade) {
                t = 1.0;
            } else if (v_cell_coords.x < p) {
                t = 1.0 - (v_cell_coords.x - p + fade) / fade;
            }

            if (t != -1.0) {
                // Blending foreground and background
                vec3 color = t * cursor_colors[0] + (1.0 - t) * cursor_colors[1];

                // Gamma correction
                out_color = vec4(pow(color, GAMMA), 1.0);
                return;
            }
        } else if (mode.cursor_shape == FP_CURSOR_HORIZONTAL) {
            const float fade = 1.0 / u.font.glyph_height;
            float p = mode.cell_percentage / 100.0;
            float t = -1.0;
            if (v_cell_coords.y < fade) {
                t = v_cell_coords.y / fade;
            } else if (v_cell_coords.y < p - fade) {
                t = 1.0;
            } else if (v_cell_coords.y < p) {
                t = 1.0 - (v_cell_coords.y - p + fade) / fade;
            }

            if (t != -1.0) {
                // Blending foreground and background
                vec3 color = t * cursor_colors[0] + (1.0 - t) * cursor_colors[1];

                // Gamma correction
                out_color = vec4(pow(color, GAMMA), 1.0);
                return;
            }
        }
    }

    vec3 t = vec3(0);
    if (v_tex_coords.x >= 0 && v_tex_coords.x < glyph.width &&
        v_tex_coords.y > 0 && v_tex_coords.y <= glyph.height)
    {
        ivec2 i = ivec2(glyph.x0 + v_tex_coords.x,
                        glyph.y0 + glyph.height - v_tex_coords.y);
        t = texelFetch(sampler2D(font_tex, font_sampler), i, 0).rgb;
    }

    // Blending foreground and background
    vec3 color = t * colors[0] + (1.0 - t) * colors[1];

    // Gamma correction
    out_color = vec4(pow(color, GAMMA), 1.0);
}
