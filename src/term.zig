const std = @import("std");
const builtin = @import("builtin");

pub const TermSize = struct {
    h: usize,
    w: usize,
};

pub const Stats = struct {
    original_w: usize,
    original_h: usize,
    new_w: usize,
    new_h: usize,
    fps: ?f32 = null,
};

const MAX_COLOR = 256;
const LAST_COLOR = MAX_COLOR - 1;

// ANSI escape codes
const ESC = "\x1B";
const CSI = ESC ++ "[";

const SHOW_CURSOR = CSI ++ "?25h";
const HIDE_CURSOR = CSI ++ "?25l";
const HOME_CURSOR = CSI ++ "1;1H";
const SAVE_CURSOR = ESC ++ "7";
const LOAD_CURSOR = ESC ++ "8";

const CLEAR_SCREEN = CSI ++ "2J";
const ALT_BUF_ENABLE = CSI ++ "?1049h";
const ALT_BUF_DISABLE = CSI ++ "?1049l";

const CLEAR_TO_EOL = CSI ++ "0K";

const RESET_COLOR = CSI ++ "0m";
const SET_FG_COLOR = "38;5";
const SET_BG_COLOR = "48;5";

const WHITE_FG = CSI ++ SET_FG_COLOR ++ ";15m";
const BLACK_BG = CSI ++ SET_BG_COLOR ++ ";0m";
const BLACK_FG = CSI ++ SET_FG_COLOR ++ ";0m";
const OG_COLOR = BLACK_BG ++ WHITE_FG;

const ASCII_TERM_ON = ALT_BUF_ENABLE ++ HIDE_CURSOR ++ HOME_CURSOR ++ CLEAR_SCREEN ++ RESET_COLOR;
const ASCII_TERM_OFF = ALT_BUF_DISABLE ++ SHOW_CURSOR ++ "\n";

// RGB ANSI escape codes
const RGB_FG = CSI ++ "38;2;";
const RGB_BG = CSI ++ "48;2;";

const TIOCGWINSZ = std.c.T.IOCGWINSZ;

allocator: std.mem.Allocator,
stdout: std.fs.File.Writer,
stdin: std.fs.File.Reader,
size: TermSize,
ascii_chars: []const u8,
stats: Stats,
buf: []u8,
buf_index: usize,
buf_len: usize,
init_frame: []u8,
// fg: [MAX_COLOR][]u8,
// bg: [MAX_COLOR][]u8,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, ascii_chars: []const u8) !Self {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const size = try getTermSize(std.io.getStdOut().handle);

    const char_size = ascii_chars.len;
    const color_size = RGB_FG.len + 12;
    const ascii_size = char_size + color_size;
    const screen_size: u64 = @intCast(ascii_size * size.w * size.h);
    const overflow_size: u64 = char_size * 100;
    const buf_size = screen_size + overflow_size;
    const buf = try allocator.alloc(u8, buf_size);

    const init_frame = std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ HOME_CURSOR, BLACK_BG, BLACK_FG },
    ) catch unreachable;

    const self = Self{
        .allocator = allocator,
        .stdout = stdout,
        .stdin = stdin,
        .size = size,
        .ascii_chars = ascii_chars,
        .stats = undefined,
        .buf = buf,
        .buf_index = 0,
        .buf_len = 0,
        .init_frame = init_frame,
        // .fg = undefined,
        // .bg = undefined,
    };

    // try self.initColor();
    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.buf);
    self.allocator.free(self.init_frame);
    // for (0..MAX_COLOR) |i| {
    //     self.allocator.free(self.fg[i]);
    //     self.allocator.free(self.bg[i]);
    // }
}

// fn initColor(self: *Self) !void {
//     for (0..MAX_COLOR) |color_idx| {
//         self.fg[color_idx] = try std.fmt.allocPrint(
//             self.allocator,
//             "{s}{d}m",
//             .{ CSI ++ SET_FG_COLOR ++ ";", color_idx },
//         );
//         self.bg[color_idx] = try std.fmt.allocPrint(
//             self.allocator,
//             "{s}{d}m",
//             .{ CSI ++ SET_BG_COLOR ++ ";", color_idx },
//         );
//     }
// }

pub fn enableAsciiMode(self: *Self) !void {
    try self.stdout.writeAll(ASCII_TERM_ON);
}

pub fn disableAsciiMode(self: *Self) !void {
    try self.stdout.writeAll(ASCII_TERM_OFF);
}

pub fn clear(self: *Self) !void {
    try self.stdout.writeAll(CLEAR_SCREEN);
    try self.stdout.writeAll(HOME_CURSOR);
}

fn resetBuffer(self: *Self) void {
    @memset(self.buf, 0);
    self.buf_index = 0;
    self.buf_len = 0;
}

fn writeToBuffer(self: *Self, s: []const u8) void {
    @memcpy(self.buf[self.buf_index..][0..s.len], s);
    self.buf_index += s.len;
    self.buf_len += s.len;
}

pub fn calculateAsciiDimensions(self: *Self, width: usize, height: usize) TermSize {
    const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const max_width = self.size.w - 2; // Account for left and right borders
    const max_height = (self.size.h - 4) * 2; // Account for top and bottom borders, and multiply by 2 for vertical resolution

    var ascii_width = max_width;
    var ascii_height = @as(usize, @intFromFloat(@as(f32, @floatFromInt(ascii_width)) / aspect_ratio)) * 2;

    if (ascii_height > max_height) {
        ascii_height = max_height;
        ascii_width = @as(usize, @intFromFloat(@as(f32, @floatFromInt(ascii_height)) * aspect_ratio / 2));
    }

    return .{ .w = ascii_width, .h = ascii_height / 2 };
}

pub fn drawBuf(self: *Self, s: []const u8) void {
    for (s) |b| {
        self.buf[self.buf_index] = b;
        self.buf_index += 1;
        self.buf_len += 1;
    }
}

pub fn renderAsciiArt(self: *Self, img: []const u8, width: usize, height: usize, channels: usize, color: bool) !void {
    const v_padding: usize = (self.size.h - height - 1) / 2; // Account for top and bottom borders
    // const h_padding: usize = (self.size.w - width - 2) / 2; // Account for left and right borders

    self.resetBuffer();
    self.writeToBuffer(self.init_frame);

    // Print top padding
    var i: usize = 0;
    while (i < v_padding) : (i += 1) {
        self.writeToBuffer("\n");
    }

    // Print top border
    // for (0..h_padding) |_| self.writeToBuffer(" ");
    // self.writeToBuffer("┌");
    // for (0..width) |_| self.writeToBuffer("-");
    // self.writeToBuffer("┐\n");

    var y: usize = 0;
    while (y < height) : (y += 1) {
        // for (0..h_padding) |_| self.writeToBuffer(" ");
        // self.writeToBuffer("│");

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = (y * width + x) * channels;

            const brightness = img[idx];
            const ascii_char = self.ascii_chars[brightness * self.ascii_chars.len / 256];

            if (color) {
                const r = img[idx];
                const g = img[idx + 1];
                const b = img[idx + 2];
                const color_code = try std.fmt.allocPrint(self.allocator, RGB_FG ++ "{d};{d};{d}m{c}" ++ RESET_COLOR, .{ r, g, b, ascii_char });
                defer self.allocator.free(color_code);
                self.writeToBuffer(color_code);
            } else {
                self.writeToBuffer(&[_]u8{ascii_char});
            }
        }

        // self.writeToBuffer("│\n");
        self.writeToBuffer("\n");
    }

    // Print bottom border
    // for (0..h_padding) |_| self.writeToBuffer(" ");
    // self.writeToBuffer("└");
    // for (0..width) |_| self.writeToBuffer("-");
    // self.writeToBuffer("┘\n");

    // Print bottom padding
    i = 0;
    while (i < v_padding) : (i += 1) {
        self.writeToBuffer("\n");
    }

    try self.flushBuffer();
    try self.printStats();
    self.resetBuffer();
}

fn getAsciiChar(self: *Self, upper: u8, lower: u8) u8 {
    const avg_brightness = (@as(u16, upper) + @as(u16, lower)) / 2;
    return self.ascii_chars[avg_brightness * self.ascii_chars.len / 256];
}

fn flushBuffer(self: *Self) !void {
    _ = try self.stdout.write(self.buf[0 .. self.buf_len - 1]);
}

pub fn printStats(self: *Self) !void {
    const original_aspect_ratio = @as(f32, @floatFromInt(self.stats.original_w)) / @as(f32, @floatFromInt(self.stats.original_h));
    const new_aspect_ratio = @as(f32, @floatFromInt(self.stats.new_w)) / @as(f32, @floatFromInt(self.stats.new_h));

    const stats_str = if (self.stats.fps) |fps|
        try std.fmt.allocPrint(self.allocator, "\nOriginal: {}x{} (AR: {d:.2}) | New: {}x{} (AR: {d:.2}) | FPS: {d:.2}", .{
            self.stats.original_w,
            self.stats.original_h,
            original_aspect_ratio,
            self.stats.new_w,
            self.stats.new_h,
            new_aspect_ratio,
            fps,
        })
    else
        try std.fmt.allocPrint(self.allocator, "\nOriginal: {}x{} (AR: {d:.2}) | New: {}x{} (AR: {d:.2}) | Term: {}x{} |", .{
            self.stats.original_w,
            self.stats.original_h,
            original_aspect_ratio,
            self.stats.new_w,
            self.stats.new_h,
            new_aspect_ratio,
            self.size.w,
            self.size.h,
        });
    defer self.allocator.free(stats_str);

    self.writeToBuffer(stats_str);
    try self.flushBuffer();
}

pub fn getTermSize(tty: std.posix.fd_t) !TermSize {
    switch (builtin.os.tag) {
        .windows => {
            const win32 = std.os.windows.kernel32;
            var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (win32.GetConsoleScreenBufferInfo(tty, &info) == 0) switch (win32.GetLastError()) {
                else => |e| return std.os.windows.unexpectedError(e),
            };
            return .{
                .h = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
                .w = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
            };
        },
        else => {
            var winsize = std.c.winsize{
                .ws_col = 0,
                .ws_row = 0,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };
            const ret_val = std.c.ioctl(tty, TIOCGWINSZ, @intFromPtr(&winsize));
            const err = std.posix.errno(ret_val);

            if (ret_val >= 0) {
                return .{
                    .h = winsize.ws_row,
                    .w = winsize.ws_col,
                };
            } else {
                return std.posix.unexpectedErrno(err);
            }
        },
    }
}
