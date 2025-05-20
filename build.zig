const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build Options

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // Targets

    addSourceGraph(b, target, optimize);
}

/// Creates the compilation and run steps for source graph.
/// Registers the run step as a TLP under `source-graph`.
/// Exports a public module `source-graph` for external consumption.
fn addSourceGraph(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Create the *public* module.
    const mod = b.addModule("source-graph", .{
        .root_source_file = b.path("src/source_graph.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the executable compilation step.
    const exe = b.addExecutable(.{
        .name = "source-graph",
        .root_module = mod,
    });

    // Mark this to be installed.
    b.installArtifact(exe);

    // Create the executable's run step.
    const run = b.addRunArtifact(exe);

    // Pass the command-line arguments through to the run step.
    if (b.args) |args| {
        run.addArgs(args);
    }

    // Register the run step as a TLP.
    const run_tlp = b.step("source-graph", "Generates source/header dependencies for a supplied source file.");
    run_tlp.dependOn(&run.step);

    // Register a check step.
    const check_tlp = b.step("source-graph-check", "Checks the source-graph source code to be valid.");
    check_tlp.dependOn(&exe.step);
}
