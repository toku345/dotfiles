const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const install_preview = b.option(
        bool,
        "install-preview",
        "Install the Bash ghostty-theme-preview next to the binary (default: true)",
    ) orelse true;

    // Read-only references outside the experiment directory.
    const preview_script = b.path("../../dot_local/bin/executable_ghostty-theme-preview");

    const exe = b.addExecutable(.{
        .name = "ghostty-theme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
    if (install_preview) {
        // Sibling lookup in the binary finds zig-out/bin/ghostty-theme-preview,
        // so `zig-out/bin/ghostty-theme` gets live preview without extra setup.
        b.getInstallStep().dependOn(&b.addInstallBinFile(preview_script, "ghostty-theme-preview").step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ghostty-theme").dependOn(&run_cmd.step);

    // Unit tests for the pure parsing / OSC logic.
    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
