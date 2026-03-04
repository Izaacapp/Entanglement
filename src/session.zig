const std = @import("std");
const chat = @import("chat.zig");
const http = @import("http.zig");

pub const Session = struct {
    id: []const u8,
    title: []const u8,
    messages: []const chat.Message,
};

const SessionJson = struct {
    id: []const u8,
    title: []const u8,
    messages: []const MessageJson,
};

const MessageJson = struct {
    role: []const u8,
    content: []const u8,
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    current_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) !SessionManager {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        const dir = try std.fmt.allocPrint(allocator, "{s}/.config/sniper/sessions", .{home});

        // Ensure directory tree exists (~/.config/sniper/sessions)
        const dirs = [_][]const u8{
            try std.fmt.allocPrint(allocator, "{s}/.config", .{home}),
            try std.fmt.allocPrint(allocator, "{s}/.config/sniper", .{home}),
        };
        defer for (dirs) |d| allocator.free(d);

        for (dirs) |d| {
            std.fs.makeDirAbsolute(d) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .allocator = allocator,
            .session_dir = dir,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        if (self.current_id) |id| self.allocator.free(id);
        self.allocator.free(self.session_dir);
    }

    pub fn newSession(self: *SessionManager) !void {
        if (self.current_id) |id| self.allocator.free(id);
        // Generate timestamp-based ID
        const ts = std.time.timestamp();
        const epoch_secs: u64 = @intCast(ts);
        self.current_id = try std.fmt.allocPrint(self.allocator, "{d}", .{epoch_secs});
    }

    pub fn save(self: *SessionManager, chat_view: *chat.ChatView) !void {
        if (chat_view.messages.items.len == 0) return;

        if (self.current_id == null) {
            try self.newSession();
        }

        const id = self.current_id.?;
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.session_dir, id });
        defer self.allocator.free(path);

        // Build title from first user message
        var title: []const u8 = "untitled";
        for (chat_view.messages.items) |msg| {
            if (msg.role == .user) {
                title = if (msg.content.len > 50) msg.content[0..50] else msg.content;
                break;
            }
        }

        // Build JSON in memory then write all at once
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        const w = json_buf.writer(self.allocator);

        try w.writeAll("{\"id\":\"");
        try writeJsonStr(w, id);
        try w.writeAll("\",\"title\":\"");
        try writeJsonStr(w, title);
        try w.writeAll("\",\"messages\":[");

        var first = true;
        for (chat_view.messages.items) |msg| {
            // Skip tool messages and assistant tool-call-only messages
            if (msg.role == .tool) continue;
            if (msg.role == .assistant and msg.content.len == 0 and msg.tool_calls_json != null) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"role\":\"");
            try w.writeAll(@tagName(msg.role));
            try w.writeAll("\",\"content\":\"");
            try writeJsonStr(w, msg.content);
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json_buf.items);

        // Save as last session
        const last_path = try std.fmt.allocPrint(self.allocator, "{s}/../last_session", .{self.session_dir});
        defer self.allocator.free(last_path);
        const last_file = std.fs.createFileAbsolute(last_path, .{}) catch return;
        defer last_file.close();
        last_file.writeAll(id) catch {};
    }

    pub fn loadLast(self: *SessionManager, chat_view: *chat.ChatView) !void {
        const last_path = try std.fmt.allocPrint(self.allocator, "{s}/../last_session", .{self.session_dir});
        defer self.allocator.free(last_path);

        const last_file = std.fs.openFileAbsolute(last_path, .{}) catch return;
        defer last_file.close();

        const id_data = last_file.readToEndAlloc(self.allocator, 256) catch return;
        defer self.allocator.free(id_data);
        const n = id_data.len;
        if (n == 0) return;

        try self.loadSession(id_data, chat_view);
    }

    pub fn loadSession(self: *SessionManager, id: []const u8, chat_view: *chat.ChatView) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.session_dir, id });
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(SessionJson, self.allocator, data, .{ .allocate = .alloc_always }) catch return;
        defer parsed.deinit();

        // Clear existing messages
        for (chat_view.messages.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |tcid| self.allocator.free(tcid);
            if (msg.tool_calls_json) |j| self.allocator.free(j);
            if (msg.tool_name) |tn| self.allocator.free(tn);
            if (msg.cached_render) |cr| self.allocator.free(cr);
        }
        chat_view.messages.clearRetainingCapacity();

        // Load messages
        for (parsed.value.messages) |msg| {
            const role: chat.Role = if (std.mem.eql(u8, msg.role, "user"))
                .user
            else if (std.mem.eql(u8, msg.role, "assistant"))
                .assistant
            else
                .system;

            const content = try self.allocator.dupe(u8, msg.content);
            try chat_view.messages.append(self.allocator, .{ .role = role, .content = content });
        }

        // Set current session ID
        if (self.current_id) |old| self.allocator.free(old);
        self.current_id = try self.allocator.dupe(u8, id);
    }

    pub fn listSessions(self: *SessionManager) ![]SessionInfo {
        var list: std.ArrayList(SessionInfo) = .empty;
        defer list.deinit(self.allocator); // caller owns returned slice

        var dir = std.fs.openDirAbsolute(self.session_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const id = entry.name[0 .. entry.name.len - 5]; // strip .json
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.session_dir, entry.name });
            defer self.allocator.free(path);

            const file = std.fs.openFileAbsolute(path, .{}) catch continue;
            defer file.close();

            const data = file.readToEndAlloc(self.allocator, 64 * 1024) catch continue;
            defer self.allocator.free(data);

            const parsed = std.json.parseFromSlice(SessionJson, self.allocator, data, .{ .allocate = .alloc_always }) catch continue;
            defer parsed.deinit();

            try list.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .title = try self.allocator.dupe(u8, parsed.value.title),
            });
        }

        return try list.toOwnedSlice(self.allocator);
    }
};

pub const SessionInfo = struct {
    id: []const u8,
    title: []const u8,
};

const writeJsonStr = http.writeJsonStr;
