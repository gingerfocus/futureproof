#version 450
#pragma shader_stage(vertex)
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

layout(set=0, binding=2) uniform fpUniforms u;
layout(set=0, binding=3) buffer CharGrid {
    uint[] char_grid;
};

layout(location=0) out vec2 v_tex_coords;
layout(location=1) out vec2 v_cell_coords;
layout(location=2) out flat uint v_ascii;
layout(location=3) out flat uint v_hl_attr;
layout(location=4) out flat  int v_cursor;

// Use a switch statement instead of a const array to work around
// https://github.com/gfx-rs/wgpu-native/issues/53
ivec2 vertex_position(uint i) {
    // Hard-coded triangle layout
    switch (i % 6) {
        case 0: return ivec2(0, 0);
        case 1: return ivec2(1, 0);
        case 2: return ivec2(0, 1);
        case 3: return ivec2(1, 0);
        case 4: return ivec2(0, 1);
        case 5: return ivec2(1, 1);
    };
    return ivec2(0);
}

void main() {
    uint tile_id = gl_VertexIndex / 6;
    const uint x_tiles = u.width_px / u.font.glyph_advance / 2;
    const uint y_tiles = u.height_px / u.font.glyph_height;
    const uint total_tiles = x_tiles * y_tiles;

    v_ascii = char_grid[tile_id] & 0xFFFF;
    v_hl_attr = char_grid[tile_id] >> 16;
    fpGlyph glyph = u.font.glyphs[v_ascii];

    uint tile_x = tile_id % x_tiles;
    uint tile_y = tile_id / x_tiles;

    // The cursor position and mode are encoded at the end of the tiles array
    v_cursor = (tile_x == char_grid[total_tiles] &&
                tile_y == char_grid[total_tiles + 1])
        ? int(char_grid[total_tiles + 2]) : -1;

    // Tile position (0 to x_tiles, 0 to y_tiles)
    ivec2 tile = ivec2(tile_id % x_tiles, y_tiles - 1 - (tile_id / x_tiles));

    ivec2 p = vertex_position(gl_VertexIndex);

    // Position of the tile vertex within the tile
    ivec2 tile_pos_px = (tile + p) * ivec2(u.font.glyph_advance, u.font.glyph_height);

    // Stretch tiles at the edges of the grid to avoid empty space
    const uint x_padding = (u.width_px / 2 - u.font.glyph_advance * x_tiles);
    float dx = 0;
    if (x_padding > 0) {
        if (tile_x == x_tiles - 1 && p.x == 1) {
            dx = int(x_padding);
            tile_pos_px.x += int(x_padding);
        } else {
            // Nothing to do here, leave in place
        }
    }
    const uint y_padding = (u.height_px - u.font.glyph_height * y_tiles);
    float dy = 0;
    if (y_padding > 0) {
        if (tile_y == 0 && p.y == 1) {
            tile_pos_px.y += int(y_padding);
            dy = y_padding / 2.0;
        } else if (tile_y == y_tiles - 1 && p.y == 0) {
            // Nothing to do, leave it at the baseline
            dy = -int(y_padding) / 2.0;
        } else {
            tile_pos_px.y += int(y_padding / 2);
        }
    }

    // Convert from pixels to window units
    vec2 vf = (tile_pos_px / vec2(u.width_px, u.height_px) - 0.5) * 2;
    gl_Position = vec4(vf, 0.0, 1.0);

    /*  We want to interpolate so that the texture coordinates on
     *  the grid are 0 at the character subregion's corners.  In 1D,
     *  this looks like this:
     *
     *  t0---0--------v-----t1      [texture coordinate]
     *  x0---x1-------x2----x3      [pixel position]
     *
     *  Solve for t0 and dt in terms of x1, d2, dx, v
     *
     *  t0 + (t1 - t0) * (x1 - x0) / (x3 - x0) = 0
     *  t0 + (t1 - t0) * (x2 - x0) / (x3 - x0) = v
     *
     *  -> t0 = v * (x1 - x0) / (x1 - x2)
     *  -> t1 = v * (x1 - x3) / (x1 - x2)
     */

    // X
    float x = (p.x == 0 ? 0 : u.font.glyph_advance) + dx;

    float x1 = glyph.x_offset;
    float x2 = x1 + glyph.width;
    float vx = glyph.width;

    float tx = vx * (x1 - x) / (x1 - x2);

    // Y
    float y = (p.y == 0 ? 0 : u.font.glyph_height) + dy;

    float y1 = glyph.y_offset - 1;
    float y2 = y1 + glyph.height;
    float vy = glyph.height;

    float ty = vy * (y1 - y) / (y1 - y2);

    v_tex_coords = vec2(tx, ty);

    v_cell_coords = vec2(p) + vec2(dx, dy) / vec2(u.font.glyph_advance, u.font.glyph_height);
}
