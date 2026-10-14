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

    // End-to-end tests that spawn the built binary against stub ghostty/fzf.
    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("exe_path", exe.getEmittedBin());
    e2e_options.addOptionPath("repo_root", b.path("../.."));
    e2e_options.addOptionPath("experiment_root", b.path("."));
    const e2e_tests = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = e2e_options.createModule() }},
        }),
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    // Child processes and temp trees are external state; never cache results.
    run_e2e_tests.has_side_effects = true;

    const test_step = b.step("test", "Run unit and end-to-end tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_e2e_tests.step);

    // Optional: run the unchanged existing Bats suite against the Zig binary.
    const bats_cmd = b.addSystemCommand(&.{"bash"});
    bats_cmd.addFileArg(b.path("tests/run-existing-bats.sh"));
    bats_cmd.addArtifactArg(exe);
    bats_cmd.has_side_effects = true;
    b.step("bats", "Run tests/bats/test_ghostty_theme.bats against the Zig binary (needs bats, Bash 5)").dependOn(&bats_cmd.step);
}
