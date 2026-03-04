const std = @import("std");
const theme = @import("theme.zig");

pub const DialogItem = struct {
    label: []const u8,
    value: []const u8,
};

pub const Dialog = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    items: []const DialogItem,
    selected: usize = 0,
    scroll_offset: usize = 0,
    visible: bool = false,

    pub fn init(allocator: std.mem.Allocator, title: []const u8, items: []const DialogItem) Dialog {
        return .{
            .allocator = allocator,
            .title = title,
            .items = items,
        };
    }

    pub fn moveUp(self: *Dialog) void {
        if (self.selected > 0) {
            self.selected -= 1;
            if (self.selected < self.scroll_offset) {
                self.scroll_offset = self.selected;
            }
        }
    }

    pub fn moveDown(self: *Dialog) void {
        if (self.selected + 1 < self.items.len) {
            self.selected += 1;
            const max_visible: usize = 10;
            if (self.selected >= self.scroll_offset + max_visible) {
                self.scroll_offset = self.selected - max_visible + 1;
            }
        }
    }

    pub fn getSelected(self: *Dialog) ?DialogItem {
        if (self.items.len == 0) return null;
        return self.items[self.selected];
    }

    pub fn render(self: *Dialog, writer: anytype, term_width: u16, term_height: u16, t: theme.Theme) !void {
        if (!self.visible) return;

        const max_visible: usize = @min(self.items.len, 10);
        const visible_count = @min(max_visible, self.items.len - self.scroll_offset);
        const box_height: u16 = @intCast(visible_count + 4); // title + border + items + border
        const box_width: u16 = @min(term_width -| 4, 60);

        const start_row = (term_height -| box_height) / 2;
        const start_col = (term_width -| box_width) / 2;

        // Top border
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xad", .{ start_row, start_col, t.border });
        var i: u16 = 0;
        while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x95\xae\x1b[0m");

        // Title (with scroll indicators)
        const has_above = self.scroll_offset > 0;
        const has_below = self.scroll_offset + visible_count < self.items.len;
        if (has_above) {
            try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m \x1b[1m{s}\x1b[0m \xe2\x96\xb2", .{ start_row + 1, start_col, t.border, self.title });
        } else {
            try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m \x1b[1m{s}\x1b[0m", .{ start_row + 1, start_col, t.border, self.title });
        }
        // Fill rest of title line
        const title_extra: u16 = if (has_above) 2 else 0;
        const title_end = start_col + 3 + @as(u16, @intCast(@min(self.title.len, box_width))) + title_extra;
        var j: u16 = title_end;
        while (j < start_col + box_width -| 1) : (j += 1) {
            try writer.print("\x1b[{d};{d}H ", .{ start_row + 1, j });
        }
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ start_row + 1, start_col + box_width - 1, t.border });

        // Separator
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x9c", .{ start_row + 2, start_col, t.border });
        i = 0;
        while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x94\xa4\x1b[0m");

        // Items (from scroll_offset)
        for (0..visible_count) |vi| {
            const item_idx = self.scroll_offset + vi;
            const row: u16 = start_row + 3 + @as(u16, @intCast(vi));
            try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row, start_col, t.border });

            if (item_idx == self.selected) {
                try writer.print(" \x1b[7m {s} \x1b[0m", .{self.items[item_idx].label});
            } else {
                try writer.print("   {s} ", .{self.items[item_idx].label});
            }

            // Fill rest
            const label_len: u16 = @intCast(@min(self.items[item_idx].label.len + 4, box_width));
            var k: u16 = start_col + 1 + label_len;
            while (k < start_col + box_width -| 1) : (k += 1) {
                try writer.print("\x1b[{d};{d}H ", .{ row, k });
            }
            try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row, start_col + box_width - 1, t.border });
        }

        // Bottom border (with scroll indicator)
        const bottom_row = start_row + 3 + @as(u16, @intCast(visible_count));
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xb0", .{ bottom_row, start_col, t.border });
        i = 0;
        while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x95\xaf\x1b[0m");

        if (has_below) {
            try writer.print("\x1b[{d};{d}H \xe2\x96\xbc", .{ bottom_row, start_col + box_width });
        }
    }
};

/// Render the help overlay (static keybinding reference)
pub fn renderHelp(writer: anytype, term_width: u16, term_height: u16, t: theme.Theme) !void {
    const help_lines = [_][]const u8{
        "Keybindings",
        "",
        "Enter        Send message",
        "Alt+Enter    Insert newline",
        "Ctrl+C       Quit",
        "Ctrl+X       Cancel request",
        "Ctrl+A       Cursor to start",
        "Ctrl+E       Cursor to end",
        "Ctrl+U       Clear before cursor",
        "Ctrl+K       Clear after cursor",
        "Ctrl+W       Delete word backward",
        "Ctrl+T       Cycle theme",
        "Ctrl+N       New session",
        "Ctrl+S       Session list",
        "Ctrl+O       Select model",
        "Ctrl+F       Attach file",
        "Ctrl+Y       Copy last response",
        "Page Up      Scroll up",
        "Page Down    Scroll down",
        "Home         Scroll to top",
        "End          Scroll to bottom",
        "Ctrl+L       Redraw screen",
        "ESC          Close dialog",
        "",
        "Slash commands:",
        "/new /clear /help /quit /copy",
        "/theme /model /sessions /init",
        "/compact",
        "",
        "Press ESC to close",
    };

    const box_width: u16 = @min(term_width -| 4, 45);
    const box_height: u16 = @intCast(help_lines.len + 2);
    const start_row = (term_height -| box_height) / 2;
    const start_col = (term_width -| box_width) / 2;

    // Top border
    try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xad", .{ start_row, start_col, t.border });
    var i: u16 = 0;
    while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
    try writer.writeAll("\xe2\x95\xae\x1b[0m");

    // Content lines
    for (help_lines, 0..) |line, idx| {
        const row: u16 = start_row + 1 + @as(u16, @intCast(idx));
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row, start_col, t.border });

        if (idx == 0) {
            // Title: bold
            try writer.print(" \x1b[1m{s}\x1b[0m", .{line});
        } else {
            try writer.print(" {s}", .{line});
        }

        // Right border
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row, start_col + box_width - 1, t.border });
    }

    // Bottom border
    const bottom_row = start_row + 1 + @as(u16, @intCast(help_lines.len));
    try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xb0", .{ bottom_row, start_col, t.border });
    i = 0;
    while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
    try writer.writeAll("\xe2\x95\xaf\x1b[0m");
}
