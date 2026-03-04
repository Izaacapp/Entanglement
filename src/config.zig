const std = @import("std");
const theme = @import("theme.zig");

pub const Config = struct {
    endpoint: []const u8,
    model: []const u8,
    host: []const u8,
    api_key: ?[]const u8,
    owns_strings: bool = false,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: Config) void {
        if (self.owns_strings) {
            if (self.allocator) |a| {
                a.free(self.endpoint);
                a.free(self.model);
                a.free(self.host);
                if (self.api_key) |k| a.free(k);
            }
        }
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    // Try config file first
    if (loadConfigFile(allocator)) |cfg| {
        return cfg;
    } else |_| {}

    // Fall back to env vars / defaults
    const endpoint = std.posix.getenv("SNIPER_ENDPOINT") orelse
        std.posix.getenv("OLLAMA_HOST") orelse
        "http://192.168.1.241:11434/v1";

    const model = std.posix.getenv("SNIPER_MODEL") orelse "deepseek-r1:8b";
    const host = std.posix.getenv("SSH_HOST") orelse "192.168.1.241";
    const api_key = std.posix.getenv("SNIPER_API_KEY");

    return Config{
        .endpoint = endpoint,
        .model = model,
        .host = host,
        .api_key = api_key,
    };
}

fn loadConfigFile(allocator: std.mem.Allocator) !Config {
    var path_buf: [512]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/sniper/config.json", .{home}) catch return error.PathTooLong;

    const file = std.fs.openFileAbsolute(path, .{}) catch return error.NoConfigFile;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 64 * 1024) catch return error.ReadFailed;
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(ConfigJson, allocator, data, .{ .allocate = .alloc_always }) catch return error.ParseFailed;
    defer parsed.deinit();

    const v = parsed.value;

    // Apply theme if specified
    if (v.theme) |t| {
        theme.setThemeByName(t);
    }

    return Config{
        .endpoint = try allocator.dupe(u8, v.endpoint orelse std.posix.getenv("SNIPER_ENDPOINT") orelse std.posix.getenv("OLLAMA_HOST") orelse "http://192.168.1.241:11434/v1"),
        .model = try allocator.dupe(u8, v.model orelse std.posix.getenv("SNIPER_MODEL") orelse "deepseek-r1:8b"),
        .host = try allocator.dupe(u8, v.host orelse std.posix.getenv("SSH_HOST") orelse "192.168.1.241"),
        .api_key = if (v.api_key) |k| try allocator.dupe(u8, k) else if (std.posix.getenv("SNIPER_API_KEY")) |k| try allocator.dupe(u8, k) else null,
        .owns_strings = true,
        .allocator = allocator,
    };
}

const ConfigJson = struct {
    endpoint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    host: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    theme: ?[]const u8 = null,
};
