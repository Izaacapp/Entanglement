pub const Theme = struct {
    name: []const u8,
    border: []const u8,
    user_label: []const u8,
    assistant_label: []const u8,
    system_label: []const u8,
    prompt_style: []const u8,
    status_bg: []const u8,
};

const themes = [_]Theme{
    .{
        .name = "catppuccin",
        .border = "38;5;240",
        .user_label = "1;38;5;183",
        .assistant_label = "1;38;5;156",
        .system_label = "1;38;5;180",
        .prompt_style = "1;38;5;117",
        .status_bg = "48;5;236;38;5;252",
    },
    .{
        .name = "gruvbox",
        .border = "38;5;241",
        .user_label = "1;38;5;214",
        .assistant_label = "1;38;5;142",
        .system_label = "1;38;5;208",
        .prompt_style = "1;38;5;109",
        .status_bg = "48;5;237;38;5;223",
    },
    .{
        .name = "tokyo_night",
        .border = "38;5;237",
        .user_label = "1;38;5;111",
        .assistant_label = "1;38;5;114",
        .system_label = "1;38;5;179",
        .prompt_style = "1;38;5;147",
        .status_bg = "48;5;234;38;5;189",
    },
    .{
        .name = "dracula",
        .border = "38;5;61",
        .user_label = "1;38;5;141",
        .assistant_label = "1;38;5;84",
        .system_label = "1;38;5;215",
        .prompt_style = "1;38;5;212",
        .status_bg = "48;5;236;38;5;253",
    },
    .{
        .name = "monokai",
        .border = "38;5;59",
        .user_label = "1;38;5;81",
        .assistant_label = "1;38;5;148",
        .system_label = "1;38;5;186",
        .prompt_style = "1;38;5;197",
        .status_bg = "48;5;235;38;5;231",
    },
    .{
        .name = "onedark",
        .border = "38;5;59",
        .user_label = "1;38;5;39",
        .assistant_label = "1;38;5;114",
        .system_label = "1;38;5;180",
        .prompt_style = "1;38;5;170",
        .status_bg = "48;5;235;38;5;145",
    },
    .{
        .name = "flexoki",
        .border = "38;5;242",
        .user_label = "1;38;5;67",
        .assistant_label = "1;38;5;71",
        .system_label = "1;38;5;172",
        .prompt_style = "1;38;5;96",
        .status_bg = "48;5;234;38;5;187",
    },
    .{
        .name = "tron",
        .border = "38;5;37",
        .user_label = "1;38;5;51",
        .assistant_label = "1;38;5;46",
        .system_label = "1;38;5;208",
        .prompt_style = "1;38;5;45",
        .status_bg = "48;5;16;38;5;51",
    },
};

var current_index: usize = 0;

pub fn current() Theme {
    return themes[current_index];
}

pub fn cycleTheme() void {
    current_index = (current_index + 1) % themes.len;
}

pub fn currentName() []const u8 {
    return themes[current_index].name;
}

pub fn setThemeByName(name: []const u8) void {
    for (themes, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, name)) {
            current_index = i;
            return;
        }
    }
}

const std = @import("std");
