const std = @import("std");

pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

pub fn getTermSize(fd: std.posix.fd_t) !TermSize {
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc != 0) {
        return TermSize{ .rows = 24, .cols = 80 };
    }
    return TermSize{ .rows = wsz.row, .cols = wsz.col };
}

pub fn renderHLine(writer: anytype, width: u16, color: []const u8) !void {
    try writer.print("\x1b[{s}m", .{color});
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        try writer.writeAll("─");
    }
    try writer.writeAll("\x1b[0m\x1b[K\r\n");
}

