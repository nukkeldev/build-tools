// Imports

const std = @import("std");

// Character Utilities

/// Returns whether the character is allowed to be in an NTFS filename.
pub fn isValidFilenameCharacter(character: u8) bool {
    // NTFS: https://en.wikipedia.org/wiki/Filename#Comparison_of_filename_limitations

    return !((character >= 0x01 and character <= 0x1F) or
        character == '"' or
        character == '*' or
        character == '/' or
        character == ':' or
        character == '<' or
        character == '>' or
        character == '?' or
        character == '\\' or
        character == '|');
}

// Command-Line Argument Parsing

/// A parsed command-line argument.
pub const Argument = union(enum) {
    Short: u8,
    Long: []const u8,
    String: []const u8,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .Short => |short| try writer.print("-{c}", .{short}),
            .Long => |long| try writer.print("--{s}", .{long}),
            .String => |string| _ = try writer.write(string),
        }
    }
};

// Parsed command-line arguments.

/// If one of the arguments is `<.special_prefix><.special_prefix>debug` or `<.special_prefix>d` then we write `true` to this variable.
/// If one of the arguments is `<.special_prefix><.special_prefix>!debug` or `<.special_prefix>!d` then we write `false` to this variable.
/// Multiple occurances are evaluated in the order passed in.
pub var DEBUG_ARGUMENTS = false;

// TODO: Required arguments, better usage templates, etc.
pub const ParseCommandLineArgumentsOptions = struct {
    /// The name of the program we are parsing for.
    name: []const u8,
    /// What to prefix short and long arguments (2x) with.
    prefix: u8 = '-',
    /// Special prefix for setting special arguments (i.e. `<.debug>`).
    special_prefix: u8 = ':',
    /// The usage template (using `std.fmt.format` syntax) to error with when no arguments are supplied.
    /// A newline is append to the end.
    ///
    /// Available variables:
    /// - `[app]` - The 0th argument passed in; the executable path.
    usage: []const u8 = "Usage: {[app]s} [options...]",
};

/// Processes command-line arguments into `Argument`s (.Short, .Long, or .String) and panics on error.
pub fn parseCommandLineArguments(allocator: std.mem.Allocator, comptime options: ParseCommandLineArgumentsOptions) std.ArrayList(Argument) {
    // Create a list to store the arguments.
    var arguments = std.ArrayList(Argument).initCapacity(allocator, 1) catch @panic("Failed to allocate ArrayList for arguments.");

    // Loop through the raw arguments and parse them into Arguments.
    const len = std.os.argv.len;
    for (std.os.argv, 0..) |arg, i| {
        // Handle cases with the 0th argument.
        if (i == 0) {
            if (i != len - 1) continue;

            // If no arguments were passed in then print usage.
            @panic(std.fmt.comptimePrint(options.usage ++ "\n", .{ .app = options.name }));
        }

        // Parse short and long arguments.
        arguments.append(b: {
            // If the argument starts with <.prefix> and is at least two characters.
            if (arg.len > 1 and arg[0] == options.prefix) {
                // Two <.prefix> in a row is parsed as a long argument.
                if (arg.len > 1 and arg[1] == options.prefix) {
                    break :b .{ .Long = arg[2..] };
                }
                // Otherwise, if it is only a <.prefix> followed by any character, it's a short argument.
                if (arg.len == 2) {
                    break :b .{ .Short = arg[1] };
                }
                // If all else fails, we interpret it as a string.
                break :b .{ .Long = arg };
            }
            // Else if the argument starts with a <.special_prefix>, then we process various special arguments.
            else if (arg.len > 1 and arg[0] == options.special_prefix) {
                if (arg.len < 2) break :b .{ .String = arg };

                // Two <.special_prefix> in a row is parsed as a long argument.
                if (arg[1] == options.special_prefix) {
                    // If the special argument starts with a '!', then we disable it; otherwise we enable it.
                    const write = arg[2] != '!';

                    if (std.mem.eql(u8, arg[(if (write) 3 else 2)..], "debug")) {
                        options.debug.* = write;
                    }

                    continue;
                }

                // Otherwise, if it is only a <.special_prefix> followed by any character, it's a short argument.
                // If the special argument starts with a '!', then we disable it; otherwise we enable it.
                const write = arg[1] != '!';
                if (write and arg.len > 3) break :b .{ .String = arg };
                if (!write and arg.len > 2) break :b .{ .String = arg };

                const arg_char = if (write) arg[1] else arg[2];
                if (arg_char == 'd') {
                    options.debug.* = write;
                }

                continue;
            }
            // Otherwise, when the argument doesn't start with a <.prefix> or is less than two characters, we interpret the argument as a string.
            else {
                break :b .{ .String = arg };
            }
        }) catch @panic("Failed to append parsed argument to list!");
    }

    return arguments;
}

// Filesystem Utilities
