const std = @import("std");

const c = @import("c.zig");
const FtAtlas = @import("FtAtlas.zig");
const msgpack = @import("msgpack.zig");
// const shaderc = @import("shaderc.zig");
const util = @import("util.zig");
const paste = @import("paste.zig");

const Buffer = @import("buffer.zig").Buffer;
const Debounce = @import("debounce.zig").Debounce(u32, 200);
const Renderer = @import("Renderer.zig");
const RPC = @import("rpc.zig").RPC;
const Window = @import("Window.zig");

const FONT_NAME = "font/Inconsolata-SemiBold.ttf";
const FONT_SIZE = 14;
const SCROLL_THRESHOLD = 0.1;

const Tui = @This();
const Self = @This();

alloc: *std.mem.Allocator,

//  These are the three components to the Tui:
//  - The window holds the GLFW window and handles resizing
//  - The renderer handles all the WGPU stuff
//  - The RPC bridge talks to a subprocess
window: Window,
renderer: Renderer,
rpc: RPC,
font: FtAtlas,

buffers: std.AutoHashMap(u32, *Buffer),
debounce: Debounce,

// Persistent shader compiler to rebuild previews faster
// compiler: c.shaderc_compiler_t,

char_grid: [512 * 512]u32,
x_tiles: u32,
y_tiles: u32,
total_tiles: u32,

mouse_tile_x: i32,
mouse_tile_y: i32,
mouse_scroll_y: f64,

//  Render state to pass into WGPU
u: c.fpUniforms,
uniforms_changed: bool,

pixel_density: u32,

pub fn init(alloc: *std.mem.Allocator) !*Self {
    // We'll use an arena for transient CPU-side resources
    var arena = std.heap.ArenaAllocator.init(alloc.*);
    var all = arena.allocator();
    const tmp_alloc: *std.mem.Allocator = &all;
    defer arena.deinit();

    var width: c_int = 900;
    var height: c_int = 600;

    var window = try Window.init(width, height, "futureproof");
    errdefer window.deinit();
    c.glfwGetFramebufferSize(window.window, &width, &height);

    var font = try FtAtlas.build_atlas(
        alloc,
        FONT_NAME,
        FONT_SIZE,
        512,
    );
    errdefer font.deinit();

    var renderer = try Renderer.init(alloc.*, window.window, &font);
    std.log.info("Renderer init done", .{});
    // fixme
    try renderer.setPreview(@embedFile("tri.wgsl"));

    const x_tiles = @as(u32, @intCast(width)) / font.u.glyph_advance;
    const y_tiles = @as(u32, @intCast(height)) / font.u.glyph_height;

    // Start up the RPC subprocess, using the global allocator
    const nvim_cmd = [_][]const u8{
        "nvim",
        "--embed",
        "--clean",
        // "-u",
        // "config/init.vim",
    };
    var rpc = try RPC.init(&nvim_cmd, alloc);
    std.log.info("RPC init done", .{});

    const out = try alloc.create(Self);
    out.* = .{
        .alloc = alloc,

        .window = window,
        .renderer = renderer,
        .rpc = rpc,
        .font = font,

        .buffers = std.AutoHashMap(u32, *Buffer).init(alloc.*),
        .debounce = Debounce.init(),
        // .compiler = c.shaderc_compiler_initialize(),

        .char_grid = undefined,
        .x_tiles = 0,
        .y_tiles = 0,
        .total_tiles = 0,

        .mouse_tile_x = 0,
        .mouse_tile_y = 0,
        .mouse_scroll_y = 0.0,

        .u = c.fpUniforms{
            .width_px = @as(u32, @intCast(width)),
            .height_px = @as(u32, @intCast(height)),
            .font = font.u,

            .attrs = undefined,
            .modes = undefined,
        },
        .uniforms_changed = true,
        .pixel_density = 1,
    };
    window.set_callbacks(
        size_cb,
        key_cb,
        mouse_button_cb,
        mouse_pos_cb,
        scroll_cb,
        @as(?*anyopaque, @ptrCast(out)),
    );

    if (false) {
        { // Attach the UI via RPC
            var options = msgpack.KeyValueMap.init(alloc.*);
            try options.put(
                msgpack.Key{ .RawString = "ext_linegrid" },
                msgpack.Value{ .Boolean = true },
            );
            defer options.deinit();
            try rpc.call_release(
                "nvim_ui_attach",
                .{ x_tiles, y_tiles, options },
            );
        }

        { // Try to subscribe to Fp events
            var options = msgpack.KeyValueMap.init(alloc.*);
            defer options.deinit();
            try rpc.call_release("nvim_subscribe", .{"Fp"});
        }

        // Tell Vim to save the default undo levels in a variable, then
        // set them to -1 (so that loading the template doesn't end up
        // in the undo list)
        try rpc.call_release(
            "nvim_input",
            .{":let old_undolevels = &undolevels<Enter>:set undolevels=-1<Enter>"},
        );

        { // Send the template text to the first buffer
            const src = try util.file_contents(
                all,
                "shaders/preview.template.frag",
            );
            var line_count: u32 = 1;
            for (src[0..(src.len - 2)]) |char| {
                if (char == '\n') {
                    line_count += 1;
                }
            }
            var lines = try tmp_alloc.alloc([]const u8, line_count);
            var start: usize = 0;
            var i: u32 = 0;
            while (std.mem.indexOf(u8, src[start..], "\n")) |end| {
                lines[i] = src[start..(start + end)];
                i += 1;
                start += end + 1;
            }

            // Encode the lines manually, as encoding nested structs
            // doesn't work right now (TODO).
            const encoded = try msgpack.Value.encode(tmp_alloc, lines);
            try rpc.call_release(
                "nvim_buf_set_lines",
                .{ 0, 0, 0, false, encoded },
            );
        }

        // Clean up and set the filetype
        try rpc.call_release(
            "nvim_input",
            .{"ddgg:set filetype=glsl<Enter>:setlocal nomodified<Enter>"},
        );

        // Re-enable undo by restoring default undo levels
        try rpc.call_release(
            "nvim_input",
            .{":let &undolevels = old_undolevels<Enter>:unlet old_undolevels<Enter>"},
        );

        out.update_size(width, height);
    }

    std.log.info("Tui init done", .{});
    return out;
}

pub fn deinit(self: *Self) void {
    self.rpc.deinit();
    self.font.deinit();
    self.window.deinit();
    self.renderer.deinit();

    var itr = self.buffers.iterator();
    while (itr.next()) |buf| {
        _ = buf;
        unreachable;
        // buf.value.deinit();
        // self.alloc.destroy(buf.value);
    }
    self.buffers.deinit();
    // c.shaderc_compiler_release(self.compiler);

    self.alloc.destroy(self);
}

fn attach_buffer(self: *Self, id: u32) !void {
    var options = msgpack.KeyValueMap.init(self.alloc);
    defer options.deinit();
    try self.rpc.call_release("nvim_buf_attach", .{ id, true, options });

    // Create a buffer on the heap and store it in the hash map.
    const buf = try self.alloc.create(Buffer);
    buf.* = try Buffer.init(self.alloc);
    try self.buffers.put(id, buf);
}

fn char_at(self: *Self, x: usize, y: usize) *u32 {
    return &self.char_grid[x + y * self.x_tiles];
}

fn api_grid_scroll(self: *Self, line: []const msgpack.Value) void {
    const grid = line[0].UInt;
    std.debug.assert(grid == 1);

    const top = line[1].UInt;
    const bot = line[2].UInt;
    const left = line[3].UInt;
    const right = line[4].UInt;

    const cols = line[6].UInt;
    std.debug.assert(cols == 0);

    // rows > 0 --> moving rows upwards
    if (line[5] == .UInt) {
        const rows = line[5].UInt;
        var y = top;
        while (y < bot - rows) : (y += 1) {
            var x = left;
            while (x < right) : (x += 1) {
                self.char_at(x, y).* = self.char_at(x, y + rows).*;
            }
        }
        // rows < 0 --> moving rows downwards
    } else if (line[5] == .Int) {
        const rows = @as(u32, -line[5].Int);
        var y = bot - 1;
        while (y >= top + rows) : (y -= 1) {
            var x = left;
            while (x < right) : (x += 1) {
                self.char_at(x, y).* = self.char_at(x, y - rows).*;
            }
        }
    }
}

fn decode_utf8(char: []const u8) u32 {
    if (char[0] >> 7 == 0) {
        std.debug.assert(char.len == 1);
        return char[0];
    } else if (char[0] >> 5 == 0b110) {
        std.debug.assert(char.len == 2);
        return (@as(u32, char[0] & 0b00011111) << 6) |
            @as(u32, char[1] & 0b00111111);
    } else if (char[0] >> 4 == 0b1110) {
        std.debug.assert(char.len == 3);
        return (@as(u32, char[0] & 0b00001111) << 12) |
            (@as(u32, char[1] & 0b00111111) << 6) |
            @as(u32, char[2] & 0b00111111);
    } else if (char[0] >> 3 == 0b11110) {
        std.debug.assert(char.len == 4);
        return (@as(u32, char[0] & 0b00000111) << 18) |
            (@as(u32, char[1] & 0b00111111) << 12) |
            (@as(u32, char[2] & 0b00111111) << 6) |
            @as(u32, char[3] & 0b00111111);
    }
    return 0;
}

fn api_grid_line(self: *Self, line: []const msgpack.Value) void {
    const grid = line[0].UInt;
    std.debug.assert(grid == 1);
    var hl_attr: u16 = 0;

    const row = line[1].UInt;
    var col = line[2].UInt;
    for (line[3].Array) |cell_| {
        const cell = cell_.Array;
        const text = cell[0].RawString;
        if (cell.len >= 2) {
            hl_attr = @as(u16, cell[1].UInt);
        }
        const repeat = if (cell.len >= 3) cell[2].UInt else 1;
        const codepoint = decode_utf8(text);

        var char: u32 = undefined;
        if (self.font.get_glyph(codepoint)) |g| {
            char = g;
        } else {
            std.debug.print("Adding new codepoint: {x}\n", .{codepoint});
            char = self.font.add_glyph(codepoint) catch |err| {
                std.debug.panic("Could not add glyph {}: {}\n", .{ codepoint, err });
            };
            // We've only added one glyph to the texture, so just copy
            // this one line over to our local uniforms:
            self.u.font.glyphs[char] = self.font.u.glyphs[char];

            // Then send the updated atlas and texture to the GPU
            self.renderer.update_uniforms(&self.u);
            self.renderer.update_font_tex(&self.font);
        }

        std.debug.assert(char < self.u.font.glyphs.len);
        var i: usize = 0;
        while (i < repeat) : (i += 1) {
            self.char_at(col, row).* = char | (@as(u32, hl_attr) << 16);
            col += 1; // TODO: unicode?!
        }
    }
}

fn api_flush(self: *Self, cmd: []const msgpack.Value) void {
    // Send over the character grid, along with the extra three values
    // that mark cursor position and mode within the grid
    std.debug.assert(cmd.len == 0);
    self.renderer.update_grid(self.char_grid[0 .. self.total_tiles + 3]);
}

fn api_grid_clear(self: *Self, cmd: []const msgpack.Value) void {
    const grid = cmd[0].UInt;
    std.debug.assert(grid == 1);
    std.mem.set(u32, self.char_grid[0..], 0);
}

fn api_grid_cursor_goto(self: *Self, cmd: []const msgpack.Value) void {
    const grid = cmd[0].UInt;
    std.debug.assert(grid == 1);

    // Record the cursor position at the end of the grid
    self.char_grid[self.total_tiles] = @as(u32, cmd[2].UInt);
    self.char_grid[self.total_tiles + 1] = @as(u32, cmd[1].UInt);
}

fn decode_hl_attrs(attr: *const msgpack.KeyValueMap) c.fpHlAttrs {
    var out = (c.fpHlAttrs){
        .foreground = 0xffffffff,
        .background = 0xffffffff,
        .special = 0xffffffff,
        .flags = 0,
    };

    var itr = attr.iterator();
    while (itr.next()) |entry| {
        if (std.mem.eql(u8, entry.key.RawString, "foreground")) {
            out.foreground = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "background")) {
            out.background = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "special")) {
            out.special = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "bold") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_BOLD;
        } else if (std.mem.eql(u8, entry.key.RawString, "italic") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_ITALIC;
        } else if (std.mem.eql(u8, entry.key.RawString, "undercurl") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_UNDERCURL;
        } else if (std.mem.eql(u8, entry.key.RawString, "reverse") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_REVERSE;
        } else if (std.mem.eql(u8, entry.key.RawString, "underline") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_UNDERLINE;
        } else if (std.mem.eql(u8, entry.key.RawString, "strikethrough") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_STRIKETHROUGH;
        } else if (std.mem.eql(u8, entry.key.RawString, "standout") and entry.value.Boolean) {
            out.flags |= c.FP_FLAG_STANDOUT;
        } else {
            std.debug.warn("Unknown hlAttr: {} {}\n", .{ entry.key, entry.value });
        }
    }
    return out;
}

fn api_hl_attr_define(self: *Self, cmd: []const msgpack.Value) void {
    // Decode rgb_attrs into the appropriate slot
    const id = cmd[0].UInt;
    std.debug.assert(id < c.FP_MAX_ATTRS);
    self.u.attrs[id] = decode_hl_attrs(&cmd[1].Map);
    self.uniforms_changed = true;
}

fn decode_mode(mode: *const msgpack.KeyValueMap) c.fpMode {
    var out = (c.fpMode){
        .cursor_shape = c.FP_CURSOR_BLOCK,
        .cell_percentage = 100,
        .blinkwait = 0,
        .blinkon = 0,
        .blinkoff = 0,
        .attr_id = 0,
    };
    var itr = mode.iterator();
    while (itr.next()) |entry| {
        if (std.mem.eql(u8, entry.key.RawString, "cursor_shape")) {
            if (std.mem.eql(u8, entry.value.RawString, "horizontal")) {
                out.cursor_shape = c.FP_CURSOR_HORIZONTAL;
            } else if (std.mem.eql(u8, entry.value.RawString, "vertical")) {
                out.cursor_shape = c.FP_CURSOR_VERTICAL;
            } else if (std.mem.eql(u8, entry.value.RawString, "block")) {
                out.cursor_shape = c.FP_CURSOR_BLOCK;
            } else {
                std.debug.panic("Unknown cursor shape: {}\n", .{entry.value});
            }
        } else if (std.mem.eql(u8, entry.key.RawString, "cell_percentage")) {
            out.cell_percentage = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "blinkwait")) {
            out.blinkwait = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "blinkon")) {
            out.blinkon = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "blinkoff")) {
            out.blinkoff = @as(u32, entry.value.UInt);
        } else if (std.mem.eql(u8, entry.key.RawString, "attr_id")) {
            out.attr_id = @as(u32, entry.value.UInt);
        } else {
            // Ignore other elements for now
        }
    }
    return out;
}

fn api_mode_info_set(self: *Self, cmd: []const msgpack.Value) void {
    std.debug.assert(cmd[1].Array.len < c.FP_MAX_MODES);
    var i: u32 = 0;
    while (i < cmd[1].Array.len) : (i += 1) {
        self.u.modes[i] = decode_mode(&cmd[1].Array[i].Map);
    }
}

fn api_mode_change(self: *Self, cmd: []const msgpack.Value) void {
    self.char_grid[self.total_tiles + 2] = @as(u32, cmd[1].UInt);
}

fn api_default_colors_set(self: *Self, cmd: []const msgpack.Value) void {
    self.u.attrs[0] = (c.fpHlAttrs){
        .foreground = @as(u32, cmd[0].UInt),
        .background = @as(u32, cmd[1].UInt),
        .special = @as(u32, cmd[2].UInt),
        .flags = 0,
    };
    self.uniforms_changed = true;
}

fn call_method(self: *Self, event: []const msgpack.Value) !void {
    const target = event[2].Array[0].Ext;
    if (target.type == 0) { // Buffer
        const buf_num = try target.as_u32();
        if (self.buffers.get(buf_num)) |buf| {
            const name = event[1].RawString;
            const args = event[2].Array[1..];
            switch (try buf.rpc_method(name, args)) {
                .Changed => {
                    try self.debounce.update(buf_num);
                },
                .Done => {
                    buf.deinit();
                    self.alloc.destroy(buf);
                    _ = self.buffers.remove(buf_num);
                },
                .Okay => {},
            }
        } else {
            std.log.warn("Invalid buffer: {}\n", .{buf_num});
        }
    } else {
        std.log.warn("Unknown method target: {}\n", .{target.type});
    }
}

fn fp_buf_new(self: *Self, args: []const msgpack.Value) !void {
    try self.attach_buffer(@as(u32, args[0].UInt));
}

fn call_fp(self: *Self, event: []const msgpack.Value) !void {
    const args_ = event[2].Array;
    const name = args_[0].RawString;
    const args = args_[1..];

    // Work around issue #4639 by storing opts in a variable

    inline for (@typeInfo(Self).@"struct".decls) |s| {
        // Same trick as call_api
        const is_fp = comptime std.mem.startsWith(u8, s.name, "fp_");
        if (is_fp) {
            if (std.mem.eql(u8, name, s.name[3..])) {
                return @call(
                    .default,
                    @field(Self, s.name),
                    .{ self, args },
                );
            }
        }
    }
    std.log.warn("[Tui] Unknown Fp event: {s}\n", .{name});
}

fn call_api(self: *Self, event: []const msgpack.Value) !void {
    // For each command in the incoming stream, try to match
    // it against a local api_XYZ declaration.
    for (event[2].Array) |cmd| {
        var matched = false;
        const api_name = cmd.Array[0].RawString;
        inline for (@typeInfo(Self).@"struct".decls) |s| {
            // This conditional should be optimized out, since
            // it's known at comptime.
            const is_api = comptime std.mem.startsWith(u8, s.name, "api_");
            if (is_api) {
                if (std.mem.eql(u8, api_name, s.name[4..])) {
                    for (cmd.Array[1..]) |v| {
                        @call(
                            .default,
                            @field(Self, s.name),
                            .{ self, v.Array },
                        );
                    }
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            std.log.warn("[Tui] Unimplemented API: {s}\n", .{api_name});
        }
    }
}

pub fn tick(self: *Self) !bool {
    if (false) {
        while (self.rpc.get_event()) |event| {
            defer self.rpc.release(event);
            if (event == .Int) {
                return false;
            }

            // Methods are called on Ext objects (buffers, windows, etc)
            if (event.Array[2].Array[0] == .Ext) {
                try self.call_method(event.Array);
            }
            // We attach a few autocommands to rpcnotify(0, 'Fp', ...), which
            // are handled here.
            else if (std.mem.eql(u8, "Fp", event.Array[1].RawString)) {
                try self.call_fp(event.Array);
            }
            // Otherwise, we compare against a list of implemented APIs, by
            // doing a comptime unrolled loop that finds api_XYZ functions
            // and compares against them by name.
            else {
                try self.call_api(event.Array);
            }
        }

        if (self.uniforms_changed) {
            self.uniforms_changed = false;
            // self.renderer.update_uniforms(&self.u);
        }

        // Work around a potential deadlock: if nvim is in a blocking mode,
        // then we can't use nvim_command, so we defer handling the shaders
        // until then.
        const mode = (try self.rpc.call("nvim_get_mode", .{}));
        defer self.rpc.release(mode);
        const key = msgpack.Key{ .RawString = "blocking" };
        const blocking = mode.Map.get(key) orelse
            std.debug.panic("Could not get 'blocking'", .{});
        if (!blocking.Boolean) {
            if (self.debounce.check()) |buf_num| {
                // Check that the target buffer hasn't been deleted during the
                // debouncing delay time.  If it exists, then try to compile
                // it as a shader and load it into the preview pane.
                if (self.buffers.get(buf_num)) |buf| {
                    const shader_text = try buf.to_buf();
                    defer self.alloc.free(shader_text);
                    try self.rebuild_preview(buf_num, shader_text);
                }
            }
        }
    }

    self.renderer.redraw(self.total_tiles);

    return true;
}

fn rebuild_preview(self: *Self, buf_num: u32, shader_text: []const u8) !void {
    std.log.info("Rebuilding preview for buffer {}\n", .{buf_num});
    // const out = try shaderc.build_preview_shader(
    //     self.alloc,
    //     self.compiler,
    //     shader_text,
    // );
    // defer out.deinit(self.alloc);

    // Clear all of the error markers before compiling the shader
    try self.rpc.call_release("nvim_command", .{":sign unplace *"});

    // Clear the quick-fix list
    try self.rpc.call_release("nvim_command", .{":lexpr \"\""});

    // switch (out) {
    //     .Shader => |s| {
    try self.renderer.setPreview(self.alloc, shader_text);
    try self.rpc.call_release("nvim_command", .{":lclose"});
    //     },
    //     .Error => |e| {
    //         var arena = std.heap.ArenaAllocator.init(self.alloc.*);
    //         var all = arena.allocator();
    //         const tmp_alloc: *std.mem.Allocator = &all;
    //         defer arena.deinit();
    //
    //         self.renderer.clear_preview(self.alloc);
    //
    //         for (e.errs) |line_err| {
    //             var line_num: u32 = 1;
    //             if (line_err.line) |n| {
    //                 line_num = n;
    //             }
    //             const cmd = try std.fmt.allocPrint(
    //                 tmp_alloc.*,
    //                 ":sign place {} line={} name=fpErr buffer={}",
    //                 .{
    //                     line_num,
    //                     line_num,
    //                     buf_num,
    //                 },
    //             );
    //             try self.rpc.call_release("nvim_command", .{cmd});
    //
    //             const lexp = try std.fmt.allocPrint(
    //                 tmp_alloc.*,
    //                 ":ladd \"{}:{s}\"",
    //                 .{ line_num, line_err.msg },
    //             );
    //             try self.rpc.call_release("nvim_command", .{lexp});
    //         }
    //         try self.rpc.call_release("nvim_command", .{":lopen"});
    //         try self.rpc.call_release("nvim_command", .{":silent! wincmd p"});
    //     },
    // }
}

pub fn run(self: *Self) !void {
    while (!self.window.closing() and (try self.tick())) {
        c.glfwWaitEvents();
    }

    // Halt the subprocess, then clean out any remaining items in the queue
    _ = try self.rpc.halt(); // Ignore return code
}

pub fn update_size(self: *Self, width: c_int, height: c_int) void {
    self.u.width_px = @as(u32, @intCast(width));
    self.u.height_px = @as(u32, @intCast(height));

    self.renderer.resize(self.u.width_px, self.u.height_px);
    // self.renderer.update_uniforms(&self.u);

    if (false) {
        const density = self.u.width_px / self.window.getWidth();
        if (density != self.pixel_density) {
            self.pixel_density = density;

            self.font.deinit();
            self.font = FtAtlas.build_atlas(
                self.alloc,
                FONT_NAME,
                FONT_SIZE * self.pixel_density,
                512,
            ) catch |err| {
                std.debug.panic("Could not rebuild font: {}\n", .{err});
            };
            self.u.font = self.font.u;
            self.renderer.update_font_tex(&self.font);
        }

        const cursor_x = self.char_grid[self.total_tiles];
        const cursor_y = self.char_grid[self.total_tiles + 1];

        self.x_tiles = self.u.width_px / self.u.font.glyph_advance / 2;
        self.y_tiles = self.u.height_px / self.u.font.glyph_height;
        self.total_tiles = self.x_tiles * self.y_tiles;

        self.rpc.call_release(
            "nvim_ui_try_resize",
            .{ self.x_tiles, self.y_tiles },
        ) catch |err| {
            std.debug.panic("Failed to resize UI: {}\n", .{err});
        };

        self.char_grid[self.total_tiles] = cursor_x;
        self.char_grid[self.total_tiles + 1] = cursor_y;

        const r = self.tick() catch |err| {
            std.debug.panic("Failed to tick: {}\n", .{err});
        };

        // Resizing the window shouldn't ever cause the nvim process to exit
        std.debug.assert(r);
    }
}

fn get_ascii_lower(key: c_int) ?u8 {
    if (key >= 1 and key <= 127) {
        const char = @as(u8, @intCast(key));
        if (char >= 'A' and char <= 'Z') {
            return char + ('a' - 'A');
        } else {
            return char;
        }
    }
    return null;
}

fn get_ascii(key: c_int, mods: c_int) ?u8 {
    if (get_ascii_lower(key)) |char| {
        return if ((mods & c.GLFW_MOD_SHIFT) != 0) to_upper(char) else char;
    }
    return null;
}

fn to_upper(key: u8) u8 {
    // This assumes a US-EN keyboard
    return switch (key) {
        'a'...'z' => key - ('a' - 'A'),
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        else => key,
    };
}

fn get_encoded(key: c_int) ?([]const u8) {
    return switch (key) {
        c.GLFW_KEY_ENTER => "Enter",
        c.GLFW_KEY_ESCAPE => "Esc",
        c.GLFW_KEY_TAB => "Tab",
        c.GLFW_KEY_BACKSPACE => "BS",
        c.GLFW_KEY_INSERT => "Insert",
        c.GLFW_KEY_DELETE => "Del",
        c.GLFW_KEY_RIGHT => "Right",
        c.GLFW_KEY_LEFT => "Left",
        c.GLFW_KEY_DOWN => "Down",
        c.GLFW_KEY_UP => "Up",
        c.GLFW_KEY_PAGE_UP => "PageUp",
        c.GLFW_KEY_PAGE_DOWN => "PageDown",
        c.GLFW_KEY_HOME => "Home",
        c.GLFW_KEY_END => "End",

        c.GLFW_KEY_F1 => "F1",
        c.GLFW_KEY_F2 => "F2",
        c.GLFW_KEY_F3 => "F3",
        c.GLFW_KEY_F4 => "F4",
        c.GLFW_KEY_F5 => "F5",
        c.GLFW_KEY_F6 => "F6",
        c.GLFW_KEY_F7 => "F7",
        c.GLFW_KEY_F8 => "F8",
        c.GLFW_KEY_F9 => "F9",
        c.GLFW_KEY_F10 => "F10",
        c.GLFW_KEY_F11 => "F11",
        c.GLFW_KEY_F12 => "F12",

        c.GLFW_KEY_KP_0 => "k0",
        c.GLFW_KEY_KP_1 => "k1",
        c.GLFW_KEY_KP_2 => "k2",
        c.GLFW_KEY_KP_3 => "k3",
        c.GLFW_KEY_KP_4 => "k4",
        c.GLFW_KEY_KP_5 => "k5",
        c.GLFW_KEY_KP_6 => "k6",
        c.GLFW_KEY_KP_7 => "k7",
        c.GLFW_KEY_KP_8 => "k8",
        c.GLFW_KEY_KP_9 => "k9",
        c.GLFW_KEY_KP_DECIMAL => "kPoint",
        c.GLFW_KEY_KP_DIVIDE => "kDivide",
        c.GLFW_KEY_KP_MULTIPLY => "kMultiply",
        c.GLFW_KEY_KP_SUBTRACT => "kSubtract",
        c.GLFW_KEY_KP_ADD => "kAdd",
        c.GLFW_KEY_KP_ENTER => "kEnter",
        c.GLFW_KEY_KP_EQUAL => "kEqual",

        else => null,
    };
}

fn skip_key(key: c_int) bool {
    return switch (key) {
        c.GLFW_KEY_LEFT_SHIFT,
        c.GLFW_KEY_LEFT_CONTROL,
        c.GLFW_KEY_LEFT_ALT,
        c.GLFW_KEY_LEFT_SUPER,
        c.GLFW_KEY_RIGHT_SHIFT,
        c.GLFW_KEY_RIGHT_CONTROL,
        c.GLFW_KEY_RIGHT_ALT,
        c.GLFW_KEY_RIGHT_SUPER,
        => true,
        else => false,
    };
}

// Helper function to convert a mod bitfield into a string
// alloc must be an arena allocator, for ease of memory management
fn encode_mods(alloc: *std.mem.Allocator, mods: c_int) ![]const u8 {
    var out = try std.fmt.allocPrint(alloc.*, "", .{});
    std.debug.assert(out.len == 0);
    const a = alloc.*;

    if ((mods & c.GLFW_MOD_SHIFT) != 0) {
        out = try std.fmt.allocPrint(a, "S-{s}", .{out});
    }
    if ((mods & c.GLFW_MOD_CONTROL) != 0) {
        out = try std.fmt.allocPrint(a, "C-{s}", .{out});
    }
    if ((mods & c.GLFW_MOD_ALT) != 0) {
        out = try std.fmt.allocPrint(a, "A-{s}", .{out});
    }
    if ((mods & c.GLFW_MOD_SUPER) != 0) {
        out = try std.fmt.allocPrint(a, "D-{s}", .{out});
    }
    return out;
}

fn shortcut(self: *Self, key: c_int, mods: c_int) !bool {
    if (key == c.GLFW_KEY_V and mods == c.GLFW_MOD_SUPER) {
        const s = paste.get_clipboard();
        const i = std.mem.indexOfSentinel(u8, 0, s);
        try self.rpc.call_release("nvim_input", .{s[0..i]});
        return true;
    }
    return false;
}

pub fn on_key(self: *Self, key: c_int, mods: c_int) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc.*);
    var all = arena.allocator();
    const alloc: *std.mem.Allocator = &all;
    defer arena.deinit();

    var char_str = [1]u8{0};
    var str: ?[]const u8 = null;

    if (skip_key(key)) {
        // Nothing to do here
    } else if (try self.shortcut(key, mods)) {
        // Nothing to do here either
    } else if (get_ascii(key, mods)) |char| {
        if (char == '<') {
            str = "<LT>";
        } else {
            char_str[0] = char;
            str = &char_str;
        }

        const mods_ = mods & (~@as(c_int, c.GLFW_MOD_SHIFT));
        if (mods_ != 0) {
            const mod_str = try encode_mods(alloc, mods_);
            std.debug.assert(mod_str.len != 0);
            str = try std.fmt.allocPrint(alloc.*, "<{s}{?s}>", .{ mod_str, str });
        }
    } else if (get_encoded(key)) |enc| {
        if (mods == 0) {
            str = try std.fmt.allocPrint(alloc.*, "<{s}>", .{enc});
        } else {
            const mod_str = try encode_mods(alloc, mods);
            str = try std.fmt.allocPrint(alloc.*, "<{s}{s}>", .{ mod_str, enc });
        }
    } else {
        std.debug.print("Got unknown key {} {}\n", .{ key, mods });
    }

    if (str) |s| {
        try self.rpc.call_release("nvim_input", .{s});
    }
}

pub fn on_mouse_pos(self: *Self, x: f64, y: f64) !void {
    self.mouse_tile_x = @as(i32, @intFromFloat(x));
    self.mouse_tile_y = @as(i32, @intFromFloat(y));
}

pub fn on_scroll(self: *Self, dx: f64, dy: f64) !void {
    _ = dx;
    // Reset accumulator if we've changed directions
    if (self.mouse_scroll_y != 0 and std.math.signbit(dy) != std.math.signbit(self.mouse_scroll_y)) {
        self.mouse_scroll_y = 0;
    }
    self.mouse_scroll_y += dy;
    while (@abs(self.mouse_scroll_y) >= SCROLL_THRESHOLD) {
        const dir = if (self.mouse_scroll_y > 0) "up" else "down";
        if (self.mouse_scroll_y > 0) {
            self.mouse_scroll_y -= SCROLL_THRESHOLD;
        } else {
            self.mouse_scroll_y += SCROLL_THRESHOLD;
        }
        self.rpc.call_release("nvim_input_mouse", .{
            "wheel",
            dir,
            "", // mods
            0, // grid
            self.mouse_tile_y, // row
            self.mouse_tile_x, // col
        }) catch |err| {
            std.debug.panic("Failed to call nvim_input_mouse: {}", .{err});
        };
    }
}

pub fn on_mouse_button(self: *Self, button: c_int, action: c_int, mods: c_int) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc.*);
    var all = arena.allocator();
    const alloc: *std.mem.Allocator = &all;
    defer arena.deinit();

    const button_str = switch (button) {
        c.GLFW_MOUSE_BUTTON_LEFT => "left",
        c.GLFW_MOUSE_BUTTON_RIGHT => "right",
        c.GLFW_MOUSE_BUTTON_MIDDLE => "middle",
        else => |_| {
            // std.log.warn("Ignoring unknown mouse: {}\n", .{b});
            // return;
            unreachable;
        },
    };

    const action_str = switch (action) {
        c.GLFW_PRESS => "press",
        c.GLFW_RELEASE => "release",
        else => |b| std.debug.panic("Invalid mouse action: {}\n", .{b}),
    };

    const mods_str = try encode_mods(alloc, mods);
    try self.rpc.call_release("nvim_input_mouse", .{
        button_str,
        action_str,
        mods_str,
        0, // grid
        self.mouse_tile_y, // row
        self.mouse_tile_x, // col
    });
}

// -----------------------------------------------------------------------------
//
export fn size_cb(w: ?*c.GLFWwindow, width: c_int, height: c_int) void {
    const ptr = c.glfwGetWindowUserPointer(w) orelse std.debug.panic("Missing user pointer", .{});
    const tui: *Tui = @ptrCast(@alignCast(ptr));
    tui.update_size(width, height);
}

export fn key_cb(w: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) void {
    _ = scancode;

    const ptr = c.glfwGetWindowUserPointer(w) orelse std.debug.panic("Missing user pointer", .{});
    const tui: *Tui = @ptrCast(@alignCast(ptr));
    if (action == c.GLFW_PRESS or action == c.GLFW_REPEAT) {
        tui.on_key(key, mods) catch |err| {
            std.debug.print("Failed on_key: {}\n", .{err});
        };
    }
}

export fn mouse_pos_cb(w: ?*c.GLFWwindow, x: f64, y: f64) void {
    const ptr = c.glfwGetWindowUserPointer(w) orelse std.debug.panic("Missing user pointer", .{});
    const tui: *Tui = @ptrCast(@alignCast(ptr));
    tui.on_mouse_pos(x, y) catch |err| {
        std.debug.print("Failed on_mouse_pos: {}\n", .{err});
    };
}

export fn mouse_button_cb(w: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) void {
    const ptr = c.glfwGetWindowUserPointer(w) orelse std.debug.panic("Missing user pointer", .{});
    const tui: *Tui = @ptrCast(@alignCast(ptr));
    tui.on_mouse_button(button, action, mods) catch |err| {
        std.debug.print("Failed on_mouse_button: {}\n", .{err});
    };
}

export fn scroll_cb(w: ?*c.GLFWwindow, dx: f64, dy: f64) void {
    const ptr = c.glfwGetWindowUserPointer(w) orelse std.debug.panic("Missing user pointer", .{});
    const tui: *Tui = @ptrCast(@alignCast(ptr));
    tui.on_scroll(dx, dy) catch |err| {
        std.debug.print("Failed on_scroll: {}\n", .{err});
    };
}
