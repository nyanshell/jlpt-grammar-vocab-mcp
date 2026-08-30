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

    // @cImport is gone in 0.17: duckdb.h is translated to a Zig module at
    // build time and imported as "duckdb_c" (see src/db.zig).
    const header: ?std.Build.LazyPath = if (duckdb_lib_dir) |dir|
        .{ .cwd_relative = b.pathJoin(&.{ dir, "duckdb.h" }) }
    else if (b.lazyDependency("libduckdb", .{})) |dep|
        dep.path("duckdb.h")
    else
        null;

    if (header) |h| {
        const translate = b.addTranslateC(.{
            .root_source_file = h,
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("duckdb_c", translate.createModule());

        const lib_path: std.Build.LazyPath = if (duckdb_lib_dir) |dir|
            .{ .cwd_relative = dir }
        else
            b.lazyDependency("libduckdb", .{}).?.path(".");
        mod.addLibraryPath(lib_path);
        mod.addRPath(lib_path);
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
