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

/// A collection of parsed command-line arguments.
pub const Arguments = struct {
    raw_args: [][:0]u8,
    short: std.StringHashMap(void),
    long: std.StringHashMap(void),
    string: std.StringHashMap(void),

    // Types

    const Self = @This();
    // TODO: Required arguments, better usage templates, etc.
    pub const Options = struct {
        /// The name of the program we are parsing for.
        name: []const u8,
        /// What to prefix short and long arguments (2x) with.
        prefix: u8 = '-',
        /// The usage template (using `std.fmt.format` syntax) to error with when no arguments are supplied.
        /// A newline is append to the end.
        ///
        /// Available variables:
        /// - `[app]` - The 0th argument passed in; the executable path.
        usage: []const u8 = "Usage: {[app]s} [options...]",
    };

    // Initialization

    /// Processes command-line arguments into `Argument`s (.Short, .Long, or .String) and panics on error.
    pub fn parseCommandLineArguments(allocator: std.mem.Allocator, comptime options: Options) Self {
        // Create the sets.
        var short = std.StringHashMap(void).init(allocator);
        var long = std.StringHashMap(void).init(allocator);
        var string = std.StringHashMap(void).init(allocator);

        // Loop through the raw arguments and parse them into Arguments.
        const args = std.process.argsAlloc(allocator) catch @panic("Failed to allocate space for the command-line arguments.");

        for (args, 0..) |arg, i| {
            // Handle cases with the 0th argument.
            if (i == 0) {
                if (i != args.len - 1) continue;

                // If no arguments were passed in then print usage.
                @panic(std.fmt.comptimePrint(options.usage ++ "\n", .{ .app = options.name }));
            }

            // Parse short and long arguments.
            {
                // If the argument starts with <.prefix> and is at least two characters.
                if (arg.len > 1 and arg[0] == options.prefix) {
                    // Two <.prefix> in a row is parsed as a long argument.
                    if (arg.len > 2 and arg[1] == options.prefix) {
                        long.put(arg[2..], {}) catch @panic("Failed to insert processed long argument.");
                        continue;
                    }
                    // Otherwise, if it is only a <.prefix> followed by any character, it's a short argument.
                    if (arg.len == 2) {
                        short.put(arg[1..2], {}) catch @panic("Failed to insert processed shprt argument.");
                        continue;
                    }
                }
                // Otherwise, when the argument doesn't start with a <.prefix> or is less than two characters, we interpret the argument as a string.
                string.put(arg, {}) catch @panic("Failed to insert processed string argument.");
            }
        }

        return .{
            .raw_args = args,
            .short = short,
            .long = long,
            .string = string,
        };
    }

    pub fn deinit(self: *@This()) void {
        std.process.argsFree(self.short.allocator, self.raw_args);
        self.short.deinit();
        self.long.deinit();
        self.string.deinit();
    }

    // Formatting

    pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Arguments:\n", .{});
        inline for (&.{ "short", "long", "string" }) |name| {
            const map: std.StringHashMap(void) = @field(value, name);
            try writer.print("\t{s}:\n", .{name});

            var iter = map.keyIterator();
            while (iter.next()) |arg| {
                try writer.print("\t\t{s}\n", .{arg.*});
            }
        }
    }
};

// Filesystem Utilities
