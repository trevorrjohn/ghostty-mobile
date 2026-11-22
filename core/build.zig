const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .name = "seance_core",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(lib);
    b.installFile("include/seance_core.h", "include/seance_core.h");

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run core unit tests").dependOn(&run_tests.step);
}
