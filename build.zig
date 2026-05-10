const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("comptime_serde", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 1. Generate documentation and install it to `prefix/docs`
    const doc_obj = b.addObject(.{
        .name = "docs",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // 2. Run unit tests
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // 3. Build the CLI tool, which depends on the `zigcli` package.
    if (b.lazyDependency("zigcli", .{
        .target = target,
        .optimize = optimize,
    })) |zigcli_dep| {
        const zigcli_mod = zigcli_dep.module("zigcli");

        const build_options = b.addOptions();
        build_options.addOption(
            []const u8,
            "version",
            b.option([]const u8, "version", "Version string") orelse "dev",
        );
        build_options.addOption(
            []const u8,
            "git_commit",
            b.option([]const u8, "git_commit", "Git commit") orelse "unknown",
        );

        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigcli", .module = zigcli_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        });
        const exe = b.addExecutable(.{
            .name = "serde-gen",
            .root_module = exe_mod,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run serde-gen");
        run_step.dependOn(&run_cmd.step);

        const cli_test_mod = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigcli", .module = zigcli_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        });
        const cli_tests = b.addTest(.{ .root_module = cli_test_mod });
        const run_cli_tests = b.addRunArtifact(cli_tests);
        test_step.dependOn(&run_cli_tests.step);
    }
}
