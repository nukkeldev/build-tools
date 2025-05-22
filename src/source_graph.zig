const std = @import("std");
const common = @import("common.zig");

const Input = struct {
    @"--string": []const u8,
    @"--debug": bool = false,
};

pub fn main() void {
    // Create our allocator.
    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();

    const allocator = da.allocator();

    // Create a parsing function to populate our program's input.
    const Parser = common.ArgumentsFor(Input, .{
        // .debug = true,
        .aliases = struct {
            pub const @"--debug" = &.{"-v"};
        },
    });

    const input = Parser.parse(allocator) catch return;
    defer Parser.deinit(allocator, input);

    std.debug.print("{}\n", .{input.*});
}

const SourceGraph = struct {
    pub var DEBUG = false;

    // Member Variables

    arena: std.heap.ArenaAllocator,
    nodes: std.StringHashMap(*Node),

    root: []const u8,
    include_paths: []const []const u8,
    sources: []const []const u8,
    headers: []const []const u8,

    // Type Definitions

    const Self = @This();

    const Node = struct {
        type_: Type,
        include: Include,
        status: Status,
        parent: ?*Node = null,
        children: ?[]*Node = null,

        pub const Status = enum { NotYetResolved, Queued, Resolved };
        pub const Type = enum { Source, Header };

        pub fn init(alloc: std.mem.Allocator, type_: Type, include: Include, parent: ?*Node, status: Status, children: ?[]*Node) !*Node {
            const node = try alloc.create(Node);
            node.* = .{
                .type_ = type_,
                .include = include,
                .status = status,
                .parent = parent,
                .children = children,
            };
            return node;
        }

        pub fn get_path(self: *const Node) []const u8 {
            return switch (self.include) {
                .Relative => |r| r.resolved_path,
                .System => |path| path,
            };
        }
    };

    const Include = union(enum) {
        Relative: RelativeInclude,
        System: []const u8,

        pub const RelativeInclude = struct {
            resolved_path: []const u8,
            status: enum { Exists, NotFound },
        };
    };

    // Functions

    /// Constructs an include graph off of the `root_file_path`.
    pub fn init(parent_allocator: std.mem.Allocator, root_file_path: []const u8, include_dirs: []const []const u8) !Self {
        // Alias the cwd.
        const cwd = std.fs.cwd();

        // Create an arena allocator.
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        const alloc = arena.allocator();
        errdefer arena.deinit();

        // Create the nodes and include_dirs_files hashmaps.
        var nodes = std.StringHashMap(*Node).init(alloc);
        var include_dirs_files = std.StringHashMap(*Node).init(alloc);

        // Create a "hash-set" to store the encompassing include directories.
        var include_paths = std.StringHashMap(void).init(alloc);

        // Walk the `include_dirs` to find all header files.
        for (include_dirs) |dir_path_combined| {
            const alias_index = std.mem.lastIndexOfScalar(u8, dir_path_combined, '#').?;

            const dir_path = dir_path_combined[0..alias_index];
            const prefix = dir_path_combined[alias_index + 1 .. dir_path_combined.len];

            try include_paths.put(try alloc.dupe(u8, dir_path), {});

            var dir = try cwd.openDir(dir_path, .{ .iterate = true });
            defer dir.close();

            var walker = try dir.walk(alloc);
            while (try walker.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".h")) continue;

                // Dupe the path so we don't have premature deinits.
                const path = try alloc.dupe(u8, entry.path);

                // Add the include's node to the hashmap.
                const node = try alloc.create(Node);
                node.status = .NotYetResolved;
                node.include = .{ .Relative = .{ .resolved_path = try std.fs.path.resolve(alloc, &.{ dir_path, path }), .status = .Exists } };
                try include_dirs_files.put(try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, if (prefix.len > 0) "/" else "", path }), node);
            }
        }

        // Log our include directories files.
        if (DEBUG) {
            var iter = include_dirs_files.iterator();
            while (iter.next()) |entry| {
                switch (entry.value_ptr.*.include) {
                    .Relative => |r| std.log.debug("#include \"{s}\" => {s}", .{ entry.key_ptr.*, r.resolved_path }),
                    else => unreachable,
                }
            }
        }

        // Create the initial root node.
        const root = try Node.init(
            alloc,
            .Source, // TODO: Detect based on file extension.
            .{ .Relative = .{ .resolved_path = root_file_path, .status = .Exists } },
            null,
            .Queued,
            null,
        );
        try nodes.put(root_file_path, root);

        // Initialize a queue to store the files we need to process.
        var queue = try std.ArrayList(*Node).initCapacity(alloc, 1);
        queue.appendAssumeCapacity(root);

        // Initialize a buffer to hold nodes before being inserted into the parent node.
        var include_buffer = std.ArrayList(*Node).init(alloc);

        // Process the queue until it is empty.
        while (queue.pop()) |node| {
            if (node.status == .Resolved) continue;
            if (node.status != .Queued) @panic("Only node's with a status of .Queued may be processed! This is a bug.");

            // Retrive the file path from the node, asserting it to not be a system include.
            var relative_include: *Include.RelativeInclude = undefined;
            switch (node.include) {
                .Relative => |r| relative_include = @constCast(&r),
                else => @panic("We should not be trying to process system includes..."),
            }
            const file_path = relative_include.resolved_path;
            try include_paths.put(std.fs.path.dirname(file_path).?, {});

            // Open the file.
            const file = cwd.openFile(file_path, .{}) catch |e| switch (e) {
                error.FileNotFound => {
                    std.log.err("Cannot find relative include '{s}'!", .{file_path});
                    relative_include.status = .NotFound;
                    continue;
                },
                else => return e,
            };
            defer file.close();

            // Attempt to find the source if present.
            // TODO: Look for .c as well.
            if (node.type_ == .Header) b: {
                const file_name = std.fs.path.basename(file_path);
                const source_name = try std.fmt.allocPrint(alloc, "{s}.cpp", .{file_name[0..std.mem.lastIndexOfScalar(u8, file_name, '.').?]});
                const path = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(file_path).?, source_name });

                cwd.access(path, .{}) catch break :b;
                if (DEBUG) std.log.debug("source found for {s}: {s}", .{ file_path, path });

                if (!nodes.contains(path)) {
                    const source_node = try Node.init(
                        alloc,
                        .Source,
                        .{
                            .Relative = .{
                                .resolved_path = path,
                                .status = .Exists, // Say the include exists by default, then override upon processing if necessary.
                            },
                        },
                        null,
                        .Queued,
                        null,
                    );
                    try nodes.put(path, source_node);
                    try queue.append(source_node);
                }
            }

            // Read it's contents.
            const contents = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
            defer alloc.free(contents);

            // Iterate through the lines and look for includes.
            var lines = std.mem.splitScalar(u8, contents, '\n');
            var line_number: usize = 1;

            while (lines.next()) |line| : (line_number += 1) {
                if (!std.mem.startsWith(u8, line, "#include")) continue;

                // Tokenize the line.
                var tokens = std.mem.tokenizeScalar(u8, line, ' ');
                _ = tokens.next(); // Skip the #include

                const include = tokens.next() orelse {
                    std.log.err("Malformed #include on line {} of {s}: '{s}'!", .{ line_number, file_path, line });
                    continue;
                };

                // Duplicate the memory so it isn't corrupted when we deinit contents.
                const path = try alloc.dupe(u8, include[1 .. include.len - 1]);
                const resolved_path = try std.fs.path.resolve(alloc, &.{ std.fs.path.dirname(file_path) orelse @panic("TODO"), path });
                if (nodes.get(resolved_path) orelse include_dirs_files.get(path)) |previously_processed_node| {
                    try include_buffer.append(previously_processed_node);

                    if (DEBUG) std.log.debug("{s} -> {s}", .{ file_path, previously_processed_node.get_path() });
                    if (previously_processed_node.status == .NotYetResolved and previously_processed_node.status == .Resolved) {
                        previously_processed_node.status = .Queued;
                        try queue.append(previously_processed_node);
                    }

                    continue;
                }

                const is_relative = include[0] & include[include.len - 1] == '"';

                // If the include is surrounded by quotes then assume it's a relative path.
                // Otherwise, we can assume it's surrounded by angle brackets and hope the user knows of the dependency.
                const pre_queue_node = try Node.init(
                    alloc,
                    .Header,
                    if (is_relative) .{
                        .Relative = .{
                            .resolved_path = resolved_path,
                            .status = .Exists, // Say the include exists by default, then override upon processing if necessary.
                        },
                    } else .{ .System = path },
                    node,
                    if (is_relative) .Queued else .NotYetResolved,
                    null,
                );

                try nodes.put(resolved_path, pre_queue_node);
                try include_buffer.append(pre_queue_node);
                if (is_relative) {
                    if (DEBUG) std.log.debug("{s} -> {s}", .{ file_path, resolved_path });
                    try queue.append(pre_queue_node);
                }
            }

            // Convert the buffer to an owned slice for the node.
            // This clears the list and it's capacity.
            node.children = try include_buffer.toOwnedSlice();
            node.status = .Resolved;
        }

        // Generate include paths.
        const paths = b: {
            const paths = try alloc.alloc([]const u8, include_paths.count());

            var i: usize = 0;
            var iter = include_paths.keyIterator();
            while (iter.next()) |path| : (i += 1) {
                paths[i] = path.*;
                if (DEBUG) std.log.debug("path: {s}", .{path.*});
            }

            break :b paths;
        };

        // Generate include sources and headers.
        const sources, const headers = b: {
            const sources = try alloc.alloc([]const u8, nodes.count());
            const headers = try alloc.alloc([]const u8, nodes.count());

            var source_count: usize = 0;
            var header_count: usize = 0;
            var iter = nodes.iterator();

            while (iter.next()) |entry| {
                if (entry.value_ptr.*.type_ == .Source) {
                    sources[source_count] = entry.value_ptr.*.get_path();
                    source_count += 1;
                } else {
                    headers[header_count] = entry.value_ptr.*.get_path();
                    header_count += 1;
                }
            }

            break :b .{ sources[0..source_count], headers[0..header_count] };
        };

        // Sort the lists.
        const compareStrings = struct {
            fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.gt);
            }
        }.compareStrings;

        std.mem.sort([]const u8, sources, {}, compareStrings);
        std.mem.sort([]const u8, headers, {}, compareStrings);

        return .{ .arena = arena, .nodes = nodes, .include_paths = paths, .headers = headers, .sources = sources, .root = root_file_path };
    }

    pub fn deinit(self: Self) void {
        self.arena.deinit();
    }

    // Analysis

    pub fn get_root(self: *const Self) []const u8 {
        return self.root;
    }

    pub fn get_include_paths(self: *const Self) []const []const u8 {
        return self.include_paths;
    }

    pub fn get_sources(self: *const Self) []const []const u8 {
        return self.sources;
    }

    pub fn get_headers(self: *const Self) []const []const u8 {
        return self.headers;
    }

    // Formatting

    pub fn debug_graphviz(self: *const Self, writer: anytype) !void {
        std.log.debug("Exported graphviz file.", .{});
        try writer.print("digraph A {{\n", .{});

        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const path = entry.value_ptr.*.get_path();
            if (entry.value_ptr.*.children) |children| {
                for (children) |child| {
                    try writer.print("\t\"{s}\" -> \"{s}\";\n", .{ path, child.get_path() });
                }
            }
        }

        try writer.print("}}", .{});
    }

    pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Include Graph of <{s}>:\n", .{self.root});

        try writer.print("Include Paths:\n", .{});
        for (self.include_paths) |include_path| {
            try writer.print("\t{s}\n", .{include_path});
        }

        try writer.print("Headers:\n", .{});
        for (self.headers) |header| {
            try writer.print("\t{s}\n", .{header});
        }

        try writer.print("Inferred Sources:\n", .{});
        for (self.sources) |source| {
            try writer.print("\t{s}\n", .{source});
        }
    }
};
