const std = @import("std");

pub const PersistentShell = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,

    const sentinel_prefix = "__SNIPER_EXIT_";
    const sentinel_suffix = "__";

    pub fn init(allocator: std.mem.Allocator) !PersistentShell {
        const argv = [_][]const u8{ "/bin/bash", "--norc", "--noprofile" };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        return .{ .child = child, .allocator = allocator };
    }

    pub fn deinit(self: *PersistentShell) void {
        if (self.child.stdin) |stdin| {
            stdin.writeAll("exit\n") catch {};
            stdin.close();
            self.child.stdin = null;
        }
        _ = self.child.wait() catch {};
    }

    pub fn exec(self: *PersistentShell, command: []const u8) !ToolResult {
        const stdin = self.child.stdin orelse return error.NoPipe;
        const stdout_pipe = self.child.stdout orelse return error.NoPipe;

        // Write command with sentinel
        stdin.writeAll(command) catch return error.WriteFailed;
        stdin.writeAll("\necho \"") catch return error.WriteFailed;
        stdin.writeAll(sentinel_prefix) catch return error.WriteFailed;
        stdin.writeAll("$?") catch return error.WriteFailed;
        stdin.writeAll(sentinel_suffix) catch return error.WriteFailed;
        stdin.writeAll("\"\n") catch return error.WriteFailed;

        // Read output until sentinel appears
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var read_buf: [4096]u8 = undefined;

        // Use poll to avoid blocking forever
        const fd = stdout_pipe.handle;
        var poll_fds = [1]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        var exit_code: u8 = 0;
        const timeout_ms: i32 = 30000; // 30 second timeout

        while (true) {
            const poll_rc = std.posix.poll(&poll_fds, timeout_ms) catch break;
            if (poll_rc == 0) break; // timeout

            if (poll_fds[0].revents & std.posix.POLL.IN == 0) break;

            const n = stdout_pipe.read(&read_buf) catch break;
            if (n == 0) break;

            try output.appendSlice(self.allocator, read_buf[0..n]);

            // Check if sentinel appeared
            if (std.mem.indexOf(u8, output.items, sentinel_prefix)) |sentinel_start| {
                // Find the exit code and sentinel end
                const code_start = sentinel_start + sentinel_prefix.len;
                if (std.mem.indexOf(u8, output.items[code_start..], sentinel_suffix)) |suffix_offset| {
                    const code_end = code_start + suffix_offset;
                    const code_str = output.items[code_start..code_end];
                    exit_code = std.fmt.parseInt(u8, code_str, 10) catch 1;

                    // Remove sentinel line from output
                    // Find the newline before sentinel
                    var line_start = sentinel_start;
                    if (line_start > 0 and output.items[line_start - 1] == '\n') {
                        line_start -= 1;
                    }
                    output.items.len = line_start;
                    break;
                }
            }

            if (output.items.len > 30 * 1024) break; // 30KB limit
        }

        if (output.items.len == 0) {
            return .{
                .content = try std.fmt.allocPrint(self.allocator, "[exit code: {d}]", .{exit_code}),
                .is_error = exit_code != 0,
            };
        }

        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);
        const w = result.writer(self.allocator);
        try w.writeAll(output.items);
        if (exit_code != 0) {
            try w.print("\n[exit code: {d}]", .{exit_code});
        }

        return .{
            .content = try self.allocator.dupe(u8, result.items),
            .is_error = exit_code != 0,
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    function_name: []const u8,
    arguments_json: []const u8,
};

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,
};

/// Tool definitions for the OpenAI-compatible API
pub const tool_definitions =
    \\[{"type":"function","function":{"name":"bash","description":"Execute a shell command. Use for running programs, installing packages, file operations, git, etc.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read the contents of a file at the given path.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative file path"},"offset":{"type":"integer","description":"Line offset to start reading from (0-based)"},"limit":{"type":"integer","description":"Max number of lines to read"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write content to a file, creating it if it doesn't exist or overwriting if it does.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"File path to write to"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Replace exact text in a file. old_string must match exactly.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"old_string":{"type":"string","description":"Exact text to find and replace"},"new_string":{"type":"string","description":"Replacement text"}},"required":["path","old_string","new_string"]}}},
    \\{"type":"function","function":{"name":"glob","description":"Find files matching a glob pattern.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. **/*.zig, src/*.ts)"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Search file contents for a regex pattern.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern to search for"},"path":{"type":"string","description":"File or directory to search in"},"include":{"type":"string","description":"Glob to filter files (e.g. *.zig)"}},"required":["pattern"]}}}]
;

/// Execute a tool call and return the result
pub fn executeTool(allocator: std.mem.Allocator, tc: ToolCall, shell: ?*PersistentShell) !ToolResult {
    // Parse the function name and dispatch
    if (std.mem.eql(u8, tc.function_name, "bash")) {
        if (shell) |sh| {
            return executeBashPersistent(allocator, tc.arguments_json, sh);
        }
        return executeBash(allocator, tc.arguments_json);
    } else if (std.mem.eql(u8, tc.function_name, "read_file")) {
        return executeReadFile(allocator, tc.arguments_json);
    } else if (std.mem.eql(u8, tc.function_name, "write_file")) {
        return executeWriteFile(allocator, tc.arguments_json);
    } else if (std.mem.eql(u8, tc.function_name, "edit_file")) {
        return executeEditFile(allocator, tc.arguments_json);
    } else if (std.mem.eql(u8, tc.function_name, "glob")) {
        return executeGlob(allocator, tc.arguments_json);
    } else if (std.mem.eql(u8, tc.function_name, "grep")) {
        return executeGrep(allocator, tc.arguments_json);
    }
    return .{
        .content = try allocator.dupe(u8, "Unknown tool"),
        .is_error = true,
    };
}

fn executeBashPersistent(allocator: std.mem.Allocator, args_json: []const u8, shell: *PersistentShell) !ToolResult {
    const command = extractJsonString(args_json, "command") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'command' argument"), .is_error = true };
    };
    const cmd = try jsonUnescape(allocator, command);
    defer allocator.free(cmd);

    return shell.exec(cmd) catch {
        // Fallback to non-persistent execution
        return executeBash(allocator, args_json);
    };
}

fn executeBash(allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
    const command = extractJsonString(args_json, "command") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'command' argument"), .is_error = true };
    };

    // Unescape the command string
    const cmd = try jsonUnescape(allocator, command);
    defer allocator.free(cmd);

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Read stdout and stderr
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;

    // Read stdout
    if (child.stdout) |pipe| {
        while (true) {
            const n = pipe.read(&read_buf) catch break;
            if (n == 0) break;
            try stdout_buf.appendSlice(allocator, read_buf[0..n]);
            if (stdout_buf.items.len > 30 * 1024) break; // 30KB limit
        }
    }

    // Read stderr
    if (child.stderr) |pipe| {
        while (true) {
            const n = pipe.read(&read_buf) catch break;
            if (n == 0) break;
            try stderr_buf.appendSlice(allocator, read_buf[0..n]);
            if (stderr_buf.items.len > 10 * 1024) break;
        }
    }

    const term = child.wait() catch {
        return .{ .content = try allocator.dupe(u8, "Failed to wait for process"), .is_error = true };
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    const w = result.writer(allocator);

    if (stdout_buf.items.len > 0) {
        try w.writeAll(stdout_buf.items);
    }
    if (stderr_buf.items.len > 0) {
        if (stdout_buf.items.len > 0) try w.writeByte('\n');
        try w.writeAll("STDERR: ");
        try w.writeAll(stderr_buf.items);
    }

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        try w.print("\n[exit code: {d}]", .{exit_code});
    }

    if (result.items.len == 0) {
        return .{
            .content = try std.fmt.allocPrint(allocator, "[exit code: {d}]", .{exit_code}),
            .is_error = exit_code != 0,
        };
    }

    return .{
        .content = try allocator.dupe(u8, result.items),
        .is_error = exit_code != 0,
    };
}

fn executeReadFile(allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
    const path_raw = extractJsonString(args_json, "path") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'path' argument"), .is_error = true };
    };
    const path = try jsonUnescape(allocator, path_raw);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Cannot open file: {s}: {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Cannot read file: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };

    // Apply offset/limit if specified
    const offset_str = extractJsonString(args_json, "offset");
    const limit_str = extractJsonString(args_json, "limit");

    if (offset_str != null or limit_str != null) {
        // Split into lines and apply offset/limit
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(allocator);
        const lw = lines.writer(allocator);

        var line_num: usize = 0;
        const offset_val = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
        const limit_val = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch std.math.maxInt(usize) else std.math.maxInt(usize);

        var iter = std.mem.splitScalar(u8, content, '\n');
        var count: usize = 0;
        while (iter.next()) |line| {
            if (line_num >= offset_val and count < limit_val) {
                try lw.print("{d}: {s}\n", .{ line_num + 1, line });
                count += 1;
            }
            line_num += 1;
        }
        allocator.free(content);
        return .{ .content = try allocator.dupe(u8, lines.items), .is_error = false };
    }

    return .{ .content = content, .is_error = false };
}

fn executeWriteFile(allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
    const path_raw = extractJsonString(args_json, "path") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'path' argument"), .is_error = true };
    };
    const content_raw = extractJsonString(args_json, "content") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'content' argument"), .is_error = true };
    };

    const path = try jsonUnescape(allocator, path_raw);
    defer allocator.free(path);
    const content = try jsonUnescape(allocator, content_raw);
    defer allocator.free(content);

    // Create parent directories if needed
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        const dir_path = path[0..idx];
        std.fs.cwd().makePath(dir_path) catch {};
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Cannot create file: {s}: {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Write failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };

    return .{
        .content = try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ content.len, path }),
        .is_error = false,
    };
}

fn executeEditFile(allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
    const path_raw = extractJsonString(args_json, "path") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'path' argument"), .is_error = true };
    };
    const old_raw = extractJsonString(args_json, "old_string") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'old_string' argument"), .is_error = true };
    };
    const new_raw = extractJsonString(args_json, "new_string") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'new_string' argument"), .is_error = true };
    };

    const path = try jsonUnescape(allocator, path_raw);
    defer allocator.free(path);
    const old_str = try jsonUnescape(allocator, old_raw);
    defer allocator.free(old_str);
    const new_str = try jsonUnescape(allocator, new_raw);
    defer allocator.free(new_str);

    // Read existing file
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Cannot read file: {s}: {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer allocator.free(content);

    // Find and replace
    if (std.mem.indexOf(u8, content, old_str)) |idx| {
        const new_content = try std.mem.concat(allocator, u8, &.{
            content[0..idx],
            new_str,
            content[idx + old_str.len ..],
        });
        defer allocator.free(new_content);

        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(allocator, "Cannot write file: {s}", .{@errorName(err)}),
                .is_error = true,
            };
        };
        defer file.close();
        file.writeAll(new_content) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(allocator, "Write failed: {s}", .{@errorName(err)}),
                .is_error = true,
            };
        };

        // Build a diff-like output
        var diff_out: std.ArrayList(u8) = .empty;
        defer diff_out.deinit(allocator);
        const dw = diff_out.writer(allocator);
        try dw.print("Edited {s}\n", .{path});

        // Show removed lines
        var old_lines = std.mem.splitScalar(u8, old_str, '\n');
        while (old_lines.next()) |line| {
            try dw.print("- {s}\n", .{line});
        }
        // Show added lines
        var new_lines = std.mem.splitScalar(u8, new_str, '\n');
        while (new_lines.next()) |line| {
            try dw.print("+ {s}\n", .{line});
        }

        return .{
            .content = try allocator.dupe(u8, diff_out.items),
            .is_error = false,
        };
    }

    return .{
        .content = try std.fmt.allocPrint(allocator, "old_string not found in {s}", .{path}),
        .is_error = true,
    };
}

fn executeGlob(allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
    const pattern_raw = extractJsonString(args_json, "pattern") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'pattern' argument"), .is_error = true };
    };
    const pattern = try jsonUnescape(allocator, pattern_raw);
    defer allocator.free(pattern);

    // Use find command for glob matching
    const cmd = try std.fmt.allocPrint(allocator, "find . -path './{s}' -type f 2>/dev/null | head -50 | sort", .{pattern});
    defer allocator.free(cmd);

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = pipe.read(&read_buf) catch break;
            if (n == 0) break;
            try out.appendSlice(allocator, read_buf[0..n]);
        }
    }
    _ = child.wait() catch {};

    if (out.items.len == 0) {
        return .{ .content = try allocator.dupe(u8, "No files matched"), .is_error = false };
    }
    return .{ .content = try allocator.dupe(u8, out.items), .is_error = false };
}

fn executeGrep(allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
    const pattern_raw = extractJsonString(args_json, "pattern") orelse {
        return .{ .content = try allocator.dupe(u8, "Missing 'pattern' argument"), .is_error = true };
    };
    const pattern = try jsonUnescape(allocator, pattern_raw);
    defer allocator.free(pattern);

    const path_raw = extractJsonString(args_json, "path");
    const search_path = if (path_raw) |p| try jsonUnescape(allocator, p) else try allocator.dupe(u8, ".");
    defer allocator.free(search_path);

    const include_raw = extractJsonString(args_json, "include");

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(allocator);
    const cw = cmd_buf.writer(allocator);
    try cw.print("grep -rn --include='*' ", .{});
    if (include_raw) |inc| {
        const inc_val = try jsonUnescape(allocator, inc);
        defer allocator.free(inc_val);
        // Re-write with include filter
        cmd_buf.clearRetainingCapacity();
        try cw.print("grep -rn --include='{s}' ", .{inc_val});
    }
    // Escape pattern for shell
    try cw.writeByte('\'');
    for (pattern) |c| {
        if (c == '\'') {
            try cw.writeAll("'\\''");
        } else {
            try cw.writeByte(c);
        }
    }
    try cw.writeAll("' ");
    try cw.writeAll(search_path);
    try cw.writeAll(" 2>/dev/null | head -50");

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd_buf.items };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = pipe.read(&read_buf) catch break;
            if (n == 0) break;
            try out.appendSlice(allocator, read_buf[0..n]);
        }
    }
    _ = child.wait() catch {};

    if (out.items.len == 0) {
        return .{ .content = try allocator.dupe(u8, "No matches found"), .is_error = false };
    }
    return .{ .content = try allocator.dupe(u8, out.items), .is_error = false };
}

// --- JSON helpers ---

/// Extract a string value from a JSON object by key name
/// Returns the raw (still-escaped) string content between quotes
pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value" or "key": "value"
    var search_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;

    // Skip whitespace and colon
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1; // skip opening quote

    // Find closing quote (handle escapes)
    const start = pos;
    while (pos < json.len) {
        if (json[pos] == '\\') {
            pos += 2;
            continue;
        }
        if (json[pos] == '"') break;
        pos += 1;
    }
    if (pos >= json.len) return null;
    return json[start..pos];
}

/// Unescape a JSON string (handle \n, \t, \", \\, \uXXXX)
pub fn jsonUnescape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '\\') {
            switch (input[i + 1]) {
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                '"' => {
                    try result.append(allocator, '"');
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                '/' => {
                    try result.append(allocator, '/');
                    i += 2;
                },
                'u' => {
                    // \uXXXX — emit proper UTF-8
                    if (i + 5 < input.len) {
                        const hex = input[i + 2 .. i + 6];
                        const code = std.fmt.parseInt(u16, hex, 16) catch {
                            try result.append(allocator, '?');
                            i += 6;
                            continue;
                        };
                        if (code < 0x80) {
                            try result.append(allocator, @intCast(code));
                        } else if (code < 0x800) {
                            // 2-byte UTF-8
                            try result.append(allocator, @intCast(0xC0 | (code >> 6)));
                            try result.append(allocator, @intCast(0x80 | (code & 0x3F)));
                        } else {
                            // 3-byte UTF-8
                            try result.append(allocator, @intCast(0xE0 | (code >> 12)));
                            try result.append(allocator, @intCast(0x80 | ((code >> 6) & 0x3F)));
                            try result.append(allocator, @intCast(0x80 | (code & 0x3F)));
                        }
                        i += 6;
                    } else {
                        try result.append(allocator, input[i]);
                        i += 1;
                    }
                },
                else => {
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}
