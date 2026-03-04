const std = @import("std");
const chat = @import("chat.zig");
const editor = @import("editor.zig");
const markdown = @import("markdown.zig");
const tools = @import("tools.zig");
const theme = @import("theme.zig");
const config = @import("config.zig");
const session = @import("session.zig");

test "ChatView: add and retrieve messages" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    try cv.addUserMessage("hello");
    try cv.addSystemMessage("system msg");
    try cv.appendAssistantChunk("world");

    const msgs = cv.getMessages();
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqualStrings("hello", msgs[0].content);
    try std.testing.expectEqual(chat.Role.user, msgs[0].role);
    try std.testing.expectEqualStrings("system msg", msgs[1].content);
    try std.testing.expectEqual(chat.Role.system, msgs[1].role);
    try std.testing.expectEqualStrings("world", msgs[2].content);
    try std.testing.expectEqual(chat.Role.assistant, msgs[2].role);
}

test "ChatView: append chunks to same assistant message" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    try cv.appendAssistantChunk("hello ");
    try cv.appendAssistantChunk("world");

    const msgs = cv.getMessages();
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("hello world", msgs[0].content);
}

test "ChatView: tool messages" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    try cv.addToolResult("call_123", "bash", "output here");
    const msgs = cv.getMessages();
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqual(chat.Role.tool, msgs[0].role);
    try std.testing.expectEqualStrings("call_123", msgs[0].tool_call_id.?);
    try std.testing.expectEqualStrings("bash", msgs[0].tool_name.?);
    try std.testing.expectEqualStrings("output here", msgs[0].content);
}

test "ChatView: assistant tool call message" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    try cv.addAssistantToolCallMessage("[{\"id\":\"1\"}]");
    const msgs = cv.getMessages();
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("", msgs[0].content);
    try std.testing.expect(msgs[0].tool_calls_json != null);
}

test "ChatView: scroll operations" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    try std.testing.expectEqual(@as(usize, 0), cv.scroll_offset);
    cv.scrollUp(5);
    try std.testing.expectEqual(@as(usize, 5), cv.scroll_offset);
    cv.scrollDown(3);
    try std.testing.expectEqual(@as(usize, 2), cv.scroll_offset);
    cv.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), cv.scroll_offset);
}

test "ChatView: render empty" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try cv.render(w, 80, 24, theme.current(), null);
    // Should contain welcome text
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "sniper") != null);
}

test "ChatView: render with messages" {
    const allocator = std.testing.allocator;
    var cv = chat.ChatView.init(allocator);
    defer cv.deinit();

    try cv.addUserMessage("test message");
    try cv.appendAssistantChunk("response");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try cv.render(w, 80, 24, theme.current(), null);
    try std.testing.expect(buf.items.len > 0);
}

test "Editor: basic input" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("h");
    try ed.handleInput("i");
    try std.testing.expectEqualStrings("hi", ed.getText());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "Editor: backspace" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("a");
    try ed.handleInput("b");
    try ed.handleInput(&[_]u8{127}); // backspace
    try std.testing.expectEqualStrings("a", ed.getText());
}

test "Editor: Ctrl+A and Ctrl+E" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("h");
    try ed.handleInput("e");
    try ed.handleInput("l");
    try ed.handleInput("l");
    try ed.handleInput("o");

    // Ctrl+A - cursor to start
    try ed.handleInput(&[_]u8{0x01});
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);

    // Ctrl+E - cursor to end
    try ed.handleInput(&[_]u8{0x05});
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);
}

test "Editor: Ctrl+U clear before cursor" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("a");
    try ed.handleInput("b");
    try ed.handleInput("c");
    // Move cursor left
    try ed.handleInput(&[_]u8{ 27, '[', 'D' });
    // Ctrl+U - clear before cursor
    try ed.handleInput(&[_]u8{0x15});
    try std.testing.expectEqualStrings("c", ed.getText());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "Editor: Ctrl+K clear after cursor" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("a");
    try ed.handleInput("b");
    try ed.handleInput("c");
    // Ctrl+A to start
    try ed.handleInput(&[_]u8{0x01});
    // Move right once
    try ed.handleInput(&[_]u8{ 27, '[', 'C' });
    // Ctrl+K - clear after cursor
    try ed.handleInput(&[_]u8{0x0B});
    try std.testing.expectEqualStrings("a", ed.getText());
}

test "Editor: Ctrl+W delete word backward" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    for ("hello world") |c| {
        try ed.handleInput(&[_]u8{c});
    }
    // Ctrl+W
    try ed.handleInput(&[_]u8{0x17});
    try std.testing.expectEqualStrings("hello ", ed.getText());
}

test "Editor: newline and multi-line" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("a");
    try ed.insertNewline();
    try ed.handleInput("b");
    try std.testing.expectEqualStrings("a\nb", ed.getText());
    try std.testing.expectEqual(@as(u16, 2), ed.getHeight());
}

test "Editor: delete at cursor" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("a");
    try ed.handleInput("b");
    try ed.handleInput(&[_]u8{0x01}); // Ctrl+A
    ed.deleteAtCursor();
    try std.testing.expectEqualStrings("b", ed.getText());
}

test "Editor: clear" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("h");
    try ed.handleInput("i");
    ed.clear();
    try std.testing.expectEqualStrings("", ed.getText());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "Editor: arrow keys navigation" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("a");
    try ed.handleInput("b");
    try ed.handleInput("c");

    // Left arrow
    try ed.handleInput(&[_]u8{ 27, '[', 'D' });
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    // Right arrow
    try ed.handleInput(&[_]u8{ 27, '[', 'C' });
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);

    // Left arrow at start - shouldn't go below 0
    try ed.handleInput(&[_]u8{0x01}); // Ctrl+A
    try ed.handleInput(&[_]u8{ 27, '[', 'D' });
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "Editor: render" {
    const allocator = std.testing.allocator;
    var ed = editor.Editor.init(allocator);
    defer ed.deinit();

    try ed.handleInput("h");
    try ed.handleInput("i");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try ed.render(w, 80, 1, theme.current());
    try std.testing.expect(buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "hi") != null);
}

test "Markdown: stripThinkBlocks" {
    const allocator = std.testing.allocator;
    const input = "before<think>thinking stuff</think>after";
    const result = try markdown.stripThinkBlocks(allocator, input);
    defer allocator.free(result);
    // Completed think blocks show a collapsed summary instead of being stripped
    try std.testing.expect(std.mem.indexOf(u8, result, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "thinking (") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "after") != null);
}

test "Markdown: stripThinkBlocks empty" {
    const allocator = std.testing.allocator;
    const result = try markdown.stripThinkBlocks(allocator, "no think blocks here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no think blocks here", result);
}

test "Markdown: stripThinkBlocks unclosed" {
    const allocator = std.testing.allocator;
    const result = try markdown.stripThinkBlocks(allocator, "before<think>still thinking...");
    defer allocator.free(result);
    // Unclosed think blocks show live thinking indicator
    try std.testing.expect(std.mem.indexOf(u8, result, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "thinking:") != null);
}

test "Markdown: renderMarkdown bold" {
    const allocator = std.testing.allocator;
    const result = try markdown.renderMarkdown(allocator, "this is **bold** text");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bold") != null);
}

test "Markdown: renderMarkdown code block" {
    const allocator = std.testing.allocator;
    const input = "```python\nprint('hello')\n```";
    const result = try markdown.renderMarkdown(allocator, input);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "python") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "print") != null);
}

test "Markdown: renderMarkdown header" {
    const allocator = std.testing.allocator;
    const result = try markdown.renderMarkdown(allocator, "# Hello");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1;38;5;117m") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

test "Markdown: renderMarkdown inline code" {
    const allocator = std.testing.allocator;
    const result = try markdown.renderMarkdown(allocator, "use `code` here");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "code") != null);
}

test "Markdown: isCodeBlock" {
    try std.testing.expect(markdown.isCodeBlock("```python"));
    try std.testing.expect(markdown.isCodeBlock("  ```"));
    try std.testing.expect(!markdown.isCodeBlock("normal text"));
}

test "Tools: extractJsonString" {
    const json = "{\"name\":\"hello\",\"value\":\"world\"}";
    const name = tools.extractJsonString(json, "name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("hello", name.?);

    const val = tools.extractJsonString(json, "value");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("world", val.?);

    const missing = tools.extractJsonString(json, "missing");
    try std.testing.expect(missing == null);
}

test "Tools: extractJsonString with escapes" {
    const json = "{\"path\":\"hello\\nworld\"}";
    const path = tools.extractJsonString(json, "path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("hello\\nworld", path.?);
}

test "Tools: jsonUnescape basic" {
    const allocator = std.testing.allocator;
    const result = try tools.jsonUnescape(allocator, "hello\\nworld");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld", result);
}

test "Tools: jsonUnescape all escapes" {
    const allocator = std.testing.allocator;
    const result = try tools.jsonUnescape(allocator, "a\\tb\\nc\\\"d\\\\e\\/f");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\tb\nc\"d\\e/f", result);
}

test "Tools: jsonUnescape unicode" {
    const allocator = std.testing.allocator;
    const result = try tools.jsonUnescape(allocator, "\\u0041\\u0042");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AB", result);
}

test "Tools: executeTool unknown" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "nonexistent",
        .arguments_json = "{}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Unknown tool", result.content);
}

test "Tools: executeTool bash echo" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "bash",
        .arguments_json = "{\"command\":\"echo hello\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "hello"));
}

test "Tools: executeTool bash exit code" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "bash",
        .arguments_json = "{\"command\":\"exit 42\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "42") != null);
}

test "Tools: executeTool read_file" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "read_file",
        .arguments_json = "{\"path\":\"build.zig\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
}

test "Tools: executeTool read_file missing" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "read_file",
        .arguments_json = "{\"path\":\"nonexistent_file_xyz.txt\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "Tools: executeTool write and read file" {
    const allocator = std.testing.allocator;

    // Write
    const write_tc = tools.ToolCall{
        .id = "1",
        .function_name = "write_file",
        .arguments_json = "{\"path\":\"/tmp/sniper_test_file.txt\",\"content\":\"test content 123\"}",
    };
    const write_result = try tools.executeTool(allocator, write_tc, null);
    defer allocator.free(write_result.content);
    try std.testing.expect(!write_result.is_error);

    // Read back
    const read_tc = tools.ToolCall{
        .id = "2",
        .function_name = "read_file",
        .arguments_json = "{\"path\":\"/tmp/sniper_test_file.txt\"}",
    };
    const read_result = try tools.executeTool(allocator, read_tc, null);
    defer allocator.free(read_result.content);
    try std.testing.expect(!read_result.is_error);
    try std.testing.expectEqualStrings("test content 123", read_result.content);

    // Cleanup
    std.fs.deleteFileAbsolute("/tmp/sniper_test_file.txt") catch {};
}

test "Tools: executeTool edit_file" {
    const allocator = std.testing.allocator;

    // Create file first
    const file = try std.fs.cwd().createFile("/tmp/sniper_test_edit.txt", .{});
    try file.writeAll("hello world foo bar");
    file.close();

    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "edit_file",
        .arguments_json = "{\"path\":\"/tmp/sniper_test_edit.txt\",\"old_string\":\"foo\",\"new_string\":\"baz\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);

    // Verify
    const content = try std.fs.cwd().readFileAlloc(allocator, "/tmp/sniper_test_edit.txt", 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello world baz bar", content);

    std.fs.deleteFileAbsolute("/tmp/sniper_test_edit.txt") catch {};
}

test "Tools: executeTool glob" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "glob",
        .arguments_json = "{\"pattern\":\"src/*.zig\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
}

test "Tools: executeTool grep" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "grep",
        .arguments_json = "{\"pattern\":\"pub fn main\",\"path\":\"src/main.zig\"}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "main") != null);
}

test "Tools: executeTool bash missing command" {
    const allocator = std.testing.allocator;
    const tc = tools.ToolCall{
        .id = "1",
        .function_name = "bash",
        .arguments_json = "{}",
    };
    const result = try tools.executeTool(allocator, tc, null);
    defer allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "Theme: cycle and current" {
    const initial = theme.currentName();
    try std.testing.expectEqualStrings("catppuccin", initial);

    theme.cycleTheme();
    try std.testing.expectEqualStrings("gruvbox", theme.currentName());

    theme.cycleTheme();
    try std.testing.expectEqualStrings("tokyo_night", theme.currentName());

    // Reset back
    theme.setThemeByName("catppuccin");
    try std.testing.expectEqualStrings("catppuccin", theme.currentName());
}

test "Theme: setThemeByName" {
    theme.setThemeByName("dracula");
    try std.testing.expectEqualStrings("dracula", theme.currentName());

    theme.setThemeByName("tron");
    try std.testing.expectEqualStrings("tron", theme.currentName());

    // Invalid name - should not change
    theme.setThemeByName("nonexistent");
    try std.testing.expectEqualStrings("tron", theme.currentName());

    // Reset
    theme.setThemeByName("catppuccin");
}

test "Theme: all themes have required fields" {
    const t = theme.current();
    try std.testing.expect(t.name.len > 0);
    try std.testing.expect(t.border.len > 0);
    try std.testing.expect(t.user_label.len > 0);
    try std.testing.expect(t.assistant_label.len > 0);
    try std.testing.expect(t.system_label.len > 0);
    try std.testing.expect(t.prompt_style.len > 0);
    try std.testing.expect(t.status_bg.len > 0);
}

test "HTTP: extractJsonInt with usage data" {
    const http_mod = @import("http.zig");
    // Simulate the SSE data line from Ollama with usage
    const data = "{\"id\":\"chatcmpl-214\",\"object\":\"chat.completion.chunk\",\"created\":1772606210,\"model\":\"deepseek-r1:8b\",\"system_fingerprint\":\"fp_ollama\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":217,\"total_tokens\":221}}";

    // Check that prompt_tokens is found
    try std.testing.expect(std.mem.indexOf(u8, data, "\"prompt_tokens\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"completion_tokens\":") != null);

    const p = http_mod.extractJsonInt(data, "prompt_tokens");
    const c = http_mod.extractJsonInt(data, "completion_tokens");
    try std.testing.expectEqual(@as(u32, 4), p);
    try std.testing.expectEqual(@as(u32, 217), c);
}

test "Config: load defaults" {
    const allocator = std.testing.allocator;
    const cfg = try config.load(allocator);
    defer cfg.deinit();

    try std.testing.expect(cfg.endpoint.len > 0);
    try std.testing.expect(cfg.model.len > 0);
}
