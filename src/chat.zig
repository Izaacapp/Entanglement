const std = @import("std");
const theme = @import("theme.zig");
const markdown = @import("markdown.zig");

fn isAnsiTerminator(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

pub const Role = enum { user, assistant, system, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null, // raw JSON for sending back
    tool_name: ?[]const u8 = null, // display name for tool results
    cached_render: ?[]u8 = null, // cached rendered lines (joined with \x00)
    cached_width: u16 = 0, // width at which cache was generated
    timestamp: i64 = 0, // unix timestamp when message was created
};

pub const ChatView = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,
    scroll_offset: usize = 0,
    total_prompt_tokens: u32 = 0,
    total_completion_tokens: u32 = 0,
    stream_buf: std.ArrayList(u8) = .empty,
    streaming_active: bool = false,

    pub fn init(allocator: std.mem.Allocator) ChatView {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ChatView) void {
        for (self.messages.items) |*msg| {
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_calls_json) |j| self.allocator.free(j);
            if (msg.tool_name) |n| self.allocator.free(n);
            if (msg.cached_render) |cr| self.allocator.free(cr);
        }
        self.messages.deinit(self.allocator);
        self.stream_buf.deinit(self.allocator);
    }

    pub fn addUserMessage(self: *ChatView, text: []const u8) !void {
        const content = try self.allocator.dupe(u8, text);
        try self.messages.append(self.allocator, .{ .role = .user, .content = content, .timestamp = std.time.timestamp() });
        self.scrollToBottom();
    }

    pub fn addSystemMessage(self: *ChatView, text: []const u8) !void {
        const content = try self.allocator.dupe(u8, text);
        try self.messages.append(self.allocator, .{ .role = .system, .content = content, .timestamp = std.time.timestamp() });
        self.scrollToBottom();
    }

    pub fn addToolResult(self: *ChatView, tool_call_id: []const u8, tool_name: []const u8, result_content: []const u8) !void {
        const content = try self.allocator.dupe(u8, result_content);
        const tcid = try self.allocator.dupe(u8, tool_call_id);
        const tname = try self.allocator.dupe(u8, tool_name);
        try self.messages.append(self.allocator, .{
            .role = .tool,
            .content = content,
            .tool_call_id = tcid,
            .tool_name = tname,
        });
        self.scrollToBottom();
    }

    /// Add an assistant message with tool_calls (no content)
    pub fn addAssistantToolCallMessage(self: *ChatView, tool_calls_json: []const u8) !void {
        const json = try self.allocator.dupe(u8, tool_calls_json);
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, ""),
            .tool_calls_json = json,
        });
        self.scrollToBottom();
    }

    pub fn beginAssistantStream(self: *ChatView) void {
        self.stream_buf.clearRetainingCapacity();
        self.streaming_active = true;
    }

    pub fn appendAssistantChunk(self: *ChatView, chunk: []const u8) !void {
        if (self.streaming_active) {
            try self.stream_buf.appendSlice(self.allocator, chunk);
            // Only auto-scroll if user is already at bottom
            if (self.scroll_offset == 0) self.scrollToBottom();
            return;
        }
        // Fallback for non-streaming mode
        if (self.messages.items.len > 0) {
            const last = &self.messages.items[self.messages.items.len - 1];
            if (last.role == .assistant and last.tool_calls_json == null) {
                const new_content = try std.mem.concat(self.allocator, u8, &.{ last.content, chunk });
                self.allocator.free(last.content);
                last.content = new_content;
                self.scrollToBottom();
                return;
            }
        }
        const content = try self.allocator.dupe(u8, chunk);
        try self.messages.append(self.allocator, .{ .role = .assistant, .content = content });
        self.scrollToBottom();
    }

    pub fn finalizeAssistantStream(self: *ChatView) !void {
        if (!self.streaming_active) return;
        self.streaming_active = false;
        if (self.stream_buf.items.len > 0) {
            const content = try self.stream_buf.toOwnedSlice(self.allocator);
            try self.messages.append(self.allocator, .{ .role = .assistant, .content = content, .timestamp = std.time.timestamp() });
        }
    }

    pub fn getMessages(self: *ChatView) []const Message {
        return self.messages.items;
    }

    pub fn scrollUp(self: *ChatView, n: usize) void {
        self.scroll_offset +|= n;
    }

    pub fn scrollDown(self: *ChatView, n: usize) void {
        self.scroll_offset -|= n;
    }

    pub fn scrollToBottom(self: *ChatView) void {
        self.scroll_offset = 0;
    }

    pub fn render(self: *ChatView, writer: anytype, width: u16, height: u16, t: theme.Theme, selected_msg: ?usize) !void {
        if (self.messages.items.len == 0 and !self.streaming_active) {
            try writer.writeAll("\x1b[K\r\n");
            try writer.print("\x1b[{s}m  sniper \x1b[0m \x1b[2mv0.4.0\x1b[0m\x1b[K\r\n", .{t.assistant_label});
            try writer.writeAll("\x1b[K\r\n");
            try writer.writeAll("  \x1b[2mType a message and press Enter to send.\x1b[0m\x1b[K\r\n");
            try writer.writeAll("  \x1b[2mUse @file to reference files, Ctrl+F to attach.\x1b[0m\x1b[K\r\n");
            try writer.writeAll("  \x1b[2mCtrl+? for help, /help for commands.\x1b[0m\x1b[K\r\n");
            try writer.writeAll("\x1b[K\r\n");
            // Fill remaining lines
            const used: usize = 7;
            const h: usize = @intCast(height);
            var rem = if (h > used) h - used else 0;
            while (rem > 0) : (rem -= 1) {
                try writer.writeAll("\x1b[K\r\n");
            }
            return;
        }

        // Use arena allocator for all per-frame temp allocations
        // Everything is freed at once when the arena is deinited — no per-object free overhead
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const frame_alloc = arena.allocator();

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(frame_alloc);

        // Build virtual message list: real messages + streaming in-progress
        const stream_msg = if (self.streaming_active and self.stream_buf.items.len > 0)
            Message{ .role = .assistant, .content = self.stream_buf.items }
        else
            null;

        for (self.messages.items, 0..) |*msg, msg_idx| {
            // Skip tool-call-only assistant messages (no visible content)
            if (msg.role == .assistant and msg.content.len == 0 and msg.tool_calls_json != null) continue;

            // Check render cache (skip for selected message in copy mode)
            const is_selected = if (selected_msg) |si| si == msg_idx else false;
            if (!is_selected and msg.cached_render != null and msg.cached_width == width) {
                // Use cached render lines (separated by \x00)
                var cache_iter = std.mem.splitScalar(u8, msg.cached_render.?, 0);
                while (cache_iter.next()) |cached_line| {
                    try lines.append(frame_alloc, cached_line);
                }
                continue;
            }

            // Track line count before this message for caching
            const lines_before = lines.items.len;

            const label_style = switch (msg.role) {
                .user => t.user_label,
                .assistant => t.assistant_label,
                .system => t.system_label,
                .tool => t.system_label,
            };
            const name: []const u8 = switch (msg.role) {
                .user => "you",
                .assistant => "sniper",
                .system => "system",
                .tool => if (msg.tool_name) |tn| tn else "tool",
            };

            // Format relative time
            var time_str: []const u8 = "";
            if (msg.timestamp > 0) {
                const now = std.time.timestamp();
                const delta: u64 = @intCast(@max(0, now - msg.timestamp));
                var time_buf: [24]u8 = undefined;
                time_str = if (delta < 60)
                    std.fmt.bufPrint(&time_buf, " \x1b[2m{d}s ago\x1b[0m", .{delta}) catch ""
                else if (delta < 3600)
                    std.fmt.bufPrint(&time_buf, " \x1b[2m{d}m ago\x1b[0m", .{delta / 60}) catch ""
                else if (delta < 86400)
                    std.fmt.bufPrint(&time_buf, " \x1b[2m{d}h ago\x1b[0m", .{delta / 3600}) catch ""
                else
                    std.fmt.bufPrint(&time_buf, " \x1b[2m{d}d ago\x1b[0m", .{delta / 86400}) catch "";
            }

            const label_line = if (is_selected)
                try std.fmt.allocPrint(frame_alloc, "\x1b[7m\x1b[{s}m {s} \x1b[0m \xe2\x86\x90 copy", .{ label_style, name })
            else
                try std.fmt.allocPrint(frame_alloc, "\x1b[{s}m {s} \x1b[0m{s}", .{ label_style, name, time_str });
            try lines.append(frame_alloc, label_line);

            var content = msg.content;
            if (msg.role == .assistant) {
                const stripped = markdown.stripThinkBlocks(frame_alloc, msg.content) catch null;
                const base = if (stripped) |s| s else msg.content;
                const rendered = markdown.renderMarkdown(frame_alloc, base) catch null;
                if (rendered) |r| {
                    content = r;
                } else if (stripped) |s| {
                    content = s;
                }
            }

            // For tool results, truncate long output at a line boundary
            if (msg.role == .tool and content.len > 2000) {
                // Find last newline before 2000 to avoid breaking mid-line or mid-UTF-8
                var cut_at: usize = 2000;
                while (cut_at > 0 and content[cut_at - 1] != '\n') cut_at -= 1;
                if (cut_at == 0) cut_at = 2000; // no newlines, just cut
                content = try std.fmt.allocPrint(frame_alloc, "{s}\n\x1b[2m... ({d} bytes truncated)\x1b[0m", .{
                    content[0..cut_at],
                    content.len - cut_at,
                });
            }

            const wrap_width = @as(usize, width) -| 4;
            if (wrap_width == 0) continue;

            var line_start: usize = 0;
            var col: usize = 0;
            var i: usize = 0;
            var last_space_i: usize = 0;
            var last_space_col: usize = 0;
            const is_tool = msg.role == .tool;
            const is_system = msg.role == .system;
            const line_prefix: []const u8 = if (is_system) "  \x1b[2m" else "  ";
            const line_suffix: []const u8 = if (is_system) "\x1b[0m" else "";
            while (i < content.len) {
                if (content[i] == '\n') {
                    const text = content[line_start..i];
                    const formatted = if (is_tool and text.len > 0 and text[0] == '+')
                        try std.fmt.allocPrint(frame_alloc, "  \x1b[32m{s}\x1b[0m", .{text})
                    else if (is_tool and text.len > 0 and text[0] == '-')
                        try std.fmt.allocPrint(frame_alloc, "  \x1b[31m{s}\x1b[0m", .{text})
                    else
                        try std.fmt.allocPrint(frame_alloc, "{s}{s}{s}", .{ line_prefix, text, line_suffix });
                    try lines.append(frame_alloc, formatted);
                    i += 1;
                    line_start = i;
                    col = 0;
                    last_space_i = i;
                    last_space_col = 0;
                } else if (content[i] == '\x1b' and i + 1 < content.len and content[i + 1] == '[') {
                    // ANSI escape sequence — skip without counting columns
                    i += 2;
                    while (i < content.len and !isAnsiTerminator(content[i])) i += 1;
                    if (i < content.len) i += 1; // skip terminator
                } else if (content[i] & 0xC0 == 0x80) {
                    // UTF-8 continuation byte — don't count column
                    i += 1;
                } else {
                    if (content[i] == ' ') {
                        last_space_i = i;
                        last_space_col = col;
                    }
                    col += 1;
                    i += 1;
                    if (col >= wrap_width) {
                        // Try to break at last space (word boundary)
                        var break_at = i;
                        if (last_space_i > line_start and last_space_col > 0) {
                            break_at = last_space_i + 1; // break after the space
                        }
                        const text = content[line_start..break_at];
                        const formatted = try std.fmt.allocPrint(frame_alloc, "{s}{s}{s}", .{ line_prefix, text, line_suffix });
                        try lines.append(frame_alloc, formatted);
                        line_start = break_at;
                        // Recount columns from new line_start to current i
                        col = 0;
                        var ri = line_start;
                        while (ri < i) {
                            if (content[ri] == '\x1b' and ri + 1 < content.len and content[ri + 1] == '[') {
                                ri += 2;
                                while (ri < content.len and !isAnsiTerminator(content[ri])) ri += 1;
                                if (ri < content.len) ri += 1;
                            } else if (content[ri] & 0xC0 == 0x80) {
                                ri += 1;
                            } else {
                                col += 1;
                                ri += 1;
                            }
                        }
                        last_space_i = line_start;
                        last_space_col = 0;
                    }
                }
            }
            if (line_start < content.len) {
                const text = content[line_start..];
                const formatted = if (is_tool and text.len > 0 and text[0] == '+')
                    try std.fmt.allocPrint(frame_alloc, "  \x1b[32m{s}\x1b[0m", .{text})
                else if (is_tool and text.len > 0 and text[0] == '-')
                    try std.fmt.allocPrint(frame_alloc, "  \x1b[31m{s}\x1b[0m", .{text})
                else
                    try std.fmt.allocPrint(frame_alloc, "{s}{s}{s}", .{ line_prefix, text, line_suffix });
                try lines.append(frame_alloc, formatted);
            }

            try lines.append(frame_alloc, "");

            // Cache the rendered lines for this message (not when selected)
            // Uses self.allocator since cache persists across frames
            if (!is_selected) {
                const new_lines = lines.items[lines_before..];
                var cache_buf: std.ArrayList(u8) = .empty;
                defer cache_buf.deinit(self.allocator);
                for (new_lines, 0..) |cl, ci| {
                    if (ci > 0) try cache_buf.append(self.allocator, 0);
                    try cache_buf.appendSlice(self.allocator, cl);
                }
                if (msg.cached_render) |old_cr| self.allocator.free(old_cr);
                msg.cached_render = try cache_buf.toOwnedSlice(self.allocator);
                msg.cached_width = width;
            }
        }

        // Render streaming in-progress message
        if (stream_msg) |smsg| {
            const label_line = try std.fmt.allocPrint(frame_alloc, "\x1b[{s}m sniper \x1b[0m", .{t.assistant_label});
            try lines.append(frame_alloc, label_line);

            var content = smsg.content;
            const stripped_s = markdown.stripThinkBlocks(frame_alloc, smsg.content) catch null;
            const base_s = if (stripped_s) |s| s else smsg.content;
            const rendered_s = markdown.renderMarkdown(frame_alloc, base_s) catch null;
            if (rendered_s) |r| {
                content = r;
            } else if (stripped_s) |s| {
                content = s;
            }

            const wrap_width_s = @as(usize, width) -| 4;
            if (wrap_width_s > 0) {
                var line_start_s: usize = 0;
                var col_s: usize = 0;
                var si: usize = 0;
                var last_sp_i: usize = 0;
                var last_sp_col: usize = 0;
                while (si < content.len) {
                    if (content[si] == '\n') {
                        const text = content[line_start_s..si];
                        const formatted = try std.fmt.allocPrint(frame_alloc, "  {s}", .{text});
                        try lines.append(frame_alloc, formatted);
                        si += 1;
                        line_start_s = si;
                        col_s = 0;
                        last_sp_i = si;
                        last_sp_col = 0;
                    } else if (content[si] == '\x1b' and si + 1 < content.len and content[si + 1] == '[') {
                        // ANSI escape — skip without counting columns
                        si += 2;
                        while (si < content.len and !isAnsiTerminator(content[si])) si += 1;
                        if (si < content.len) si += 1;
                    } else if (content[si] & 0xC0 == 0x80) {
                        // UTF-8 continuation byte
                        si += 1;
                    } else {
                        if (content[si] == ' ') {
                            last_sp_i = si;
                            last_sp_col = col_s;
                        }
                        col_s += 1;
                        si += 1;
                        if (col_s >= wrap_width_s) {
                            var break_at = si;
                            if (last_sp_i > line_start_s and last_sp_col > 0) {
                                break_at = last_sp_i + 1;
                            }
                            const text = content[line_start_s..break_at];
                            const formatted = try std.fmt.allocPrint(frame_alloc, "  {s}", .{text});
                            try lines.append(frame_alloc, formatted);
                            line_start_s = break_at;
                            col_s = 0;
                            var ri = line_start_s;
                            while (ri < si) {
                                if (content[ri] == '\x1b' and ri + 1 < content.len and content[ri + 1] == '[') {
                                    ri += 2;
                                    while (ri < content.len and !isAnsiTerminator(content[ri])) ri += 1;
                                    if (ri < content.len) ri += 1;
                                } else if (content[ri] & 0xC0 == 0x80) {
                                    ri += 1;
                                } else {
                                    col_s += 1;
                                    ri += 1;
                                }
                            }
                            last_sp_i = line_start_s;
                            last_sp_col = 0;
                        }
                    }
                }
                if (line_start_s < content.len) {
                    const text = content[line_start_s..];
                    const formatted = try std.fmt.allocPrint(frame_alloc, "  {s}", .{text});
                    try lines.append(frame_alloc, formatted);
                }
            }

            try lines.append(frame_alloc, "");
        }

        const total = lines.items.len;
        const h: usize = @intCast(height);

        if (total > h) {
            if (self.scroll_offset > total - h) {
                self.scroll_offset = total - h;
            }
        } else {
            self.scroll_offset = 0;
        }

        const end = if (total > self.scroll_offset) total - self.scroll_offset else total;
        const start = if (end > h) end - h else 0;

        for (lines.items[start..end]) |line| {
            try writer.writeAll(line);
            try writer.writeAll("\x1b[K\r\n"); // clear to end of line
        }

        var remaining = h - (end - start);
        while (remaining > 0) : (remaining -= 1) {
            try writer.writeAll("\x1b[K\r\n"); // clear empty lines
        }
    }
};
