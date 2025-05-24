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

/// Options for `ArgumentsFor`.
pub const ArgumentsForOptions = struct {
    /// A pointer to a struct that mirrors the field names in ArgumentsFor's struct
    /// being populated, in which the field types are `[][]const u8`'s that specify
    /// additional aliases for this property.
    aliases: type = struct {},
    /// Whether to emit debug logging when parsing arguments.
    debug: bool = false,
};

/// Create a parsing function that takes in a list of command-line arguments
/// for `struct`, which that populates an instance of struct according to the
/// names of it's fields, their types, and the aliases specified in `options`.
///
/// Returns a struct with a `parse` method that takes in an allocator and returns the `Input` type
/// (returning a generic error on usage failure, and panicking on other issues), and a `deinit` method that
/// takes in the same allocator and cleans up the `Input` instance.
pub fn ArgumentsFor(comptime Input: type, comptime options: ArgumentsForOptions) type {
    // Helper Functions
    const dbg = debugFn(options.debug, std.log.debug);

    // Fields
    const fields = @typeInfo(Input).@"struct".fields;

    // Return Type
    return struct {
        pub fn parse(allocator: std.mem.Allocator) !*Input {
            // Allocate an instance of our `input` type.
            const input = try allocator.create(Input);
            errdefer allocator.destroy(input);

            // Allocate and populate an array of our command-line arguments.
            var args = try std.process.argsWithAllocator(allocator);
            defer args.deinit();

            // Create an array to store what has been assigned.
            var assignments: [fields.len]bool = .{false} ** fields.len;

            // Possibly Positional Arguments™
            // TODO: Reduce size by pre-computing count of required arguments.
            var possibly_positional_arguments: [fields.len]?[]const u8 = .{null} ** fields.len;
            // Possibly Positional Arguments™ Index
            var ppa_index: usize = 0;
            errdefer for (possibly_positional_arguments) |@"ppa?"| if (@"ppa?") |ppa| allocator.free(ppa);

            // Loop through the arguments and their aliases.
            _ = args.next(); // Skip the executabe path.
            while (args.next()) |arg| {
                dbg("Parsing argument \"{s}\".", .{arg});

                // Check if it corresponds to any of this field.
                var exists = false;
                b: {
                    inline for (fields, 0..) |field, index| {
                        dbg("Checking against \"{s}\".", .{field.name});

                        exists = std.mem.eql(u8, field.name, arg);
                        if (exists) {
                            dbg("Property \"{s}\" found.", .{arg});
                        } else {
                            if (@hasDecl(options.aliases, field.name)) b2: {
                                inline for (@field(options.aliases, field.name)) |alias| {
                                    dbg("Checking against alias \"{s}\".", .{alias});

                                    if (std.mem.eql(u8, alias, arg)) {
                                        dbg("Property \"{s}\" found under the alias \"{s}\".", .{ arg, alias });
                                        exists = true;
                                        break :b2;
                                    }
                                }
                            }
                        }

                        // If the property does exist, then determine what type of property it is
                        // and set it accordingly.
                        if (exists) {
                            // TODO: Check if it has been assigned before.

                            // Flags for all supported variable types.
                            comptime var boolean = false;
                            comptime var string = false;
                            comptime var int = false;

                            comptime {
                                s: switch (@typeInfo(field.type)) {
                                    // If the field is nullable, then loop the child type.
                                    .optional => |o| continue :s @typeInfo(o.child),
                                    // Booleans: (?)bool
                                    .bool => boolean = true,
                                    // Strings: (?)[]const u8
                                    .pointer => |p| string = p.is_const and p.child == u8,
                                    // Integers: (?)any bitness / sign
                                    .int => int = true,
                                    // Otherwise, this field is not supported.
                                    else => @compileError(std.fmt.comptimePrint("Invalid Type \"{s}\" for Argument \"{s}\"", .{
                                        @typeName(field.type),
                                        field.name,
                                    })),
                                }
                            }

                            // TODO: Currently we don't have a way to enable/disable properties.
                            if (boolean) {
                                const fieldPtr: *bool = @ptrFromInt(@intFromPtr(input) + @offsetOf(Input, field.name));
                                fieldPtr.* = true;
                            }

                            if (string) {
                                const fieldPtr: *[]const u8 = @ptrFromInt(@intFromPtr(input) + @offsetOf(Input, field.name));
                                fieldPtr.* = try allocator.dupe(
                                    u8,
                                    args.next() orelse {
                                        std.log.err(
                                            "Expected value after string argument \"{s}\"",
                                            .{field.name},
                                        );
                                        return error.Error;
                                    },
                                );
                            }

                            if (int) {
                                // TODO
                            }

                            // Mark this field as having been assigned.
                            assignments[index] = true;

                            break :b;
                        }
                    }

                    if (!exists) {
                        if (ppa_index < possibly_positional_arguments.len) {
                            dbg("Added \"{s}\" as a possibly positional argument.", .{arg});

                            possibly_positional_arguments[ppa_index] = try allocator.dupe(u8, arg);
                            ppa_index += 1;
                        } else {
                            std.log.err("Too many positional arguments specified, ignoring \"{s}\"", .{arg});
                        }
                    }
                }
            }

            // Ensure required arguments are set, if not print usage.
            var all_required_assignments_set = true;
            ppa_index = 0;
            inline for (fields, 0..) |field, i| {
                if (!assignments[i] and @typeInfo(field.type) != .optional and field.defaultValue() == null) {
                    if (possibly_positional_arguments[ppa_index]) |ppa| {
                        dbg("Attempting to assign \"{s}\" to argument \"{s}\".", .{ ppa, field.name });

                        // Flags for all supported variable types.
                        comptime var boolean = false;
                        comptime var string = false;
                        comptime var int = false;

                        comptime {
                            s: switch (@typeInfo(field.type)) {
                                // If the field is nullable, then loop the child type.
                                .optional => |o| continue :s @typeInfo(o.child),
                                // Booleans: (?)bool
                                .bool => boolean = true,
                                // Strings: (?)[]const u8
                                .pointer => |p| string = p.is_const and p.child == u8,
                                // Integers: (?)any bitness / sign
                                .int => int = true,
                                // Otherwise, this field is not supported.
                                else => @compileError(std.fmt.comptimePrint("Invalid Type \"{s}\" for argument \"{s}\"", .{
                                    @typeName(field.type),
                                    field.name,
                                })),
                            }
                        }

                        if (boolean) {
                            const fieldPtr: *bool = @ptrFromInt(@intFromPtr(input) + @offsetOf(Input, field.name));
                            if (std.mem.eql(u8, ppa, "true")) {
                                fieldPtr.* = true;
                            } else if (std.mem.eql(u8, ppa, "false")) {
                                fieldPtr.* = false;
                            }
                        }

                        if (string) {
                            const fieldPtr: *[]const u8 = @ptrFromInt(@intFromPtr(input) + @offsetOf(Input, field.name));
                            fieldPtr.* = ppa;
                        }

                        if (int) {
                            // TODO
                        }

                        possibly_positional_arguments[ppa_index] = null;
                        if (ppa_index < possibly_positional_arguments.len - 1) {
                            ppa_index += 1;
                        }
                    } else {
                        std.log.err("\"{s}\" requires the argument \"{s}\" to be set!", .{ @typeName(Input), fields[i].name });
                        all_required_assignments_set = false;
                    }
                }
            }
            // Free the extra arguments.
            for (possibly_positional_arguments) |@"ppa?"| if (@"ppa?") |ppa| {
                std.log.warn("Positional argument \"{s}\" was discarded.", .{ppa});
                allocator.free(ppa);
            };

            if (!all_required_assignments_set) {
                // TODO: Print usage.

                return error.Error;
            }

            return input;
        }

        pub fn deinit(allocator: std.mem.Allocator, input: *Input) void {
            inline for (@typeInfo(@TypeOf(input.*)).@"struct".fields) |field| {
                comptime var free = false;
                comptime {
                    s: switch (@typeInfo(field.type)) {
                        // If the field is nullable, then loop the child type.
                        .optional => |o| continue :s @typeInfo(o.child),
                        // Strings: (?)[]const u8, need to be deinit'd.
                        .pointer => |p| free = p.is_const and p.child == u8,
                        // Otherwise, this field does not need to be deinit'd.
                        else => {},
                    }
                }

                if (free) allocator.free(@field(input.*, field.name));
            }
            allocator.destroy(input);
        }
    };
}

// Filesystem Utilities

// Misc. Utilities

pub fn debugFn(comptime enabled: bool, comptime func: fn (comptime msg: []const u8, args: anytype) void) fn (comptime msg: []const u8, args: anytype) void {
    return if (enabled) struct {
        fn f(comptime msg: []const u8, args: anytype) void {
            func(msg, args);
        }
    }.f else struct {
        fn f(comptime _: []const u8, _: anytype) void {}
    }.f;
}
