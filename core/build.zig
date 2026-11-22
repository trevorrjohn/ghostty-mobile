const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        // Linked into a shared library on Android.
        .pic = true,
    });

    const lib = b.addLibrary(.{
        .name = "seance_core",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(lib);
    b.installFile("include/seance_core.h", "include/seance_core.h");

    // Shared library for the host, used by the Android app's JVM unit tests
    // (they load the same JNI exports the app links on-device).
    const host_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = false,
    });
    const host_lib = b.addLibrary(.{
        .name = "seance_core",
        .linkage = .dynamic,
        .root_module = host_module,
    });
    const host_step = b.step("host-jni", "Build the host shared library for JVM tests");
    host_step.dependOn(&b.addInstallArtifact(host_lib, .{}).step);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run core unit tests").dependOn(&run_tests.step);
}
