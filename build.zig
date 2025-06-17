const std = @import("std");
const builtin = @import("builtin");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = "hydra";
    const exe = b.addExecutable(.{.name = app, .root_module = main});

    exe.linkLibC();

    // Adding package dependency
    const cfp = b.dependency("cfp", .{});
    exe.root_module.addImport("cfp", cfp.module("cfp"));

    const stencil = b.dependency("stencil", .{});
    exe.root_module.addImport("stencil", stencil.module("stencil"));

    const saturn = b.dependency("saturn", .{});
    exe.root_module.addImport("saturn", saturn.module("saturn"));

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}