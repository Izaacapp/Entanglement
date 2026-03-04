#!/usr/bin/env perl
# scaffold.pl - Generate Zig project structure for Sniper TUI
# Reads OpenCode Go source as reference, outputs Zig module stubs
use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename;

my $root = dirname(dirname(__FILE__));
my $src  = "$root/src";

# Module map: Zig source files to generate
my %modules = (
    'main.zig'       => \&gen_main,
    'tui.zig'        => \&gen_tui,
    'chat.zig'       => \&gen_chat,
    'editor.zig'     => \&gen_editor,
    'status.zig'     => \&gen_status,
    'http.zig'       => \&gen_http,
    'config.zig'     => \&gen_config,
    'theme.zig'      => \&gen_theme,
    'markdown.zig'   => \&gen_markdown,
    'layout.zig'     => \&gen_layout,
);

print "Scaffolding Sniper TUI in $src\n";
make_path($src) unless -d $src;

for my $file (sort keys %modules) {
    my $path = "$src/$file";
    if (-f $path) {
        print "  SKIP $file (exists)\n";
        next;
    }
    open my $fh, '>', $path or die "Can't write $path: $!\n";
    print $fh $modules{$file}->();
    close $fh;
    print "  CREATED $file\n";
}

# Generate build.zig.zon
my $zon = "$root/build.zig.zon";
unless (-f $zon) {
    open my $fh, '>', $zon or die "Can't write $zon: $!\n";
    print $fh gen_zon();
    close $fh;
    print "  CREATED build.zig.zon\n";
}

# Generate build.zig
my $build = "$root/build.zig";
unless (-f $build) {
    open my $fh, '>', $build or die "Can't write $build: $!\n";
    print $fh gen_build();
    close $fh;
    print "  CREATED build.zig\n";
}

print "\nDone. Run: cd $root && zig build\n";

# ─── Generators ───────────────────────────────────────────

sub gen_main { return <<'ZIG';
const std = @import("std");
const config = @import("config.zig");
const tui = @import("tui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    var app = try tui.App.init(allocator, cfg);
    defer app.deinit();

    try app.run();
}
ZIG
}

sub gen_tui { return <<'ZIG';
const std = @import("std");
const config = @import("config.zig");
const chat = @import("chat.zig");
const editor = @import("editor.zig");
const status = @import("status.zig");
const theme = @import("theme.zig");
const layout = @import("layout.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    tty: std.posix.fd_t,
    width: u16,
    height: u16,
    chat_view: chat.ChatView,
    editor_view: editor.Editor,
    status_bar: status.StatusBar,
    running: bool,
    original_termios: std.posix.termios,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !App {
        const tty = std.io.getStdIn().handle;
        var original = try std.posix.tcgetattr(tty);
        var raw = original;

        // Raw mode
        raw.lflag = raw.lflag.unset(.{
            .ECHO = true,
            .ICANON = true,
            .ISIG = true,
            .IEXTEN = true,
        });
        raw.iflag = raw.iflag.unset(.{
            .IXON = true,
            .ICRNL = true,
            .BRKINT = true,
            .INPCK = true,
            .ISTRIP = true,
        });
        raw.cflag = raw.cflag.set(.{ .CS8 = true });
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(tty, .FLUSH, raw);

        const size = try layout.getTermSize(tty);

        const writer = std.io.getStdOut().writer();
        // Enter alt screen, hide cursor, enable mouse
        try writer.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h");

        return App{
            .allocator = allocator,
            .cfg = cfg,
            .tty = tty,
            .width = size.cols,
            .height = size.rows,
            .chat_view = chat.ChatView.init(allocator),
            .editor_view = editor.Editor.init(allocator),
            .status_bar = status.StatusBar.init(cfg),
            .running = true,
            .original_termios = original,
        };
    }

    pub fn deinit(self: *App) void {
        const writer = std.io.getStdOut().writer();
        // Exit alt screen, show cursor, disable mouse
        writer.writeAll("\x1b[?1003l\x1b[?1006l\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(self.tty, .FLUSH, self.original_termios) catch {};
        self.chat_view.deinit();
        self.editor_view.deinit();
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            try self.render();
            try self.handleInput();
        }
    }

    fn render(self: *App) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        const t = theme.current;

        // Clear and position
        try w.writeAll("\x1b[H");

        // Chat area (top)
        const chat_height = self.height - 6; // editor + status
        try self.chat_view.render(w, self.width, chat_height, t);

        // Separator
        try layout.renderHLine(w, self.width, t.border);

        // Editor (bottom)
        try self.editor_view.render(w, self.width, 4, t);

        // Status bar
        try self.status_bar.render(w, self.width, t);

        try std.io.getStdOut().writeAll(buf.items);
    }

    fn handleInput(self: *App) !void {
        var buf: [32]u8 = undefined;
        const n = try std.posix.read(self.tty, &buf);
        if (n == 0) return;

        const input = buf[0..n];

        // Ctrl+C quit
        if (input[0] == 3) {
            self.running = false;
            return;
        }

        // Enter - send message
        if (input[0] == '\r' or input[0] == '\n') {
            const msg = self.editor_view.getText();
            if (msg.len > 0) {
                try self.chat_view.addUserMessage(msg);
                self.editor_view.clear();
                self.status_bar.setStatus("Thinking...");
                try self.render();

                // Stream response from server
                const http_mod = @import("http.zig");
                try http_mod.streamChat(
                    self.allocator,
                    self.cfg,
                    self.chat_view.getMessages(),
                    &self.chat_view,
                    self,
                );
                self.status_bar.setStatus("Ready");
            }
            return;
        }

        // Forward to editor
        try self.editor_view.handleInput(input);
    }
};
ZIG
}

sub gen_chat { return <<'ZIG';
const std = @import("std");
const theme = @import("theme.zig");

pub const Role = enum { user, assistant, system };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ChatView = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    scroll_offset: usize,

    pub fn init(allocator: std.mem.Allocator) ChatView {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message).init(allocator),
            .scroll_offset = 0,
        };
    }

    pub fn deinit(self: *ChatView) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
    }

    pub fn addUserMessage(self: *ChatView, text: []const u8) !void {
        const content = try self.allocator.dupe(u8, text);
        try self.messages.append(.{ .role = .user, .content = content });
    }

    pub fn appendAssistantChunk(self: *ChatView, chunk: []const u8) !void {
        if (self.messages.items.len > 0) {
            const last = &self.messages.items[self.messages.items.len - 1];
            if (last.role == .assistant) {
                const new_content = try std.mem.concat(self.allocator, u8, &.{ last.content, chunk });
                self.allocator.free(last.content);
                last.content = new_content;
                return;
            }
        }
        const content = try self.allocator.dupe(u8, chunk);
        try self.messages.append(.{ .role = .assistant, .content = content });
    }

    pub fn getMessages(self: *ChatView) []const Message {
        return self.messages.items;
    }

    pub fn render(self: *ChatView, writer: anytype, width: u16, height: u16, t: theme.Theme) !void {
        _ = height;
        for (self.messages.items) |msg| {
            const label = switch (msg.role) {
                .user => t.user_label,
                .assistant => t.assistant_label,
                .system => t.system_label,
            };
            // Role label
            try writer.print("\x1b[{s}m{s}\x1b[0m\r\n", .{ label, @tagName(msg.role) });

            // Content with word wrap
            var col: u16 = 0;
            for (msg.content) |c| {
                if (c == '\n') {
                    try writer.writeAll("\r\n");
                    col = 0;
                } else {
                    try writer.writeByte(c);
                    col += 1;
                    if (col >= width) {
                        try writer.writeAll("\r\n");
                        col = 0;
                    }
                }
            }
            try writer.writeAll("\r\n\r\n");
        }
    }
};
ZIG
}

sub gen_editor { return <<'ZIG';
const std = @import("std");
const theme = @import("theme.zig");

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor: usize,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .cursor = 0,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
    }

    pub fn getText(self: *Editor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn handleInput(self: *Editor, input: []const u8) !void {
        // Backspace
        if (input[0] == 127 or input[0] == 8) {
            if (self.cursor > 0) {
                _ = self.buffer.orderedRemove(self.cursor - 1);
                self.cursor -= 1;
            }
            return;
        }

        // Escape sequences (arrows etc)
        if (input.len >= 3 and input[0] == 27 and input[1] == '[') {
            switch (input[2]) {
                'D' => { // Left
                    if (self.cursor > 0) self.cursor -= 1;
                },
                'C' => { // Right
                    if (self.cursor < self.buffer.items.len) self.cursor += 1;
                },
                else => {},
            }
            return;
        }

        // Regular character
        if (input[0] >= 32 and input[0] < 127) {
            try self.buffer.insert(self.cursor, input[0]);
            self.cursor += 1;
        }
    }

    pub fn render(self: *Editor, writer: anytype, width: u16, height: u16, t: theme.Theme) !void {
        _ = height;
        // Prompt
        try writer.print("\x1b[{s}m > \x1b[0m", .{t.prompt_style});

        // Buffer content
        const max_visible = @as(usize, width) -| 4;
        const start = if (self.buffer.items.len > max_visible) self.buffer.items.len - max_visible else 0;
        const visible = self.buffer.items[start..];
        try writer.writeAll(visible);

        // Cursor
        try writer.writeAll("\x1b[?25h"); // show cursor

        // Clear rest of line
        try writer.writeAll("\x1b[K\r\n");
    }
};
ZIG
}

sub gen_status { return <<'ZIG';
const std = @import("std");
const config = @import("config.zig");
const theme = @import("theme.zig");

pub const StatusBar = struct {
    cfg: config.Config,
    message: []const u8,

    pub fn init(cfg: config.Config) StatusBar {
        return .{
            .cfg = cfg,
            .message = "Ready",
        };
    }

    pub fn setStatus(self: *StatusBar, msg: []const u8) void {
        self.message = msg;
    }

    pub fn render(self: *StatusBar, writer: anytype, width: u16, t: theme.Theme) !void {
        // Status bar background
        try writer.print("\x1b[{s}m", .{t.status_bg});

        // Left: model name
        try writer.print(" sniper | {s}", .{self.cfg.model});

        // Right: status message
        const left_len = 11 + self.cfg.model.len;
        const right_start = if (width > left_len + self.message.len + 2)
            width - self.message.len - 2
        else
            left_len + 2;

        var i: u16 = @intCast(left_len);
        while (i < right_start) : (i += 1) {
            try writer.writeByte(' ');
        }
        try writer.print("{s} ", .{self.message});
        try writer.writeAll("\x1b[0m");
    }
};
ZIG
}

sub gen_http { return <<'ZIG';
const std = @import("std");
const config = @import("config.zig");
const chat = @import("chat.zig");

const ChatPayload = struct {
    model: []const u8,
    messages: []const ApiMessage,
    stream: bool,
};

const ApiMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub fn streamChat(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    messages: []const chat.Message,
    chat_view: *chat.ChatView,
    app: anytype,
) !void {
    var api_messages = std.ArrayList(ApiMessage).init(allocator);
    defer api_messages.deinit();

    for (messages) |msg| {
        try api_messages.append(.{
            .role = @tagName(msg.role),
            .content = msg.content,
        });
    }

    const payload = ChatPayload{
        .model = cfg.model,
        .messages = api_messages.items,
        .stream = true,
    };

    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    try std.json.stringify(payload, .{}, payload_buf.writer());

    // Build URL
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{cfg.endpoint});

    // HTTP request
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.open(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload_buf.items.len };
    try req.send();
    try req.writeAll(payload_buf.items);
    try req.finish();
    try req.wait();

    // Read SSE stream
    var line_buf: [4096]u8 = undefined;
    const reader = req.reader();
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const data = line["data: ".len..];
        if (std.mem.eql(u8, data, "[DONE]")) break;

        // Parse JSON chunk
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("choices")) |choices| {
            if (choices.array.items.len > 0) {
                const delta = choices.array.items[0].object.get("delta") orelse continue;
                if (delta.object.get("content")) |content| {
                    switch (content) {
                        .string => |s| {
                            try chat_view.appendAssistantChunk(s);
                            try app.render();
                        },
                        else => {},
                    }
                }
            }
        }
    }
}
ZIG
}

sub gen_config { return <<'ZIG';
const std = @import("std");

pub const Config = struct {
    endpoint: []const u8,
    model: []const u8,
    host: []const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    _ = allocator;

    // Read from .env or env vars
    const endpoint = std.posix.getenv("SNIPER_ENDPOINT") orelse
        std.posix.getenv("OLLAMA_HOST") orelse
        "http://192.168.1.241:11434/v1";

    const model = std.posix.getenv("SNIPER_MODEL") orelse "deepseek-r1:8b";
    const host = std.posix.getenv("SSH_HOST") orelse "192.168.1.241";

    return Config{
        .endpoint = endpoint,
        .model = model,
        .host = host,
    };
}
ZIG
}

sub gen_theme { return <<'ZIG';
pub const Theme = struct {
    border: []const u8,
    user_label: []const u8,
    assistant_label: []const u8,
    system_label: []const u8,
    prompt_style: []const u8,
    status_bg: []const u8,
};

pub const current = Theme{
    // Catppuccin-inspired
    .border = "38;5;240",
    .user_label = "1;38;5;183",        // Bold lavender
    .assistant_label = "1;38;5;156",    // Bold green
    .system_label = "1;38;5;180",       // Bold yellow
    .prompt_style = "1;38;5;117",       // Bold blue
    .status_bg = "48;5;236;38;5;252",   // Dark gray bg, light text
};

pub const gruvbox = Theme{
    .border = "38;5;241",
    .user_label = "1;38;5;214",
    .assistant_label = "1;38;5;142",
    .system_label = "1;38;5;208",
    .prompt_style = "1;38;5;109",
    .status_bg = "48;5;237;38;5;223",
};

pub const tokyo_night = Theme{
    .border = "38;5;237",
    .user_label = "1;38;5;111",
    .assistant_label = "1;38;5;114",
    .system_label = "1;38;5;179",
    .prompt_style = "1;38;5;147",
    .status_bg = "48;5;234;38;5;189",
};
ZIG
}

sub gen_markdown { return <<'ZIG';
const std = @import("std");

/// Strip <think>...</think> blocks from DeepSeek R1 output
pub fn stripThinkBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "<think>")) {
            // Skip until </think>
            if (std.mem.indexOf(u8, input[i..], "</think>")) |end| {
                i += end + "</think>".len;
                continue;
            } else {
                break; // Still thinking, skip rest
            }
        }
        try result.append(input[i]);
        i += 1;
    }
    return result.toOwnedSlice();
}

/// Basic code block detection for syntax highlighting
pub fn isCodeBlock(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```");
}
ZIG
}

sub gen_layout { return <<'ZIG';
const std = @import("std");

pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

pub fn getTermSize(fd: std.posix.fd_t) !TermSize {
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc != 0) {
        return TermSize{ .rows = 24, .cols = 80 };
    }
    return TermSize{ .rows = wsz.ws_row, .cols = wsz.ws_col };
}

pub fn renderHLine(writer: anytype, width: u16, color: []const u8) !void {
    try writer.print("\x1b[{s}m", .{color});
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        try writer.writeAll("─");
    }
    try writer.writeAll("\x1b[0m\r\n");
}

pub fn renderBox(writer: anytype, content: []const u8, width: u16, color: []const u8) !void {
    try writer.print("\x1b[{s}m╭", .{color});
    var i: u16 = 0;
    while (i < width -| 2) : (i += 1) try writer.writeAll("─");
    try writer.writeAll("╮\x1b[0m\r\n");

    try writer.print("\x1b[{s}m│\x1b[0m {s}", .{ color, content });
    const content_len: u16 = @intCast(@min(content.len, width));
    i = content_len + 2;
    while (i < width -| 1) : (i += 1) try writer.writeByte(' ');
    try writer.print("\x1b[{s}m│\x1b[0m\r\n", .{color});

    try writer.print("\x1b[{s}m╰", .{color});
    i = 0;
    while (i < width -| 2) : (i += 1) try writer.writeAll("─");
    try writer.writeAll("╯\x1b[0m\r\n");
}
ZIG
}

sub gen_zon { return <<'ZIG';
.{
    .name = .{ .override = "sniper" },
    .version = .{ 0, 1, 0 },
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
ZIG
}

sub gen_build { return <<'ZIG';
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sniper",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run sniper");
    run_step.dependOn(&run_cmd.step);
}
ZIG
}
