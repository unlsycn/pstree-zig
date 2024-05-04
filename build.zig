const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64 },
    .{ .cpu_arch = .x86 },
};

pub fn build(b: *std.Build) !void {
    const optimeze = b.standardOptimizeOption(.{});
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = "pstree",
            .root_source_file = .{ .path = "src/pstree.zig" },
            .target = b.resolveTargetQuery(t),
            .optimize = optimeze,
        });

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });

        b.getInstallStep().dependOn(&target_output.step);
    }
}
