const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const duckdb_lib_dir = b.option(
        []const u8,
        "duckdb-lib-dir",
        "Directory containing libduckdb.so and duckdb.h (overrides the bundled dependency)",
    );

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (duckdb_lib_dir) |dir| {
        const lazy = std.Build.LazyPath{ .cwd_relative = dir };
        mod.addIncludePath(lazy);
        mod.addLibraryPath(lazy);
        mod.addRPath(lazy);
        mod.linkSystemLibrary("duckdb", .{});
    } else if (b.lazyDependency("libduckdb", .{})) |dep| {
        mod.addIncludePath(dep.path("."));
        mod.addLibraryPath(dep.path("."));
        mod.addRPath(dep.path("."));
        mod.linkSystemLibrary("duckdb", .{});
    }

    const exe = b.addExecutable(.{
        .name = "jlpt-mcp-server",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run the server").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
