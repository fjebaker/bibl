const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_clippy = b.dependency("clippy", .{ .target = target, .optimize = optimize });
    const dep_farbe = b.dependency("farbe", .{ .target = target, .optimize = optimize });
    const dep_datetime = b.dependency("datetime", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "bibl",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    exe.root_module.addImport("clippy", dep_clippy.module("clippy"));
    exe.root_module.addImport("farbe", dep_farbe.module("farbe"));
    exe.root_module.addImport("datetime", dep_datetime.module("zig-datetime"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
