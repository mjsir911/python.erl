const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addSharedLibrary(.{
        .name = "python-nif",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/nif.zig"),
    });
    lib.addIncludePath(.{ .cwd_relative = "/usr/lib64/erlang/usr/include/" });
    lib.addIncludePath(.{ .cwd_relative = "/usr/include/python3.13/" });
    lib.linkLibC();
    // const lib = b.addLibrary(.{
    //     .name = "erlang-python",
    //     .linkage = .shared,
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //     }),
    // });
    lib.addObjectFile(.{.cwd_relative="/usr/lib64/erlang/lib/erl_interface-5.5/lib/libei.a",});
    lib.linkSystemLibrary("python3.13");

    b.installArtifact(lib);
}

