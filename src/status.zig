const std = @import("std");
const config = @import("config.zig");
const theme = @import("theme.zig");

pub const StatusBar = struct {
    cfg: config.Config,
    message: []const u8,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    context_limit: u32 = 32768,

    pub fn init(cfg: config.Config) StatusBar {
        return .{
            .cfg = cfg,
            .message = "Ready",
        };
    }

    pub fn setStatus(self: *StatusBar, msg: []const u8) void {
        self.message = msg;
    }

    pub fn updateTokens(self: *StatusBar, prompt: u32, completion: u32) void {
        self.prompt_tokens = prompt;
        self.completion_tokens = completion;
    }

    pub fn render(self: *StatusBar, writer: anytype, width: u16, t: theme.Theme) !void {
        // Status bar background
        try writer.print("\x1b[{s}m", .{t.status_bg});

        // Left: model name + theme
        try writer.print(" sniper | {s} | {s}", .{ self.cfg.model, theme.currentName() });

        var left_len: usize = 11 + self.cfg.model.len + 3 + theme.currentName().len;

        // Token count + context % if available
        if (self.prompt_tokens > 0 or self.completion_tokens > 0) {
            var tok_buf: [96]u8 = undefined;
            const ctx_pct = if (self.context_limit > 0)
                (self.prompt_tokens * 100) / self.context_limit
            else
                0;
            const tok_str = std.fmt.bufPrint(&tok_buf, " | {d}+{d}tok | ctx:{d}%", .{ self.prompt_tokens, self.completion_tokens, ctx_pct }) catch "";
            try writer.writeAll(tok_str);
            left_len += tok_str.len;
        }

        // Right: status message
        const w: usize = @intCast(width);
        const right_start = if (w > left_len + self.message.len + 2)
            w - self.message.len - 2
        else
            left_len + 2;

        var i: usize = left_len;
        while (i < right_start) : (i += 1) {
            try writer.writeByte(' ');
        }
        try writer.print("{s} ", .{self.message});
        try writer.writeAll("\x1b[0m");
    }
};
