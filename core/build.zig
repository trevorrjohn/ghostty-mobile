const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = createModule(b, target, optimize, false);
    const lib = b.addLibrary(.{
        .name = "seance_core",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(lib);
    b.installFile("include/seance_core.h", "include/seance_core.h");

    // Shared library for the host, used by the Android app's JVM unit tests
    // (they load the same JNI exports the app links on-device).
    const host_lib = b.addLibrary(.{
        .name = "seance_core",
        .linkage = .dynamic,
        .root_module = createModule(b, b.graph.host, optimize, true),
    });
    const host_step = b.step("host-jni", "Build the host shared library for JVM tests");
    host_step.dependOn(&b.addInstallArtifact(host_lib, .{}).step);

    const tests = b.addTest(.{ .root_module = createModule(b, b.graph.host, optimize, true) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run core unit tests").dependOn(&run_tests.step);
}

fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_vt: bool,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Linked into a shared library on Android.
        .pic = true,
    });

    // libghostty-vt, consumed through its C API so the engine stays a thin,
    // upgrade-friendly layer over the same ABI both apps use. The apps link
    // libghostty-vt themselves, so the static archive only references it;
    // host builds (tests, JVM library) link it here.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    })) |dep| {
        if (link_vt) module.linkLibrary(dep.artifact("ghostty-vt-static"));

        // Android has no libc headers in Zig's tree, so translate the (LP64,
        // identical-layout) C declarations against musl instead.
        var translate_target = target;
        if (target.result.abi.isAndroid()) {
            translate_target = b.resolveTargetQuery(.{
                .cpu_arch = target.result.cpu.arch,
                .os_tag = .linux,
                .abi = .musl,
            });
        }
        const translate = b.addTranslateC(.{
            .root_source_file = b.path("src/ghostty_c.h"),
            .target = translate_target,
            .optimize = optimize,
        });
        translate.addIncludePath(dep.path("include"));
        module.addImport("ghostty_c", translate.createModule());
    }
    return module;
}
