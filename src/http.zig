const std = @import("std");
const config = @import("config.zig");
const chat = @import("chat.zig");
const tools_mod = @import("tools.zig");

pub const StreamResult = struct {
    tool_calls: ?[]tools_mod.ToolCall,
    finish_reason: FinishReason,
    prompt_tokens: u32,
    completion_tokens: u32,
    api_error: ?[]const u8 = null,
};

pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    unknown,
};

pub fn streamChat(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    messages: []const chat.Message,
    chat_view: *chat.ChatView,
    app: anytype,
    use_tools: bool,
    cancel_flag: *bool,
    tty_fd: std.posix.fd_t,
) !StreamResult {
    _ = cancel_flag; // Now handled via poll on tty_fd
    // Build JSON payload manually
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const w = payload.writer(allocator);

    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.writeAll("\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");

    for (messages, 0..) |msg, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"");
        switch (msg.role) {
            .tool => try w.writeAll("tool"),
            else => try w.writeAll(@tagName(msg.role)),
        }
        try w.writeAll("\"");

        // Tool call ID for tool responses
        if (msg.tool_call_id) |tcid| {
            try w.writeAll(",\"tool_call_id\":\"");
            try writeJsonStr(w, tcid);
            try w.writeByte('"');
        }

        // Content
        if (msg.content.len > 0) {
            try w.writeAll(",\"content\":\"");
            try writeJsonStr(w, msg.content);
            try w.writeByte('"');
        } else {
            try w.writeAll(",\"content\":null");
        }

        // Tool calls array for assistant messages
        if (msg.tool_calls_json) |tc_json| {
            try w.writeAll(",\"tool_calls\":");
            try w.writeAll(tc_json);
        }

        try w.writeByte('}');
    }
    try w.writeAll("]");

    // Add tools if requested
    if (use_tools) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_mod.tool_definitions);
    }

    try w.writeByte('}');

    // Build URL
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{cfg.endpoint}) catch return error.UrlTooLong;

    // Build curl argv
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "curl", "-sN", "--max-time", "300", "-X", "POST", url,
        "-H", "Content-Type: application/json",
    });

    var auth_header_buf: [512]u8 = undefined;
    if (cfg.api_key) |key| {
        const auth_header = std.fmt.bufPrint(&auth_header_buf, "Authorization: Bearer {s}", .{key}) catch return error.AuthHeaderTooLong;
        try argv.appendSlice(allocator, &.{ "-H", auth_header });
    }

    try argv.appendSlice(allocator, &.{ "-d", payload.items });

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    // Store child ID for cancellation
    defer {
        _ = child.wait() catch {};
    }

    const pipe = child.stdout.?;
    var remainder: std.ArrayList(u8) = .empty;
    defer remainder.deinit(allocator);
    var read_buf: [4096]u8 = undefined;

    // Tool call accumulation
    var tc_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (tc_ids.items) |id| allocator.free(id);
        tc_ids.deinit(allocator);
    }
    var tc_names: std.ArrayList([]u8) = .empty;
    defer {
        for (tc_names.items) |name| allocator.free(name);
        tc_names.deinit(allocator);
    }
    var tc_args: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (tc_args.items) |*a| a.deinit(allocator);
        tc_args.deinit(allocator);
    }

    var finish: FinishReason = .stop;
    var p_tokens: u32 = 0;
    var c_tokens: u32 = 0;

    // Render throttle: 30fps = 33ms between renders
    var last_render_ns: i128 = 0;
    const render_interval_ns: i128 = 33_000_000; // 33ms

    // Track whether we received any SSE data
    var got_sse_data = false;
    // Accumulate all raw bytes for error detection
    var raw_response: std.ArrayList(u8) = .empty;
    defer raw_response.deinit(allocator);

    const pipe_fd = pipe.handle;
    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = pipe_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = tty_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        // Poll with 33ms timeout for render pacing
        const poll_rc = std.posix.poll(&poll_fds, 33) catch break;

        // Check TTY for Ctrl+X cancellation
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            var tty_buf: [32]u8 = undefined;
            const tty_n = std.posix.read(tty_fd, &tty_buf) catch 0;
            for (tty_buf[0..tty_n]) |c| {
                if (c == 0x18) { // Ctrl+X
                    _ = std.posix.kill(child.id, 9) catch {};
                    return error.Cancelled;
                }
            }
        }

        // No data ready and no timeout action needed
        if (poll_rc == 0) continue;

        // Check pipe for data
        if (poll_fds[0].revents & std.posix.POLL.IN == 0) {
            // Check for hangup (pipe closed)
            if (poll_fds[0].revents & std.posix.POLL.HUP != 0) break;
            continue;
        }

        const n = pipe.read(&read_buf) catch break;
        if (n == 0) break;

        try remainder.appendSlice(allocator, read_buf[0..n]);
        try raw_response.appendSlice(allocator, read_buf[0..n]);

        while (std.mem.indexOf(u8, remainder.items, "\n")) |nl| {
            const line = remainder.items[0..nl];
            if (std.mem.startsWith(u8, line, "data: ")) {
                got_sse_data = true;
                const data = line["data: ".len..];
                if (std.mem.eql(u8, data, "[DONE]")) {
                    // Final render before returning
                    app.render() catch {};

                    var result = StreamResult{
                        .tool_calls = null,
                        .finish_reason = finish,
                        .prompt_tokens = p_tokens,
                        .completion_tokens = c_tokens,
                    };

                    if (tc_ids.items.len > 0) {
                        var tcs = try allocator.alloc(tools_mod.ToolCall, tc_ids.items.len);
                        for (tc_ids.items, 0..) |id, i| {
                            tcs[i] = .{
                                .id = try allocator.dupe(u8, id),
                                .function_name = try allocator.dupe(u8, tc_names.items[i]),
                                .arguments_json = try allocator.dupe(u8, tc_args.items[i].items),
                            };
                        }
                        result.tool_calls = tcs;
                        result.finish_reason = .tool_calls;
                    }

                    const after = nl + 1;
                    std.mem.copyForwards(u8, remainder.items[0..], remainder.items[after..]);
                    remainder.items.len -= after;
                    return result;
                }

                if (std.mem.indexOf(u8, data, "\"finish_reason\":\"tool_calls\"") != null) {
                    finish = .tool_calls;
                }
                if (std.mem.indexOf(u8, data, "\"finish_reason\":\"length\"") != null) {
                    finish = .length;
                }

                if (std.mem.indexOf(u8, data, "\"prompt_tokens\":") != null) {
                    p_tokens = extractJsonInt(data, "prompt_tokens");
                }
                if (std.mem.indexOf(u8, data, "\"completion_tokens\":") != null) {
                    c_tokens = extractJsonInt(data, "completion_tokens");
                }

                if (std.mem.indexOf(u8, data, "\"tool_calls\"") != null) {
                    parseToolCallDelta(allocator, data, &tc_ids, &tc_names, &tc_args) catch {};
                }

                const content = extractContent(data);
                if (content) |c| {
                    if (c.len == 0) {
                        const after = nl + 1;
                        std.mem.copyForwards(u8, remainder.items[0..], remainder.items[after..]);
                        remainder.items.len -= after;
                        continue;
                    }
                    var unesc: std.ArrayList(u8) = .empty;
                    defer unesc.deinit(allocator);
                    var ii: usize = 0;
                    while (ii < c.len) {
                        if (ii + 1 < c.len and c[ii] == '\\') {
                            switch (c[ii + 1]) {
                                'n' => {
                                    try unesc.append(allocator, '\n');
                                    ii += 2;
                                    continue;
                                },
                                't' => {
                                    try unesc.append(allocator, '\t');
                                    ii += 2;
                                    continue;
                                },
                                '"' => {
                                    try unesc.append(allocator, '"');
                                    ii += 2;
                                    continue;
                                },
                                '\\' => {
                                    try unesc.append(allocator, '\\');
                                    ii += 2;
                                    continue;
                                },
                                else => {},
                            }
                        }
                        try unesc.append(allocator, c[ii]);
                        ii += 1;
                    }
                    try chat_view.appendAssistantChunk(unesc.items);
                    const now_ns = std.time.nanoTimestamp();
                    if (now_ns - last_render_ns >= render_interval_ns) {
                        try app.render();
                        last_render_ns = now_ns;
                    }
                }
            }
            const after = nl + 1;
            std.mem.copyForwards(u8, remainder.items[0..], remainder.items[after..]);
            remainder.items.len -= after;
        }
    }

    // If we never got SSE data, the response is likely a JSON error
    if (!got_sse_data and raw_response.items.len > 0) {
        // Extract error message from JSON error response
        if (tools_mod.extractJsonString(raw_response.items, "message")) |err_msg| {
            const msg = tools_mod.jsonUnescape(allocator, err_msg) catch null;
            if (msg) |m| {
                return StreamResult{
                    .tool_calls = null,
                    .finish_reason = .unknown,
                    .prompt_tokens = 0,
                    .completion_tokens = 0,
                    .api_error = m,
                };
            }
        }
        // Generic error — no SSE data received
        return StreamResult{
            .tool_calls = null,
            .finish_reason = .unknown,
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .api_error = try allocator.dupe(u8, "No response from API"),
        };
    }

    return StreamResult{
        .tool_calls = null,
        .finish_reason = finish,
        .prompt_tokens = p_tokens,
        .completion_tokens = c_tokens,
    };
}

/// Non-streaming chat for non-interactive mode
pub fn chatOnce(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    messages: []const chat.Message,
) ![]const u8 {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const w = payload.writer(allocator);

    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.writeAll("\",\"stream\":false,\"messages\":[");

    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"");
        try w.writeAll(@tagName(msg.role));
        try w.writeAll("\",\"content\":\"");
        try writeJsonStr(w, msg.content);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{cfg.endpoint}) catch return error.UrlTooLong;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.appendSlice(allocator, &.{
        "curl", "-s", "--max-time", "120", "-X", "POST", url,
        "-H", "Content-Type: application/json",
    });
    var auth_buf: [512]u8 = undefined;
    if (cfg.api_key) |key| {
        const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{key}) catch return error.AuthHeaderTooLong;
        try argv_list.appendSlice(allocator, &.{ "-H", auth });
    }
    try argv_list.appendSlice(allocator, &.{ "-d", payload.items });

    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = pipe.read(&buf) catch break;
            if (n == 0) break;
            try out.appendSlice(allocator, buf[0..n]);
        }
    }
    _ = child.wait() catch {};

    // Extract content from response
    const content = extractContent(out.items) orelse return error.NoContent;
    return try tools_mod.jsonUnescape(allocator, content);
}

fn parseToolCallDelta(
    allocator: std.mem.Allocator,
    data: []const u8,
    tc_ids: *std.ArrayList([]u8),
    tc_names: *std.ArrayList([]u8),
    tc_args: *std.ArrayList(std.ArrayList(u8)),
) !void {
    // Look for "id":"..." in the tool_calls
    if (tools_mod.extractJsonString(data, "id")) |id_raw| {
        if (id_raw.len > 0) {
            // New tool call
            const id = try tools_mod.jsonUnescape(allocator, id_raw);
            try tc_ids.append(allocator, id);

            // Extract function name
            const name_raw = tools_mod.extractJsonString(data, "name") orelse "";
            const name = try tools_mod.jsonUnescape(allocator, name_raw);
            try tc_names.append(allocator, name);

            // Start accumulating arguments
            var args: std.ArrayList(u8) = .empty;
            if (tools_mod.extractJsonString(data, "arguments")) |arg_raw| {
                const arg = try tools_mod.jsonUnescape(allocator, arg_raw);
                try args.appendSlice(allocator, arg);
                allocator.free(arg);
            }
            try tc_args.append(allocator, args);
            return;
        }
    }

    // Append to existing tool call arguments
    if (tools_mod.extractJsonString(data, "arguments")) |arg_raw| {
        if (arg_raw.len > 0 and tc_args.items.len > 0) {
            const last = &tc_args.items[tc_args.items.len - 1];
            const arg = try tools_mod.jsonUnescape(allocator, arg_raw);
            defer allocator.free(arg);
            try last.appendSlice(allocator, arg);
        }
    }
}

fn extractContent(json: []const u8) ?[]const u8 {
    const needle = "\"content\":\"";
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const content_start = start + needle.len;

    var i = content_start;
    while (i < json.len) {
        if (json[i] == '\\') {
            i += 2;
            continue;
        }
        if (json[i] == '"') break;
        i += 1;
    }
    if (i >= json.len) return null;
    return json[content_start..i];
}

pub fn extractJsonInt(json: []const u8, key: []const u8) u32 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return 0;
    const pos = std.mem.indexOf(u8, json, needle) orelse return 0;
    var start = pos + needle.len;
    while (start < json.len and json[start] == ' ') start += 1;
    var end = start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == start) return 0;
    return std.fmt.parseInt(u32, json[start..end], 10) catch 0;
}

pub fn writeJsonStr(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}
