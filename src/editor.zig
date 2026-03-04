const std = @import("std");
const theme = @import("theme.zig");

fn utf8ByteLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 1;
}

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_offset: usize = 0, // first visible line in editor viewport

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn getText(self: *Editor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn insertNewline(self: *Editor) !void {
        try self.buffer.insert(self.allocator, self.cursor, '\n');
        self.cursor += 1;
    }

    pub fn deleteAtCursor(self: *Editor) void {
        if (self.cursor < self.buffer.items.len) {
            _ = self.buffer.orderedRemove(self.cursor);
        }
    }

    fn findWordBoundaryBack(self: *Editor) usize {
        if (self.cursor == 0) return 0;
        var pos = self.cursor;
        // Skip spaces
        while (pos > 0 and self.buffer.items[pos - 1] == ' ') pos -= 1;
        // Skip word chars
        while (pos > 0 and self.buffer.items[pos - 1] != ' ') pos -= 1;
        return pos;
    }

    // Get line/col info for multi-line navigation
    pub fn getCursorLineCol(self: *Editor) struct { line: usize, col: usize, line_start: usize } {
        var line: usize = 0;
        var line_start: usize = 0;
        for (self.buffer.items[0..self.cursor], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{ .line = line, .col = self.cursor - line_start, .line_start = line_start };
    }

    pub fn getLineCount(self: *Editor) usize {
        var count: usize = 1;
        for (self.buffer.items) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    fn getLineStartEnd(self: *Editor, target_line: usize) struct { start: usize, end: usize } {
        var line: usize = 0;
        var start: usize = 0;
        for (self.buffer.items, 0..) |c, i| {
            if (line == target_line) {
                // Find end
                var end = i;
                while (end < self.buffer.items.len and self.buffer.items[end] != '\n') end += 1;
                return .{ .start = start, .end = end };
            }
            if (c == '\n') {
                line += 1;
                start = i + 1;
            }
        }
        // Last line
        return .{ .start = start, .end = self.buffer.items.len };
    }

    pub fn getHeight(self: *Editor) u16 {
        const line_count = self.getLineCount();
        return @intCast(@max(1, @min(line_count, 10)));
    }

    pub fn handleInput(self: *Editor, input: []const u8) !void {
        if (input.len == 0) return;

        // Ctrl+A — cursor to start of line
        if (input[0] == 0x01) {
            const info = self.getCursorLineCol();
            self.cursor = info.line_start;
            return;
        }

        // Ctrl+E — cursor to end of line
        if (input[0] == 0x05) {
            const info = self.getCursorLineCol();
            const le = self.getLineStartEnd(info.line);
            self.cursor = le.end;
            return;
        }

        // Ctrl+U — clear line before cursor
        if (input[0] == 0x15) {
            const info = self.getCursorLineCol();
            const count = self.cursor - info.line_start;
            if (count > 0) {
                // Remove chars from line_start to cursor
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    _ = self.buffer.orderedRemove(info.line_start);
                }
                self.cursor = info.line_start;
            }
            return;
        }

        // Ctrl+K — clear line after cursor
        if (input[0] == 0x0B) {
            const info = self.getCursorLineCol();
            const le = self.getLineStartEnd(info.line);
            const count = le.end - self.cursor;
            if (count > 0) {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    _ = self.buffer.orderedRemove(self.cursor);
                }
            }
            return;
        }

        // Ctrl+W — delete word backward
        if (input[0] == 0x17) {
            const new_pos = self.findWordBoundaryBack();
            const count = self.cursor - new_pos;
            if (count > 0) {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    _ = self.buffer.orderedRemove(new_pos);
                }
                self.cursor = new_pos;
            }
            return;
        }

        // Backspace — delete entire UTF-8 character
        if (input[0] == 127 or input[0] == 8) {
            if (self.cursor > 0) {
                // Skip back over UTF-8 continuation bytes
                var del_count: usize = 1;
                while (self.cursor > del_count and (self.buffer.items[self.cursor - del_count] & 0xC0) == 0x80) {
                    del_count += 1;
                }
                var d: usize = 0;
                while (d < del_count) : (d += 1) {
                    _ = self.buffer.orderedRemove(self.cursor - del_count);
                }
                self.cursor -= del_count;
            }
            return;
        }

        // Escape sequences
        if (input.len >= 3 and input[0] == 27 and input[1] == '[') {
            switch (input[2]) {
                'D' => { // Left — skip back over UTF-8 character
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        while (self.cursor > 0 and (self.buffer.items[self.cursor] & 0xC0) == 0x80) {
                            self.cursor -= 1;
                        }
                    }
                },
                'C' => { // Right — skip forward by UTF-8 character
                    if (self.cursor < self.buffer.items.len) {
                        const char_len = utf8ByteLen(self.buffer.items[self.cursor]);
                        self.cursor = @min(self.cursor + char_len, self.buffer.items.len);
                    }
                },
                'A' => { // Up — move to previous line
                    const info = self.getCursorLineCol();
                    if (info.line > 0) {
                        const prev = self.getLineStartEnd(info.line - 1);
                        const prev_len = prev.end - prev.start;
                        self.cursor = prev.start + @min(info.col, prev_len);
                    }
                },
                'B' => { // Down — move to next line
                    const info = self.getCursorLineCol();
                    const total = self.getLineCount();
                    if (info.line + 1 < total) {
                        const next = self.getLineStartEnd(info.line + 1);
                        const next_len = next.end - next.start;
                        self.cursor = next.start + @min(info.col, next_len);
                    }
                },
                'H' => { // Home
                    const info = self.getCursorLineCol();
                    self.cursor = info.line_start;
                },
                'F' => { // End
                    const info = self.getCursorLineCol();
                    const le = self.getLineStartEnd(info.line);
                    self.cursor = le.end;
                },
                '3' => { // Delete forward: ESC[3~
                    if (input.len >= 4 and input[3] == '~') {
                        self.deleteAtCursor();
                    }
                },
                else => {},
            }
            return;
        }

        // Tab — insert 2 spaces
        if (input[0] == '\t') {
            try self.buffer.insert(self.allocator, self.cursor, ' ');
            self.cursor += 1;
            try self.buffer.insert(self.allocator, self.cursor, ' ');
            self.cursor += 1;
            return;
        }

        // Regular printable characters — process ALL bytes in input (including UTF-8)
        for (input) |c| {
            if (c >= 32) {
                try self.buffer.insert(self.allocator, self.cursor, c);
                self.cursor += 1;
            }
        }
    }

    pub fn render(self: *Editor, writer: anytype, width: u16, height: u16, t: theme.Theme) !void {
        const max_visible = @as(usize, width) -| 4;
        if (max_visible == 0) return;
        const max_lines: usize = @intCast(height);

        // Find which line the cursor is on
        const cursor_info = self.getCursorLineCol();

        // Adjust scroll_offset to keep cursor visible
        if (cursor_info.line < self.scroll_offset) {
            self.scroll_offset = cursor_info.line;
        } else if (cursor_info.line >= self.scroll_offset + max_lines) {
            self.scroll_offset = cursor_info.line - max_lines + 1;
        }

        // Split buffer by newlines and render visible lines
        var line_idx: usize = 0;
        var lines_rendered: usize = 0;
        var pos: usize = 0;
        while (pos <= self.buffer.items.len) {
            // Find end of this line
            var end = pos;
            while (end < self.buffer.items.len and self.buffer.items[end] != '\n') end += 1;

            if (line_idx >= self.scroll_offset and lines_rendered < max_lines) {
                const line_content = self.buffer.items[pos..end];
                const is_multiline = self.getLineCount() > 1;
                const prefix = if (!is_multiline) " > " else if (line_idx == 0) " > " else "   ";
                try writer.print("\x1b[{s}m{s}\x1b[0m", .{ t.prompt_style, prefix });

                // Show visible portion with cursor
                const start_offset = if (line_content.len > max_visible) line_content.len - max_visible else 0;
                const cursor_in_line = self.cursor >= pos and self.cursor <= end;
                const cursor_col = if (cursor_in_line) self.cursor - pos else 0;

                if (cursor_in_line) {
                    const visible = line_content[start_offset..];
                    const cursor_vis = if (cursor_col >= start_offset) cursor_col - start_offset else 0;

                    if (cursor_vis < visible.len) {
                        // Cursor on a character — highlight full UTF-8 sequence
                        try writer.writeAll(visible[0..cursor_vis]);
                        try writer.writeAll("\x1b[7m");
                        const clen = utf8ByteLen(visible[cursor_vis]);
                        const cend = @min(cursor_vis + clen, visible.len);
                        try writer.writeAll(visible[cursor_vis..cend]);
                        try writer.writeAll("\x1b[0m");
                        try writer.writeAll(visible[cend..]);
                    } else {
                        // Cursor at end of line — show block cursor as space
                        try writer.writeAll(visible);
                        try writer.writeAll("\x1b[7m \x1b[0m");
                    }
                } else {
                    try writer.writeAll(line_content[start_offset..]);
                }

                try writer.writeAll("\x1b[K\r\n");
                lines_rendered += 1;
            }

            line_idx += 1;
            if (end >= self.buffer.items.len) break;
            pos = end + 1; // skip newline
        }

        // Fill remaining lines if editor area is larger than content
        while (lines_rendered < max_lines) : (lines_rendered += 1) {
            try writer.writeAll("\x1b[K\r\n");
        }
    }
};
