const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const interface_module = b.addModule("interface", .{
        .root_source_file = b.path("src/interface.zig"),
    });

    // Create test modules
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/interface.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Creates a step for unit testing.
    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Simple test
    const simple_test_module = b.createModule(.{
        .root_source_file = b.path("test/simple.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_test_module.addImport("interface", interface_module);

    const simple_tests = b.addTest(.{
        .root_module = simple_test_module,
    });

    const run_simple_tests = b.addRunArtifact(simple_tests);

    // Complex test
    const complex_test_module = b.createModule(.{
        .root_source_file = b.path("test/complex.zig"),
        .target = target,
        .optimize = optimize,
    });
    complex_test_module.addImport("interface", interface_module);

    const complex_tests = b.addTest(.{
        .root_module = complex_test_module,
    });

    const run_complex_tests = b.addRunArtifact(complex_tests);

    // Embedded test
    const embedded_test_module = b.createModule(.{
        .root_source_file = b.path("test/embedded.zig"),
        .target = target,
        .optimize = optimize,
    });
    embedded_test_module.addImport("interface", interface_module);

    const embedded_tests = b.addTest(.{
        .root_module = embedded_test_module,
    });

    const run_embedded_tests = b.addRunArtifact(embedded_tests);

    // Vtable test
    const vtable_test_module = b.createModule(.{
        .root_source_file = b.path("test/vtable.zig"),
        .target = target,
        .optimize = optimize,
    });
    vtable_test_module.addImport("interface", interface_module);

    const vtable_tests = b.addTest(.{
        .root_module = vtable_test_module,
    });

    const run_vtable_tests = b.addRunArtifact(vtable_tests);

    // Collections test
    const collections_test_module = b.createModule(.{
        .root_source_file = b.path("test/collections.zig"),
        .target = target,
        .optimize = optimize,
    });
    collections_test_module.addImport("interface", interface_module);

    const collections_tests = b.addTest(.{
        .root_module = collections_test_module,
    });

    const run_collections_tests = b.addRunArtifact(collections_tests);

    // Inference test
    const inference_test_module = b.createModule(.{
        .root_source_file = b.path("test/inference.zig"),
        .target = target,
        .optimize = optimize,
    });
    inference_test_module.addImport("interface", interface_module);

    const inference_tests = b.addTest(.{
        .root_module = inference_test_module,
    });

    const run_inference_tests = b.addRunArtifact(inference_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_simple_tests.step);
    test_step.dependOn(&run_complex_tests.step);
    test_step.dependOn(&run_embedded_tests.step);
    test_step.dependOn(&run_vtable_tests.step);
    test_step.dependOn(&run_collections_tests.step);
    test_step.dependOn(&run_inference_tests.step);
}
