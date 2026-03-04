const std = @import("std");
const config = @import("config.zig");
const tui = @import("tui.zig");
const http = @import("http.zig");
const chat = @import("chat.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try config.load(allocator);
    defer cfg.deinit();

    // Check for -p flag (non-interactive mode)
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var prompt: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "--prompt")) {
            if (i + 1 < args.len) {
                prompt = args[i + 1];
                i += 1;
            }
        }
    }

    if (prompt) |p| {
        // Non-interactive mode
        const messages = [_]chat.Message{
            .{ .role = .user, .content = p },
        };
        const response = http.chatOnce(allocator, cfg, &messages) catch |err| {
            const stderr_file = std.fs.File.stderr();
            stderr_file.writeAll("Error: ") catch {};
            stderr_file.writeAll(@errorName(err)) catch {};
            stderr_file.writeAll("\n") catch {};
            std.process.exit(1);
        };
        defer allocator.free(response);
        const stdout_file = std.fs.File.stdout();
        stdout_file.writeAll(response) catch {};
        stdout_file.writeAll("\n") catch {};
        return;
    }

    var app = tui.App.init(allocator, cfg) catch |err| {
        if (err == error.NotATerminal) {
            const stderr_file = std.fs.File.stderr();
            stderr_file.writeAll("Error: sniper requires a terminal. Use -p for non-interactive mode.\n") catch {};
            std.process.exit(1);
        }
        return err;
    };
    defer app.deinit();

    try app.run();
}
