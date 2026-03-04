const std = @import("std");

/// Strip <think>...</think> blocks from DeepSeek R1 output
pub fn stripThinkBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "<think>")) {
            // Skip until </think>
            if (std.mem.indexOf(u8, input[i..], "</think>")) |end| {
                i += end + "</think>".len;
                // Skip leading newline after </think>
                if (i < input.len and input[i] == '\n') i += 1;
                continue;
            } else {
                break; // Still thinking, skip rest
            }
        }
        try result.append(allocator, input[i]);
        i += 1;
    }
    return try result.toOwnedSlice(allocator);
}

/// Render markdown-formatted text with ANSI escape codes
/// Supports: **bold**, *italic*, `inline code`, ```code blocks```, # headers
pub fn renderMarkdown(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    const w = result.writer(allocator);

    var in_code_block = false;
    var in_bold = false;
    var in_italic = false;
    var in_inline_code = false;

    var lines_iter = std.mem.splitScalar(u8, input, '\n');
    var first_line = true;

    while (lines_iter.next()) |line| {
        if (!first_line) try w.writeByte('\n');
        first_line = false;

        // Code block toggle
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```")) {
            if (in_code_block) {
                try w.writeAll("\x1b[0m"); // end code block
                try w.writeAll("\x1b[2m\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\x1b[0m"); // └───
                in_code_block = false;
            } else {
                in_code_block = true;
                // Show language tag with border
                const trimmed = std.mem.trimLeft(u8, line, " ");
                const lang = trimmed[3..];
                try w.writeAll("\x1b[2m\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"); // ┌───
                if (lang.len > 0) {
                    try w.writeByte(' ');
                    try w.writeAll(lang);
                    try w.writeByte(' ');
                }
                try w.writeAll("\x1b[0m");
                try w.writeAll("\x1b[2m"); // dim for code
            }
            continue;
        }

        if (in_code_block) {
            try w.writeAll("\xe2\x94\x82 "); // │ (with space)
            // Basic syntax highlighting for common tokens
            try highlightCodeLine(w, line);
            continue;
        }

        // Headers
        if (line.len > 0 and line[0] == '#') {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            if (level <= 3 and level < line.len and line[level] == ' ') {
                try w.writeAll("\x1b[1;38;5;117m"); // bold blue
                try w.writeAll(line[level + 1 ..]);
                try w.writeAll("\x1b[0m");
                continue;
            }
        }

        // Inline formatting
        var i: usize = 0;
        while (i < line.len) {
            // Backtick — inline code
            if (line[i] == '`') {
                if (in_inline_code) {
                    try w.writeAll("\x1b[0m");
                    in_inline_code = false;
                } else {
                    try w.writeAll("\x1b[7m"); // reverse video
                    in_inline_code = true;
                }
                i += 1;
                continue;
            }

            if (in_inline_code) {
                try w.writeByte(line[i]);
                i += 1;
                continue;
            }

            // Bold: **
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
                if (in_bold) {
                    try w.writeAll("\x1b[22m"); // unbold
                    in_bold = false;
                } else {
                    try w.writeAll("\x1b[1m"); // bold
                    in_bold = true;
                }
                i += 2;
                continue;
            }

            // Italic: *
            if (line[i] == '*') {
                if (in_italic) {
                    try w.writeAll("\x1b[23m"); // un-italic
                    in_italic = false;
                } else {
                    try w.writeAll("\x1b[3m"); // italic
                    in_italic = true;
                }
                i += 1;
                continue;
            }

            try w.writeByte(line[i]);
            i += 1;
        }

        // Reset inline styles at end of each line to prevent leaking
        if (in_inline_code) {
            try w.writeAll("\x1b[0m");
            in_inline_code = false;
        }
        if (in_bold) {
            try w.writeAll("\x1b[22m");
            in_bold = false;
        }
        if (in_italic) {
            try w.writeAll("\x1b[23m");
            in_italic = false;
        }
    }

    // Reset any lingering styles
    if (in_bold or in_italic or in_inline_code or in_code_block) {
        try w.writeAll("\x1b[0m");
    }

    return try result.toOwnedSlice(allocator);
}

/// Extract code blocks (content between ``` delimiters) from markdown text
pub fn extractCodeBlocks(allocator: std.mem.Allocator, input: []const u8) ![][]u8 {
    var blocks: std.ArrayList([]u8) = .empty;
    defer blocks.deinit(allocator);

    var in_block = false;
    var block_start: usize = 0;
    var lines_iter = std.mem.splitScalar(u8, input, '\n');
    var pos: usize = 0;

    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_block) {
                // End of block — extract content
                if (pos > block_start) {
                    const block_content = try allocator.dupe(u8, input[block_start .. pos - 1]); // -1 for trailing \n
                    try blocks.append(allocator, block_content);
                }
                in_block = false;
            } else {
                // Start of block — next line is content start
                in_block = true;
                block_start = pos + line.len + 1; // +1 for \n
            }
        }
        pos += line.len + 1; // +1 for \n delimiter
    }

    return try blocks.toOwnedSlice(allocator);
}

/// Basic code block detection for syntax highlighting
pub fn isCodeBlock(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```");
}

const keywords = [_][]const u8{
    "fn",       "const",    "var",      "if",       "else",
    "while",    "for",      "return",   "try",      "catch",
    "switch",   "break",    "continue", "defer",    "pub",
    "struct",   "enum",     "union",    "error",    "import",
    "function", "let",      "class",    "async",    "await",
    "def",      "self",     "None",     "True",     "False",
    "int",      "bool",     "void",     "u8",       "usize",
    "true",     "false",    "null",     "undefined", "type",
};

fn isKeywordAt(line: []const u8, pos: usize, kw: []const u8) bool {
    if (pos + kw.len > line.len) return false;
    if (!std.mem.eql(u8, line[pos .. pos + kw.len], kw)) return false;
    // Check word boundary before
    if (pos > 0 and isIdentChar(line[pos - 1])) return false;
    // Check word boundary after
    if (pos + kw.len < line.len and isIdentChar(line[pos + kw.len])) return false;
    return true;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn highlightCodeLine(w: anytype, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        // String literals
        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            try w.writeAll("\x1b[38;5;179m"); // yellow for strings
            try w.writeByte(line[i]);
            i += 1;
            while (i < line.len) {
                try w.writeByte(line[i]);
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    try w.writeByte(line[i]);
                } else if (line[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try w.writeAll("\x1b[2m"); // back to dim
            continue;
        }

        // Comments (// and #)
        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
            try w.writeAll("\x1b[38;5;242m"); // gray for comments
            try w.writeAll(line[i..]);
            try w.writeAll("\x1b[2m");
            return;
        }
        if (line[i] == '#' and (i == 0 or line[i - 1] == ' ')) {
            // Could be comment or header — treat as comment in code blocks
            try w.writeAll("\x1b[38;5;242m");
            try w.writeAll(line[i..]);
            try w.writeAll("\x1b[2m");
            return;
        }

        // Numbers
        if (line[i] >= '0' and line[i] <= '9' and (i == 0 or !isIdentChar(line[i - 1]))) {
            try w.writeAll("\x1b[38;5;141m"); // purple for numbers
            while (i < line.len and ((line[i] >= '0' and line[i] <= '9') or line[i] == '.' or line[i] == 'x' or line[i] == 'b')) {
                try w.writeByte(line[i]);
                i += 1;
            }
            try w.writeAll("\x1b[2m");
            continue;
        }

        // Keywords
        var found_kw = false;
        for (keywords) |kw| {
            if (isKeywordAt(line, i, kw)) {
                try w.writeAll("\x1b[38;5;81m"); // blue for keywords
                try w.writeAll(kw);
                try w.writeAll("\x1b[2m");
                i += kw.len;
                found_kw = true;
                break;
            }
        }
        if (found_kw) continue;

        try w.writeByte(line[i]);
        i += 1;
    }
}
