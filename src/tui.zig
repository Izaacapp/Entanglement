const std = @import("std");
const config = @import("config.zig");
const chat = @import("chat.zig");
const editor = @import("editor.zig");
const status = @import("status.zig");
const theme = @import("theme.zig");
const layout = @import("layout.zig");
const session = @import("session.zig");
const dialog = @import("dialog.zig");
const http = @import("http.zig");
const tools_mod = @import("tools.zig");
const markdown = @import("markdown.zig");

const stdout = std.fs.File.stdout();

fn writeOut(data: []const u8) void {
    stdout.writeAll(data) catch {};
}

fn utf8CharLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 1; // invalid, treat as single byte
}

const UiMode = enum {
    normal,
    help,
    session_list,
    model_select,
    confirm_quit,
    file_picker,
    copy_select,
    tool_confirm,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    tty: std.posix.fd_t,
    width: u16,
    height: u16,
    chat_view: chat.ChatView,
    editor_view: editor.Editor,
    status_bar: status.StatusBar,
    session_mgr: ?session.SessionManager,
    running: bool,
    original_termios: std.posix.termios,
    mode: UiMode = .normal,
    dialog_items: ?[]dialog.DialogItem = null,
    dialog_view: ?dialog.Dialog = null,
    model_override: ?[]const u8 = null,
    cancel_flag: bool = false,
    streaming: bool = false,
    tools_supported: bool = true,
    selected_message: ?usize = null,
    auto_approve_tools: bool = false,
    pending_tool_call: ?tools_mod.ToolCall = null,
    tool_confirm_content: ?[]const u8 = null,
    shell: ?tools_mod.PersistentShell = null,
    // File attachments
    attachments: std.ArrayList([]const u8) = .empty,
    // Context loaded
    context_loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !App {
        const tty = std.fs.File.stdin().handle;
        const original = try std.posix.tcgetattr(tty);
        var raw = original;

        const ECHO: u64 = 0x00000008;
        const ICANON: u64 = 0x00000100;
        const ISIG: u64 = 0x00000080;
        const IEXTEN: u64 = 0x00000400;
        const IXON: u64 = 0x00000200;
        const ICRNL: u64 = 0x00000100;
        const BRKINT: u64 = 0x00000002;
        const INPCK: u64 = 0x00000010;
        const ISTRIP: u64 = 0x00000020;

        raw.lflag = @bitCast(@as(u64, @bitCast(raw.lflag)) & ~(ECHO | ICANON | ISIG | IEXTEN));
        raw.iflag = @bitCast(@as(u64, @bitCast(raw.iflag)) & ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP));
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(tty, .FLUSH, raw);

        const size = try layout.getTermSize(tty);
        writeOut("\x1b[?1049h\x1b[?25l\x1b[?2004h"); // alt screen + hide cursor + bracketed paste

        var sess_mgr: ?session.SessionManager = session.SessionManager.init(allocator) catch null;
        var cv = chat.ChatView.init(allocator);

        if (sess_mgr) |*sm| {
            sm.loadLast(&cv) catch {};
        }

        var app = App{
            .allocator = allocator,
            .cfg = cfg,
            .tty = tty,
            .width = size.cols,
            .height = size.rows,
            .chat_view = cv,
            .editor_view = editor.Editor.init(allocator),
            .status_bar = status.StatusBar.init(cfg),
            .session_mgr = sess_mgr,
            .running = true,
            .original_termios = original,
            .attachments = std.ArrayList([]const u8).empty,
        };

        // Initialize persistent shell
        app.shell = tools_mod.PersistentShell.init(allocator) catch null;

        // Load context files
        app.loadContextFiles();

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.session_mgr) |*sm| {
            sm.save(&self.chat_view) catch {};
            sm.deinit();
        }
        if (self.shell) |*sh| sh.deinit();
        writeOut("\x1b[?2004l\x1b[?25h\x1b[?1049l");
        std.posix.tcsetattr(self.tty, .FLUSH, self.original_termios) catch {};
        if (self.model_override) |m| self.allocator.free(m);
        if (self.tool_confirm_content) |tc| self.allocator.free(tc);
        self.freeDialogItems();
        self.freeAttachments();
        self.attachments.deinit(self.allocator);
        self.chat_view.deinit();
        self.editor_view.deinit();
    }

    fn freeDialogItems(self: *App) void {
        if (self.dialog_items) |items| {
            for (items) |item| {
                self.allocator.free(item.label);
                self.allocator.free(item.value);
            }
            self.allocator.free(items);
            self.dialog_items = null;
        }
        self.dialog_view = null;
    }

    fn freeAttachments(self: *App) void {
        for (self.attachments.items) |a| self.allocator.free(a);
        self.attachments.clearRetainingCapacity();
    }

    fn clearMessages(self: *App) void {
        for (self.chat_view.messages.items) |m| {
            self.allocator.free(m.content);
            if (m.tool_call_id) |id| self.allocator.free(id);
            if (m.tool_calls_json) |j| self.allocator.free(j);
            if (m.tool_name) |nn| self.allocator.free(nn);
            if (m.cached_render) |cr| self.allocator.free(cr);
        }
        self.chat_view.messages.clearRetainingCapacity();
        self.chat_view.scroll_offset = 0;
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            try self.render();
            try self.handleInput();
        }
    }

    pub fn render(self: *App) !void {
        if (layout.getTermSize(self.tty)) |size| {
            self.width = size.cols;
            self.height = size.rows;
        } else |_| {}

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        const t = theme.current();

        try w.writeAll("\x1b[H"); // cursor home (no full clear — each line clears to end)

        const editor_height = self.editor_view.getHeight();
        const chrome_height: u16 = editor_height + 2;
        const chat_height = self.height -| chrome_height;

        try self.chat_view.render(w, self.width, chat_height, t, self.selected_message);
        try layout.renderHLine(w, self.width, t.border);
        try self.editor_view.render(w, self.width, editor_height, t);

        // Update scroll indicator
        if (self.chat_view.scroll_offset > 0) {
            self.status_bar.scroll_indicator = "\xe2\x86\x91 scrolled";
        } else {
            self.status_bar.scroll_indicator = null;
        }
        try self.status_bar.render(w, self.width, t);

        switch (self.mode) {
            .help => try dialog.renderHelp(w, self.width, self.height, t),
            .confirm_quit => try renderQuitConfirm(w, self.width, self.height, t),
            .tool_confirm => try self.renderToolConfirm(w, t),
            .session_list, .model_select, .file_picker => {
                if (self.dialog_view) |*dv| {
                    try dv.render(w, self.width, self.height, t);
                }
            },
            .copy_select, .normal => {},
        }

        stdout.writeAll(buf.items) catch {};
    }

    fn handleInput(self: *App) !void {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(self.tty, &buf) catch return;
        if (n == 0) return;
        const input = buf[0..n];

        // During streaming, only allow scroll keys
        if (self.streaming) {
            self.handleStreamingInput(input);
            return;
        }

        if (self.mode != .normal) {
            try self.handleDialogInput(input);
            return;
        }

        // Process input byte by byte, handling escape sequences as chunks
        var pos: usize = 0;
        while (pos < input.len) {
            const c = input[pos];

            // Bracketed paste: ESC[200~ ... ESC[201~
            if (c == 27 and pos + 5 < input.len and
                input[pos + 1] == '[' and input[pos + 2] == '2' and
                input[pos + 3] == '0' and input[pos + 4] == '0' and input[pos + 5] == '~')
            {
                pos += 6; // skip paste start marker
                // Find paste end marker ESC[201~
                const paste_start = pos;
                while (pos + 5 < input.len) {
                    if (input[pos] == 27 and input[pos + 1] == '[' and input[pos + 2] == '2' and
                        input[pos + 3] == '0' and input[pos + 4] == '1' and input[pos + 5] == '~')
                    {
                        break;
                    }
                    pos += 1;
                }
                const paste_end = pos;
                if (pos + 5 < input.len) pos += 6; // skip paste end marker

                // Insert pasted content into editor (newlines become actual newlines)
                const pasted = input[paste_start..paste_end];
                for (pasted) |pc| {
                    if (pc == '\r') continue; // skip CR from CRLF
                    if (pc == '\n') {
                        self.editor_view.insertNewline() catch {};
                    } else if (pc >= 32) {
                        self.editor_view.buffer.insert(self.allocator, self.editor_view.cursor, pc) catch break;
                        self.editor_view.cursor += 1;
                    }
                }
                continue;
            }

            // Escape sequence
            if (c == 27 and pos + 1 < input.len) {
                // Alt+Enter
                if (input[pos + 1] == '\r' or input[pos + 1] == '\n') {
                    try self.editor_view.insertNewline();
                    pos += 2;
                    continue;
                }

                // ESC [ sequences
                if (input[pos + 1] == '[' and pos + 2 < input.len) {
                    // Page Up/Down: ESC[5~ / ESC[6~, Home/End: ESC[1~ / ESC[4~
                    if (pos + 3 < input.len and input[pos + 3] == '~') {
                        if (input[pos + 2] == '5') { // Page Up
                            self.chat_view.scrollUp(self.height / 2);
                            pos += 4;
                            continue;
                        }
                        if (input[pos + 2] == '6') { // Page Down
                            self.chat_view.scrollDown(self.height / 2);
                            pos += 4;
                            continue;
                        }
                        if (input[pos + 2] == '1') { // Home — scroll to top
                            self.chat_view.scroll_offset = std.math.maxInt(usize);
                            pos += 4;
                            continue;
                        }
                        if (input[pos + 2] == '4') { // End — scroll to bottom
                            self.chat_view.scrollToBottom();
                            pos += 4;
                            continue;
                        }
                    }

                    // Pass escape sequence to editor
                    const seq_end = @min(pos + 4, input.len);
                    try self.editor_view.handleInput(input[pos..seq_end]);
                    pos = seq_end;
                    continue;
                }

                // Bare ESC — skip
                pos += 1;
                continue;
            }

            // Enter
            if (c == '\r' or c == '\n') {
                try self.handleEnter();
                pos += 1;
                continue;
            }

            // Control characters
            if (c < 32) {
                try self.handleControlChar(c);
                pos += 1;
                if (!self.running or self.mode != .normal) return;
                continue;
            }

            // Tab
            if (c == '\t') {
                // Handled in handleControlChar above (c < 32 is true for \t=9)
                pos += 1;
                continue;
            }

            // Backspace (127)
            if (c == 127 or c == 8) {
                try self.editor_view.handleInput(&[_]u8{c});
                pos += 1;
                continue;
            }

            // Printable character — insert into editor (including UTF-8)
            if (c >= 32) {
                const char_len = utf8CharLen(c);
                if (pos + char_len <= input.len) {
                    var ci: usize = 0;
                    while (ci < char_len) : (ci += 1) {
                        try self.editor_view.buffer.insert(self.allocator, self.editor_view.cursor + ci, input[pos + ci]);
                    }
                    self.editor_view.cursor += char_len;
                    pos += char_len;
                } else {
                    pos += 1;
                }
                continue;
            }

            // Skip unexpected bytes
            pos += 1;
        }
    }

    fn handleStreamingInput(self: *App, input: []const u8) void {
        // During streaming, allow Page Up/Down/Home/End for scrolling
        var pos: usize = 0;
        while (pos < input.len) {
            if (input[pos] == 27 and pos + 2 < input.len and input[pos + 1] == '[') {
                if (pos + 3 < input.len and input[pos + 3] == '~') {
                    if (input[pos + 2] == '5') { // Page Up
                        self.chat_view.scrollUp(self.height / 2);
                        pos += 4;
                        continue;
                    }
                    if (input[pos + 2] == '6') { // Page Down
                        self.chat_view.scrollDown(self.height / 2);
                        pos += 4;
                        continue;
                    }
                    if (input[pos + 2] == '1') { // Home
                        self.chat_view.scroll_offset = std.math.maxInt(usize);
                        pos += 4;
                        continue;
                    }
                    if (input[pos + 2] == '4') { // End
                        self.chat_view.scrollToBottom();
                        pos += 4;
                        continue;
                    }
                }
                pos += 3;
                continue;
            }
            pos += 1;
        }
    }

    fn handleControlChar(self: *App, c: u8) !void {
        switch (c) {
            3 => { // Ctrl+C
                if (self.chat_view.messages.items.len == 0) {
                    self.running = false;
                } else {
                    self.mode = .confirm_quit;
                }
            },
            0x14 => { // Ctrl+T
                theme.cycleTheme();
                self.status_bar.setStatus(theme.currentName());
            },
            0x1F => self.mode = .help, // Ctrl+?
            0x0C => {}, // Ctrl+L — force redraw (just re-renders next frame)
            0x0E => try self.newSession(), // Ctrl+N
            0x0F => try self.openModelSelect(), // Ctrl+O
            0x13 => try self.openSessionList(), // Ctrl+S
            0x05 => { // Ctrl+E
                if (self.editor_view.buffer.items.len == 0) {
                    try self.openExternalEditor();
                } else {
                    try self.editor_view.handleInput(&[_]u8{c});
                }
            },
            0x06 => try self.openFilePicker(), // Ctrl+F
            0x19 => self.copyLastResponse(), // Ctrl+Y
            '\t' => { // Tab — @ completion or pass to editor
                if (!self.tryAtCompletion()) {
                    try self.editor_view.handleInput(&[_]u8{c});
                }
            },
            else => try self.editor_view.handleInput(&[_]u8{c}), // Ctrl+A, Ctrl+U, Ctrl+K, Ctrl+W, etc.
        }
    }

    fn handleEnter(self: *App) !void {
        const msg = self.editor_view.getText();
        if (msg.len == 0) return;

        // Check for slash commands
        if (msg[0] == '/') {
            try self.handleSlashCommand(msg);
            self.editor_view.clear();
            return;
        }

        // Build message with attachments and @file references
        var full_msg: std.ArrayList(u8) = .empty;
        defer full_msg.deinit(self.allocator);

        // Process @file references in the message
        {
            const fw = full_msg.writer(self.allocator);
            var at_files: std.ArrayList([]const u8) = .empty;
            defer {
                for (at_files.items) |f| self.allocator.free(f);
                at_files.deinit(self.allocator);
            }

            var mi: usize = 0;
            while (mi < msg.len) {
                if (msg[mi] == '@' and mi + 1 < msg.len and (msg[mi + 1] == '.' or msg[mi + 1] == '/')) {
                    var end = mi + 1;
                    while (end < msg.len and msg[end] != ' ' and msg[end] != '\n' and msg[end] != '\t') end += 1;
                    const path = msg[mi + 1 .. end];
                    at_files.append(self.allocator, self.allocator.dupe(u8, path) catch "") catch {};
                    mi = end;
                } else {
                    mi += 1;
                }
            }

            for (at_files.items) |path| {
                if (path.len == 0) continue;
                const file_content = std.fs.cwd().readFileAlloc(self.allocator, path, 512 * 1024) catch continue;
                defer self.allocator.free(file_content);
                fw.print("<file path=\"{s}\">\n{s}\n</file>\n\n", .{ path, file_content }) catch continue;
            }
        }

        if (self.attachments.items.len > 0) {
            const fw = full_msg.writer(self.allocator);
            for (self.attachments.items) |path| {
                const content = std.fs.cwd().readFileAlloc(self.allocator, path, 512 * 1024) catch |err| {
                    try fw.print("[Failed to read {s}: {s}]\n", .{ path, @errorName(err) });
                    continue;
                };
                defer self.allocator.free(content);
                try fw.print("<file path=\"{s}\">\n{s}\n</file>\n\n", .{ path, content });
            }
            self.freeAttachments();
        }

        if (full_msg.items.len > 0) {
            const fw = full_msg.writer(self.allocator);
            try fw.writeAll(msg);
        }

        const final_msg = if (full_msg.items.len > 0) full_msg.items else msg;
        try self.chat_view.addUserMessage(final_msg);
        self.editor_view.clear();

        try self.doChat();
    }

    fn doChat(self: *App) !void {
        self.streaming = true;
        self.cancel_flag = false;
        defer {
            self.streaming = false;
            self.cancel_flag = false;
        }

        // Tool calling loop
        var iterations: u8 = 0;
        const max_iterations: u8 = 20;
        var use_tools = self.tools_supported;

        while (iterations < max_iterations) : (iterations += 1) {
            self.status_bar.setLoading(if (iterations == 0) "Thinking..." else "Using tools...");
            try self.render();

            self.chat_view.beginAssistantStream();

            // Retry with backoff on network errors
            var result: http.StreamResult = undefined;
            var retry: u8 = 0;
            const max_retries: u8 = 3;
            const backoff_ms = [_]u64{ 200, 400, 800 };

            while (true) {
                result = http.streamChat(
                    self.allocator,
                    self.cfg,
                    self.chat_view.getMessages(),
                    &self.chat_view,
                    self,
                    use_tools,
                    &self.cancel_flag,
                    self.tty,
                ) catch |err| {
                    if (err == error.Cancelled or err == error.OutOfMemory) {
                        self.chat_view.finalizeAssistantStream() catch {};
                        const err_msg: []const u8 = if (err == error.Cancelled) "Cancelled" else "Error: out of memory";
                        self.chat_view.addSystemMessage(err_msg) catch {};
                        self.status_bar.setStatus(if (err == error.Cancelled) "Cancelled" else "Error");
                        return;
                    }
                    if (retry < max_retries) {
                        var retry_msg_buf: [32]u8 = undefined;
                        const retry_msg = std.fmt.bufPrint(&retry_msg_buf, "Retry {d}/{d}...", .{ retry + 1, max_retries }) catch "Retrying...";
                        self.status_bar.setLoading(retry_msg);
                        try self.render();
                        std.Thread.sleep(backoff_ms[retry] * std.time.ns_per_ms);
                        self.chat_view.beginAssistantStream(); // Reset stream buf
                        retry += 1;
                        continue;
                    }
                    self.chat_view.finalizeAssistantStream() catch {};
                    self.chat_view.addSystemMessage("Error: API request failed") catch {};
                    self.status_bar.setStatus("Error");
                    return;
                };
                break;
            }

            // Finalize streaming buffer into a message
            self.chat_view.finalizeAssistantStream() catch {};

            // Handle API errors (e.g., model doesn't support tools)
            if (result.api_error) |api_err| {
                defer self.allocator.free(api_err);

                // If tools not supported, cache it and retry without tools
                if (use_tools and std.mem.indexOf(u8, api_err, "not support tools") != null) {
                    use_tools = false;
                    self.tools_supported = false;
                    continue;
                }

                // Show other API errors to user
                self.chat_view.addSystemMessage(api_err) catch {};
                self.status_bar.setStatus("Error");
                return;
            }

            // Track tokens
            self.chat_view.total_prompt_tokens += result.prompt_tokens;
            self.chat_view.total_completion_tokens += result.completion_tokens;
            self.status_bar.updateTokens(
                self.chat_view.total_prompt_tokens,
                self.chat_view.total_completion_tokens,
            );

            // Auto-compact if context usage > 90%
            if (self.status_bar.context_limit > 0 and
                self.chat_view.total_prompt_tokens > (self.status_bar.context_limit * 9 / 10))
            {
                self.compactContext() catch {};
            }

            // No tool calls — we're done
            if (result.tool_calls == null) {
                self.status_bar.setStatus("Ready");
                break;
            }

            // Execute tool calls
            const tcs = result.tool_calls.?;
            defer {
                for (tcs) |tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.function_name);
                    self.allocator.free(tc.arguments_json);
                }
                self.allocator.free(tcs);
            }

            // Build tool_calls JSON for the assistant message
            var tc_json: std.ArrayList(u8) = .empty;
            defer tc_json.deinit(self.allocator);
            const jw = tc_json.writer(self.allocator);
            try jw.writeByte('[');
            for (tcs, 0..) |tc, i| {
                if (i > 0) try jw.writeByte(',');
                try jw.writeAll("{\"id\":\"");
                try jw.writeAll(tc.id);
                try jw.writeAll("\",\"type\":\"function\",\"function\":{\"name\":\"");
                try jw.writeAll(tc.function_name);
                try jw.writeAll("\",\"arguments\":\"");
                // Escape the arguments JSON for embedding
                for (tc.arguments_json) |c| {
                    switch (c) {
                        '"' => try jw.writeAll("\\\""),
                        '\\' => try jw.writeAll("\\\\"),
                        '\n' => try jw.writeAll("\\n"),
                        '\r' => try jw.writeAll("\\r"),
                        '\t' => try jw.writeAll("\\t"),
                        else => try jw.writeByte(c),
                    }
                }
                try jw.writeAll("\"}}");
            }
            try jw.writeByte(']');

            // Add the assistant tool-call message
            try self.chat_view.addAssistantToolCallMessage(tc_json.items);

            // Execute each tool (with permission check for write tools)
            for (tcs) |tc| {
                self.status_bar.setLoading(tc.function_name);
                try self.render();

                // Permission check for write tools
                if (!self.auto_approve_tools and self.needsToolConfirmation(tc.function_name)) {
                    // Extract command/content for display
                    const preview = tools_mod.extractJsonString(tc.arguments_json, "command") orelse
                        tools_mod.extractJsonString(tc.arguments_json, "path") orelse
                        tc.function_name;
                    const desc = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ tc.function_name, preview }) catch null;
                    self.tool_confirm_content = desc;
                    self.mode = .tool_confirm;
                    try self.render();

                    // Wait for user input
                    while (self.mode == .tool_confirm and self.running) {
                        var confirm_buf: [32]u8 = undefined;
                        const cn = std.posix.read(self.tty, &confirm_buf) catch continue;
                        if (cn == 0) continue;
                        self.handleToolConfirmInput(confirm_buf[0]);
                        try self.render();
                    }

                    // If denied (pending_tool_call is null and content was freed)
                    if (self.tool_confirm_content != null) {
                        self.allocator.free(self.tool_confirm_content.?);
                        self.tool_confirm_content = null;
                        // Denied — add error result
                        try self.chat_view.addToolResult(tc.id, tc.function_name, "Tool execution denied by user");
                        continue;
                    }
                }

                const shell_ptr: ?*tools_mod.PersistentShell = if (self.shell) |*sh| sh else null;
                const tool_result = tools_mod.executeTool(self.allocator, tc, shell_ptr) catch |err| {
                    const err_str = try std.fmt.allocPrint(self.allocator, "Tool execution failed: {s}", .{@errorName(err)});
                    try self.chat_view.addToolResult(tc.id, tc.function_name, err_str);
                    self.allocator.free(err_str);
                    continue;
                };
                defer self.allocator.free(tool_result.content);

                try self.chat_view.addToolResult(tc.id, tc.function_name, tool_result.content);
                try self.render();
            }

            // Check cancellation
            if (self.cancel_flag) {
                self.status_bar.setStatus("Cancelled");
                return;
            }

            // Loop back to send tool results to API
        }

        if (iterations >= max_iterations) {
            self.chat_view.addSystemMessage("Tool call limit reached") catch {};
            self.status_bar.setStatus("Ready");
        }

        // Auto-save
        if (self.session_mgr) |*sm| {
            sm.save(&self.chat_view) catch {};
        }
    }

    fn handleDialogInput(self: *App, input: []const u8) !void {
        if (self.mode == .confirm_quit) {
            if (input[0] == 'y' or input[0] == 'Y' or input[0] == 3) {
                self.running = false;
            } else {
                self.mode = .normal;
            }
            return;
        }

        if (self.mode == .tool_confirm) {
            self.handleToolConfirmInput(input[0]);
            return;
        }

        if (self.mode == .copy_select) {
            self.handleCopyModeInput(input);
            return;
        }

        if (input[0] == 27 and input.len == 1) {
            self.mode = .normal;
            self.freeDialogItems();
            return;
        }

        if (self.mode == .help) {
            self.mode = .normal;
            return;
        }

        if (input.len >= 3 and input[0] == 27 and input[1] == '[') {
            if (self.dialog_view) |*dv| {
                switch (input[2]) {
                    'A' => dv.moveUp(),
                    'B' => dv.moveDown(),
                    else => {},
                }
            }
            return;
        }

        if (input[0] == '\r' or input[0] == '\n') {
            if (self.dialog_view) |*dv| {
                if (dv.getSelected()) |sel| {
                    switch (self.mode) {
                        .session_list => {
                            if (self.session_mgr) |*sm| {
                                sm.save(&self.chat_view) catch {};
                                sm.loadSession(sel.value, &self.chat_view) catch {};
                            }
                        },
                        .model_select => {
                            const model_name = self.allocator.dupe(u8, sel.value) catch return;
                            if (self.model_override) |old| self.allocator.free(old);
                            self.model_override = model_name;
                            self.cfg.model = model_name;
                            self.status_bar.cfg.model = model_name;
                            self.tools_supported = true; // Reset for new model
                        },
                        .file_picker => {
                            // Add file as attachment
                            const path = self.allocator.dupe(u8, sel.value) catch return;
                            self.attachments.append(self.allocator, path) catch {
                                self.allocator.free(path);
                            };
                            self.status_bar.setStatus("File attached");
                        },
                        else => {},
                    }
                }
            }
            self.mode = .normal;
            self.freeDialogItems();
            return;
        }

        if (input[0] == 3 or input[0] == 'q') {
            self.mode = .normal;
            self.freeDialogItems();
            return;
        }
    }

    fn handleSlashCommand(self: *App, msg: []const u8) !void {
        if (std.mem.eql(u8, msg, "/new") or std.mem.eql(u8, msg, "/n")) {
            try self.newSession();
        } else if (std.mem.eql(u8, msg, "/quit") or std.mem.eql(u8, msg, "/q")) {
            self.running = false;
        } else if (std.mem.eql(u8, msg, "/clear")) {
            self.clearMessages();
            self.status_bar.setStatus("Cleared");
        } else if (std.mem.eql(u8, msg, "/help") or std.mem.eql(u8, msg, "/h") or std.mem.eql(u8, msg, "/?")) {
            self.mode = .help;
        } else if (std.mem.eql(u8, msg, "/theme")) {
            theme.cycleTheme();
            self.status_bar.setStatus(theme.currentName());
        } else if (std.mem.eql(u8, msg, "/model")) {
            try self.openModelSelect();
        } else if (std.mem.eql(u8, msg, "/sessions")) {
            try self.openSessionList();
        } else if (std.mem.startsWith(u8, msg, "/init")) {
            try self.initProject();
        } else if (std.mem.eql(u8, msg, "/compact")) {
            try self.compactContext();
        } else if (std.mem.eql(u8, msg, "/copy")) {
            self.enterCopyMode();
        } else {
            self.chat_view.addSystemMessage("Unknown command. Try /help") catch {};
        }
    }

    fn compactContext(self: *App) !void {
        // Summarize the conversation so far to reduce context size
        if (self.chat_view.messages.items.len < 4) {
            self.chat_view.addSystemMessage("Not enough messages to compact") catch {};
            return;
        }

        self.status_bar.setLoading("Compacting...");
        try self.render();

        // Build a summary prompt
        var summary_prompt: std.ArrayList(u8) = .empty;
        defer summary_prompt.deinit(self.allocator);
        const spw = summary_prompt.writer(self.allocator);
        try spw.writeAll("Summarize the following conversation in a concise paragraph, preserving key decisions, code changes, and context:\n\n");

        for (self.chat_view.messages.items) |msg| {
            if (msg.role == .tool) continue;
            if (msg.role == .assistant and msg.content.len == 0) continue;
            const role_name: []const u8 = switch (msg.role) {
                .user => "User",
                .assistant => "Assistant",
                .system => "System",
                .tool => continue,
            };
            try spw.print("{s}: {s}\n\n", .{ role_name, if (msg.content.len > 500) msg.content[0..500] else msg.content });
        }

        const messages = [_]chat.Message{
            .{ .role = .user, .content = summary_prompt.items },
        };
        const summary = http.chatOnce(self.allocator, self.cfg, &messages) catch {
            self.chat_view.addSystemMessage("Compact failed") catch {};
            self.status_bar.setStatus("Error");
            return;
        };

        // Clear all messages and add summary as system message
        self.clearMessages();

        try self.chat_view.addSystemMessage(summary);
        self.allocator.free(summary);
        self.chat_view.total_prompt_tokens = 0;
        self.chat_view.total_completion_tokens = 0;
        self.status_bar.updateTokens(0, 0);
        self.status_bar.setStatus("Compacted");
    }

    fn initProject(self: *App) !void {
        // Create/update project context file
        const init_prompt = "Analyze this project directory and create an OpenCode.md file with:\n" ++
            "1. Build/lint/test commands\n2. Code style guidelines\n3. Key file locations\n4. Architecture overview\n" ++
            "Run `find . -maxdepth 3 -type f | head -50` and `cat package.json 2>/dev/null || cat Cargo.toml 2>/dev/null || cat build.zig 2>/dev/null || cat go.mod 2>/dev/null` first to understand the project, then write the OpenCode.md file.";
        try self.chat_view.addUserMessage(init_prompt);
        try self.doChat();
    }

    fn newSession(self: *App) !void {
        if (self.session_mgr) |*sm| {
            sm.save(&self.chat_view) catch {};
            self.clearMessages();
            self.chat_view.total_prompt_tokens = 0;
            self.chat_view.total_completion_tokens = 0;
            sm.newSession() catch {};
            self.status_bar.setStatus("New session");
        }
    }

    fn openSessionList(self: *App) !void {
        const sm = &(self.session_mgr orelse return);
        const sessions = sm.listSessions() catch return;
        if (sessions.len == 0) {
            self.allocator.free(sessions);
            self.status_bar.setStatus("No sessions");
            return;
        }
        self.freeDialogItems();
        var items = try self.allocator.alloc(dialog.DialogItem, sessions.len);
        for (sessions, 0..) |s, i| {
            items[i] = .{ .label = s.title, .value = s.id };
        }
        self.allocator.free(sessions);
        self.dialog_items = items;
        self.dialog_view = dialog.Dialog.init(self.allocator, "Sessions", items);
        self.dialog_view.?.visible = true;
        self.mode = .session_list;
    }

    fn openModelSelect(self: *App) !void {
        const models = self.fetchModels() catch {
            self.status_bar.setStatus("Failed to fetch models");
            return;
        };
        if (models.len == 0) {
            self.allocator.free(models);
            self.status_bar.setStatus("No models found");
            return;
        }
        self.freeDialogItems();
        self.dialog_items = models;
        self.dialog_view = dialog.Dialog.init(self.allocator, "Select Model", models);
        self.dialog_view.?.visible = true;
        self.mode = .model_select;
    }

    fn openFilePicker(self: *App) !void {
        // List files in CWD
        const argv = [_][]const u8{ "find", ".", "-maxdepth", "3", "-type", "f", "-not", "-path", "./.git/*", "-not", "-path", "./.zig-cache/*", "-not", "-path", "./node_modules/*" };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var read_buf: [4096]u8 = undefined;
        if (child.stdout) |pipe| {
            while (true) {
                const nn = pipe.read(&read_buf) catch break;
                if (nn == 0) break;
                try out.appendSlice(self.allocator, read_buf[0..nn]);
                if (out.items.len > 32 * 1024) break;
            }
        }
        _ = child.wait() catch {};

        // Parse into items
        var items_list: std.ArrayList(dialog.DialogItem) = .empty;
        defer items_list.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, out.items, '\n');
        var count: usize = 0;
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            if (count >= 50) break;
            const label = try self.allocator.dupe(u8, line);
            const value = try self.allocator.dupe(u8, line);
            try items_list.append(self.allocator, .{ .label = label, .value = value });
            count += 1;
        }

        if (items_list.items.len == 0) {
            self.status_bar.setStatus("No files found");
            return;
        }

        self.freeDialogItems();
        const items = try items_list.toOwnedSlice(self.allocator);
        self.dialog_items = items;
        self.dialog_view = dialog.Dialog.init(self.allocator, "Attach File", items);
        self.dialog_view.?.visible = true;
        self.mode = .file_picker;
    }

    fn fetchModels(self: *App) ![]dialog.DialogItem {
        var url_buf: [512]u8 = undefined;
        const endpoint = self.cfg.endpoint;
        const base = if (std.mem.endsWith(u8, endpoint, "/v1"))
            endpoint[0 .. endpoint.len - 3]
        else
            endpoint;

        const url = std.fmt.bufPrint(&url_buf, "{s}/api/tags", .{base}) catch return error.UrlTooLong;

        const argv = [_][]const u8{ "curl", "-s", "--max-time", "5", url };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(self.allocator);
        var read_buf: [4096]u8 = undefined;
        if (child.stdout) |pipe| {
            while (true) {
                const nn = pipe.read(&read_buf) catch break;
                if (nn == 0) break;
                try response.appendSlice(self.allocator, read_buf[0..nn]);
            }
        }
        _ = child.wait() catch {};

        var items: std.ArrayList(dialog.DialogItem) = .empty;
        defer items.deinit(self.allocator);

        const data = response.items;
        const needle = "\"name\":\"";
        var pos: usize = 0;
        while (pos < data.len) {
            const start = std.mem.indexOf(u8, data[pos..], needle) orelse break;
            const name_start = pos + start + needle.len;
            const name_end_rel = std.mem.indexOf(u8, data[name_start..], "\"") orelse break;
            const name = data[name_start .. name_start + name_end_rel];

            const label = try self.allocator.dupe(u8, name);
            const value = try self.allocator.dupe(u8, name);
            try items.append(self.allocator, .{ .label = label, .value = value });
            pos = name_start + name_end_rel + 1;
        }

        return try items.toOwnedSlice(self.allocator);
    }

    fn loadContextFiles(self: *App) void {
        if (self.context_loaded) return;
        self.context_loaded = true;

        const context_files = [_][]const u8{
            "CLAUDE.md",
            "CLAUDE.local.md",
            "opencode.md",
            "opencode.local.md",
            "OpenCode.md",
            "OpenCode.local.md",
            "OPENCODE.md",
            ".cursorrules",
            ".github/copilot-instructions.md",
        };

        var context: std.ArrayList(u8) = .empty;
        defer context.deinit(self.allocator);
        const w = context.writer(self.allocator);

        for (context_files) |path| {
            const content = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch continue;
            defer self.allocator.free(content);
            w.print("# Context from {s}:\n{s}\n\n", .{ path, content }) catch continue;
        }

        if (context.items.len > 0) {
            self.chat_view.addSystemMessage(context.items) catch {};
        }
    }

    fn tryAtCompletion(self: *App) bool {
        const buf = self.editor_view.buffer.items;
        const cursor = self.editor_view.cursor;

        // Find @ before cursor
        var at_pos: ?usize = null;
        var i: usize = cursor;
        while (i > 0) {
            i -= 1;
            if (buf[i] == '@') {
                at_pos = i;
                break;
            }
            if (buf[i] == ' ' or buf[i] == '\n') break;
        }

        const atp = at_pos orelse return false;
        const prefix = buf[atp + 1 .. cursor];

        // Find matching files
        var cmd_buf: [512]u8 = undefined;
        const cmd = if (prefix.len > 0)
            std.fmt.bufPrint(&cmd_buf, "find . -maxdepth 3 -type f -not -path './.git/*' -not -path './.zig-cache/*' -not -path './node_modules/*' -name '*{s}*' 2>/dev/null | head -1", .{prefix}) catch return false
        else
            return false;

        const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var read_buf: [1024]u8 = undefined;
        if (child.stdout) |pipe| {
            while (true) {
                const n = pipe.read(&read_buf) catch break;
                if (n == 0) break;
                out.appendSlice(self.allocator, read_buf[0..n]) catch break;
            }
        }
        _ = child.wait() catch {};

        // Get first result line
        const result = std.mem.trimRight(u8, out.items, "\n\r");
        if (result.len == 0) return false;

        // Replace @prefix with @filepath
        const remove_count = cursor - atp;
        var j: usize = 0;
        while (j < remove_count) : (j += 1) {
            _ = self.editor_view.buffer.orderedRemove(atp);
        }
        self.editor_view.cursor = atp;

        // Insert @filepath
        const completion = std.fmt.allocPrint(self.allocator, "@{s} ", .{result}) catch return false;
        defer self.allocator.free(completion);

        for (completion) |c| {
            self.editor_view.buffer.insert(self.allocator, self.editor_view.cursor, c) catch break;
            self.editor_view.cursor += 1;
        }

        return true;
    }

    fn openExternalEditor(self: *App) !void {
        const editor_cmd = std.posix.getenv("EDITOR") orelse std.posix.getenv("VISUAL") orelse "vi";

        // Create temp file
        var tmp_path_buf: [256]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "/tmp/sniper_edit_{d}.md", .{std.time.timestamp()}) catch return;

        // Write current buffer content to temp file
        const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
        if (self.editor_view.buffer.items.len > 0) {
            tmp_file.writeAll(self.editor_view.buffer.items) catch {};
        }
        tmp_file.close();

        // Restore terminal
        writeOut("\x1b[?2004l\x1b[?25h\x1b[?1049l");
        std.posix.tcsetattr(self.tty, .FLUSH, self.original_termios) catch {};

        // Spawn editor
        const argv = [_][]const u8{ editor_cmd, tmp_path };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            // Re-enter raw mode
            self.reenterRawMode();
            return;
        };
        _ = child.wait() catch {};

        // Re-enter raw mode
        self.reenterRawMode();

        // Read back the file
        const edited = std.fs.cwd().readFileAlloc(self.allocator, tmp_path, 512 * 1024) catch return;
        defer self.allocator.free(edited);

        // Delete temp file
        std.fs.deleteFileAbsolute(tmp_path) catch {};

        // Put edited content into buffer
        if (edited.len > 0) {
            self.editor_view.clear();
            for (edited) |c| {
                self.editor_view.buffer.append(self.allocator, c) catch break;
            }
            self.editor_view.cursor = self.editor_view.buffer.items.len;
        }
    }

    fn reenterRawMode(self: *App) void {
        const ECHO: u64 = 0x00000008;
        const ICANON: u64 = 0x00000100;
        const ISIG: u64 = 0x00000080;
        const IEXTEN: u64 = 0x00000400;
        const IXON: u64 = 0x00000200;
        const ICRNL: u64 = 0x00000100;
        const BRKINT: u64 = 0x00000002;
        const INPCK: u64 = 0x00000010;
        const ISTRIP: u64 = 0x00000020;

        var raw = self.original_termios;
        raw.lflag = @bitCast(@as(u64, @bitCast(raw.lflag)) & ~(ECHO | ICANON | ISIG | IEXTEN));
        raw.iflag = @bitCast(@as(u64, @bitCast(raw.iflag)) & ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP));
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        std.posix.tcsetattr(self.tty, .FLUSH, raw) catch {};
        writeOut("\x1b[?1049h\x1b[?25l\x1b[?2004h");
    }

    fn renderToolConfirm(self: *App, writer: anytype, t: theme.Theme) !void {
        const tc_content = self.tool_confirm_content orelse "Execute tool?";
        const box_width: u16 = @min(self.width -| 4, 70);
        const box_height: u16 = 5;
        const row = (self.height -| box_height) / 2;
        const col = (self.width -| box_width) / 2;

        // Top border
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xad", .{ row, col, t.border });
        var bi: u16 = 0;
        while (bi < box_width -| 2) : (bi += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x95\xae\x1b[0m");

        // Title
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m \x1b[1mAllow tool execution?\x1b[0m", .{ row + 1, col, t.border });
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row + 1, col + box_width - 1, t.border });

        // Content (truncated)
        const max_content = @as(usize, box_width) -| 4;
        const display = if (tc_content.len > max_content) tc_content[0..max_content] else tc_content;
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m \x1b[2m{s}\x1b[0m", .{ row + 2, col, t.border, display });
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row + 2, col + box_width - 1, t.border });

        // Options
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m (y)es (n)o (a)lways", .{ row + 3, col, t.border });
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row + 3, col + box_width - 1, t.border });

        // Bottom border
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xb0", .{ row + 4, col, t.border });
        bi = 0;
        while (bi < box_width -| 2) : (bi += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x95\xaf\x1b[0m");
    }

    fn handleToolConfirmInput(self: *App, c: u8) void {
        switch (c) {
            'y', 'Y' => {
                self.mode = .normal;
                self.pending_tool_call = null;
                if (self.tool_confirm_content) |tc| {
                    self.allocator.free(tc);
                    self.tool_confirm_content = null;
                }
                // Tool approved — execution continues in doChat
            },
            'a', 'A' => {
                self.auto_approve_tools = true;
                self.mode = .normal;
                self.pending_tool_call = null;
                if (self.tool_confirm_content) |tc| {
                    self.allocator.free(tc);
                    self.tool_confirm_content = null;
                }
            },
            'n', 'N', 27 => {
                self.mode = .normal;
                self.pending_tool_call = null;
                if (self.tool_confirm_content) |tc| {
                    self.allocator.free(tc);
                    self.tool_confirm_content = null;
                }
            },
            else => {},
        }
    }

    fn needsToolConfirmation(_: *App, tool_name: []const u8) bool {
        return std.mem.eql(u8, tool_name, "bash") or
            std.mem.eql(u8, tool_name, "write_file") or
            std.mem.eql(u8, tool_name, "edit_file");
    }

    fn enterCopyMode(self: *App) void {
        // Find visible message indices (skip tool-call-only)
        var last_visible: ?usize = null;
        for (self.chat_view.messages.items, 0..) |msg, i| {
            if (msg.role == .assistant and msg.content.len == 0 and msg.tool_calls_json != null) continue;
            if (msg.role == .tool) continue;
            last_visible = i;
        }

        if (last_visible == null) {
            self.status_bar.setStatus("No messages");
            return;
        }

        self.selected_message = last_visible;
        self.mode = .copy_select;
        self.status_bar.setStatus("Copy mode: \xe2\x86\x91\xe2\x86\x93 select, Enter copy, b blocks, ESC exit");
    }

    fn handleCopyModeInput(self: *App, input: []const u8) void {
        if (input[0] == 27) {
            if (input.len == 1) {
                // ESC — exit copy mode
                self.mode = .normal;
                self.selected_message = null;
                self.status_bar.setStatus("Ready");
                return;
            }
            if (input.len >= 3 and input[1] == '[') {
                switch (input[2]) {
                    'A' => self.copyModeUp(), // Up
                    'B' => self.copyModeDown(), // Down
                    else => {},
                }
                return;
            }
        }

        if (input[0] == '\r' or input[0] == '\n') {
            // Copy selected message
            if (self.selected_message) |idx| {
                if (idx < self.chat_view.messages.items.len) {
                    const msg = self.chat_view.messages.items[idx];
                    if (msg.content.len > 0) {
                        const stripped = markdown.stripThinkBlocks(self.allocator, msg.content) catch msg.content;
                        defer if (stripped.ptr != msg.content.ptr) self.allocator.free(stripped);
                        self.copyToClipboard(stripped);
                    }
                }
            }
            self.mode = .normal;
            self.selected_message = null;
            return;
        }

        if (input[0] == 'b' or input[0] == 'B') {
            // Extract code blocks from selected message
            if (self.selected_message) |idx| {
                if (idx < self.chat_view.messages.items.len) {
                    const msg = self.chat_view.messages.items[idx];
                    self.showCodeBlockPicker(msg.content);
                }
            }
            return;
        }

        if (input[0] == 'q') {
            self.mode = .normal;
            self.selected_message = null;
            self.status_bar.setStatus("Ready");
        }
    }

    fn copyModeUp(self: *App) void {
        const sel = self.selected_message orelse return;
        var i = sel;
        while (i > 0) {
            i -= 1;
            const msg = self.chat_view.messages.items[i];
            if (msg.role == .assistant and msg.content.len == 0 and msg.tool_calls_json != null) continue;
            if (msg.role == .tool) continue;
            self.selected_message = i;
            return;
        }
    }

    fn copyModeDown(self: *App) void {
        const sel = self.selected_message orelse return;
        var i = sel + 1;
        while (i < self.chat_view.messages.items.len) {
            const msg = self.chat_view.messages.items[i];
            if (msg.role == .assistant and msg.content.len == 0 and msg.tool_calls_json != null) {
                i += 1;
                continue;
            }
            if (msg.role == .tool) {
                i += 1;
                continue;
            }
            self.selected_message = i;
            return;
        }
    }

    fn showCodeBlockPicker(self: *App, content: []const u8) void {
        const blocks = markdown.extractCodeBlocks(self.allocator, content) catch return;
        if (blocks.len == 0) {
            self.allocator.free(blocks);
            self.status_bar.setStatus("No code blocks");
            return;
        }

        self.freeDialogItems();
        var items = self.allocator.alloc(dialog.DialogItem, blocks.len) catch {
            for (blocks) |b| self.allocator.free(b);
            self.allocator.free(blocks);
            return;
        };

        for (blocks, 0..) |block, i| {
            const preview = if (block.len > 40) block[0..40] else block;
            const label = std.fmt.allocPrint(self.allocator, "Block {d}: {s}...", .{ i + 1, preview }) catch self.allocator.dupe(u8, "Block") catch "";
            items[i] = .{ .label = label, .value = block };
        }
        self.allocator.free(blocks);

        self.dialog_items = items;
        self.dialog_view = dialog.Dialog.init(self.allocator, "Code Blocks", items);
        self.dialog_view.?.visible = true;
        self.mode = .file_picker; // Reuse file_picker mode for selection, but copy on select

        // Override: when selected, copy the block
        // We'll use the file_picker handler but check context
    }

    fn copyLastResponse(self: *App) void {
        // Find last assistant message
        var last_assistant: ?[]const u8 = null;
        var i = self.chat_view.messages.items.len;
        while (i > 0) {
            i -= 1;
            const msg = self.chat_view.messages.items[i];
            if (msg.role == .assistant and msg.content.len > 0) {
                last_assistant = msg.content;
                break;
            }
        }

        const content = last_assistant orelse {
            self.status_bar.setStatus("Nothing to copy");
            return;
        };

        // Strip think blocks before copying
        const stripped = markdown.stripThinkBlocks(self.allocator, content) catch content;
        defer if (stripped.ptr != content.ptr) self.allocator.free(stripped);

        self.copyToClipboard(stripped);
    }

    fn copyToClipboard(self: *App, text: []const u8) void {
        // Try pbcopy (macOS)
        const argv = [_][]const u8{"pbcopy"};
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            // Fallback: OSC 52 escape sequence
            self.copyViaOsc52(text);
            return;
        };

        if (child.stdin) |stdin| {
            stdin.writeAll(text) catch {};
            stdin.close();
            child.stdin = null;
        }
        _ = child.wait() catch {};
        self.status_bar.setStatus("Copied!");
    }

    fn copyViaOsc52(self: *App, text: []const u8) void {
        _ = self;
        const base64_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        // Write OSC 52: \x1b]52;c;<base64>\x07
        writeOut("\x1b]52;c;");
        var i: usize = 0;
        while (i < text.len) {
            const remaining = text.len - i;
            const b0 = text[i];
            const b1: u8 = if (remaining > 1) text[i + 1] else 0;
            const b2: u8 = if (remaining > 2) text[i + 2] else 0;

            const c0 = base64_alpha[b0 >> 2];
            const c1 = base64_alpha[((b0 & 0x03) << 4) | (b1 >> 4)];
            const c2 = if (remaining > 1) base64_alpha[((b1 & 0x0f) << 2) | (b2 >> 6)] else @as(u8, '=');
            const c3 = if (remaining > 2) base64_alpha[b2 & 0x3f] else @as(u8, '=');

            stdout.writeAll(&[_]u8{ c0, c1, c2, c3 }) catch {};
            i += 3;
        }
        writeOut("\x07");
    }

    fn renderQuitConfirm(writer: anytype, term_width: u16, term_height: u16, t: theme.Theme) !void {
        const msg = "Quit sniper? (y/n)";
        const box_width: u16 = 30;
        const box_height: u16 = 3;
        const row = (term_height -| box_height) / 2;
        const col = (term_width -| box_width) / 2;

        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xad", .{ row, col, t.border });
        var i: u16 = 0;
        while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x95\xae\x1b[0m");

        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m \x1b[1m{s}\x1b[0m", .{ row + 1, col, t.border, msg });
        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x94\x82\x1b[0m", .{ row + 1, col + box_width - 1, t.border });

        try writer.print("\x1b[{d};{d}H\x1b[{s}m\xe2\x95\xb0", .{ row + 2, col, t.border });
        i = 0;
        while (i < box_width -| 2) : (i += 1) try writer.writeAll("\xe2\x94\x80");
        try writer.writeAll("\xe2\x95\xaf\x1b[0m");
    }
};
