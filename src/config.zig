const std = @import("std");
const theme = @import("theme.zig");

pub const Config = struct {
    endpoint: []const u8,
    model: []const u8,
    host: []const u8,
    api_key: ?[]const u8,
    system_prompt: ?[]const u8 = null,
    context_limit: u32 = 32768,
    models: ?[]const []const u8 = null, // favorite models for quick switching
    owns_strings: bool = false,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: Config) void {
        if (self.owns_strings) {
            if (self.allocator) |a| {
                a.free(self.endpoint);
                a.free(self.model);
                a.free(self.host);
                if (self.api_key) |k| a.free(k);
                if (self.system_prompt) |sp| a.free(sp);
                if (self.models) |ms| {
                    for (ms) |m| a.free(m);
                    a.free(ms);
                }
            }
        }
    }
};

// Generic defaults — override via .env, env vars, or ~/.config/sniper/config.json
const default_endpoint = "http://localhost:11434/v1";
const default_model = "deepseek-r1:8b";
const default_host = "localhost";

pub fn load(allocator: std.mem.Allocator) !Config {
    // Load .env file if present (populates env_map)
    var env_map = loadDotEnv(allocator);
    defer {
        if (env_map) |*m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            m.deinit();
        }
    }

    // Try config file first
    if (loadConfigFile(allocator, env_map)) |cfg| {
        return cfg;
    } else |_| {}

    // Fall back to env vars / .env / defaults
    const endpoint = getEnvOrDotEnv("SNIPER_ENDPOINT", env_map) orelse
        getEnvOrDotEnv("OLLAMA_HOST", env_map) orelse
        default_endpoint;

    // OLLAMA_HOST from .env may not have /v1 suffix — add it
    var endpoint_fixed_buf: [512]u8 = undefined;
    const final_endpoint = fixEndpoint(endpoint, &endpoint_fixed_buf);

    const model = getEnvOrDotEnv("SNIPER_MODEL", env_map) orelse
        getEnvOrDotEnv("OLLAMA_MODEL", env_map) orelse
        default_model;
    const host = getEnvOrDotEnv("SSH_HOST", env_map) orelse default_host;
    const api_key = getEnvOrDotEnv("SNIPER_API_KEY", env_map);

    return Config{
        .endpoint = final_endpoint,
        .model = model,
        .host = host,
        .api_key = api_key,
    };
}

fn fixEndpoint(endpoint: []const u8, buf: *[512]u8) []const u8 {
    // If endpoint doesn't end with /v1, append it
    if (!std.mem.endsWith(u8, endpoint, "/v1")) {
        const trimmed = std.mem.trimRight(u8, endpoint, "/");
        return std.fmt.bufPrint(buf, "{s}/v1", .{trimmed}) catch endpoint;
    }
    return endpoint;
}

fn getEnvOrDotEnv(key: []const u8, env_map: ?std.StringHashMap([]const u8)) ?[]const u8 {
    // System env vars take priority
    if (std.posix.getenv(key)) |v| return v;
    // Then .env file
    if (env_map) |m| {
        if (m.get(key)) |v| return v;
    }
    return null;
}

fn loadConfigFile(allocator: std.mem.Allocator, env_map: ?std.StringHashMap([]const u8)) !Config {
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

    const raw_endpoint = v.endpoint orelse getEnvOrDotEnv("SNIPER_ENDPOINT", env_map) orelse getEnvOrDotEnv("OLLAMA_HOST", env_map) orelse default_endpoint;
    var ep_buf: [512]u8 = undefined;
    const fixed_ep = fixEndpoint(raw_endpoint, &ep_buf);

    // Parse models array
    var models_owned: ?[]const []const u8 = null;
    if (v.models) |ms| {
        var model_list: std.ArrayList([]const u8) = .empty;
        for (ms) |m| {
            const duped = allocator.dupe(u8, m) catch continue;
            model_list.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
        if (model_list.items.len > 0) {
            models_owned = model_list.toOwnedSlice(allocator) catch null;
        } else {
            model_list.deinit(allocator);
        }
    }

    return Config{
        .endpoint = try allocator.dupe(u8, fixed_ep),
        .model = try allocator.dupe(u8, v.model orelse getEnvOrDotEnv("SNIPER_MODEL", env_map) orelse getEnvOrDotEnv("OLLAMA_MODEL", env_map) orelse default_model),
        .host = try allocator.dupe(u8, v.host orelse getEnvOrDotEnv("SSH_HOST", env_map) orelse default_host),
        .api_key = if (v.api_key) |k| try allocator.dupe(u8, k) else if (getEnvOrDotEnv("SNIPER_API_KEY", env_map)) |k| try allocator.dupe(u8, k) else null,
        .system_prompt = if (v.system_prompt) |sp| try allocator.dupe(u8, sp) else null,
        .context_limit = v.context_limit orelse 32768,
        .models = models_owned,
        .owns_strings = true,
        .allocator = allocator,
    };
}

/// Parse a .env file from the current directory. Returns null if not found.
fn loadDotEnv(allocator: std.mem.Allocator) ?std.StringHashMap([]const u8) {
    const content = std.fs.cwd().readFileAlloc(allocator, ".env", 64 * 1024) catch return null;
    defer allocator.free(content);

    var map = std.StringHashMap([]const u8).init(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            if (key.len == 0) continue;

            const key_owned = allocator.dupe(u8, key) catch continue;
            const val_owned = allocator.dupe(u8, val) catch {
                allocator.free(key_owned);
                continue;
            };
            map.put(key_owned, val_owned) catch {
                allocator.free(key_owned);
                allocator.free(val_owned);
                continue;
            };
        }
    }

    return map;
}

const ConfigJson = struct {
    endpoint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    host: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    context_limit: ?u32 = null,
    models: ?[]const []const u8 = null,
};
