const std = @import("std");

pub const ConfigStep = struct {
    step: std.build.Step,
    generated_file: std.build.GeneratedFile,
    builder: *std.build.Builder,
    override_version: ?[]const u8,

    pub fn create(builder: *std.build.Builder) !*ConfigStep {
        const path = "zig-cache/limp_config.zig";
        try std.fs.cwd().makePath(std.fs.path.dirname(path).?);

        const version_option_desc = "Allows setting a version number when building for a release instead of using a git commit hash";
        const override_version = builder.option([]const u8, "version", version_option_desc);

        var ret = try builder.allocator.create(ConfigStep);
        ret.* = ConfigStep {
            .step = std.build.Step.init(.custom, "config", builder.allocator, make),
            .generated_file = .{
                .step = &ret.step,
                .path = path,
            },
            .builder = builder,
            .override_version = override_version,
        };
        return ret;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(ConfigStep, "step", step);

        const version = self.override_version orelse try self.getCommitHash();

        const file = try std.fs.cwd().createFile(self.generated_file.path.?, .{});
        defer file.close();

        const writer = file.writer();
        writer.print("pub const version = \"{}\";\n", .{ std.fmt.fmtSliceEscapeUpper(version) }) catch unreachable;
    }

    fn getCommitHash(self: *ConfigStep) ![]const u8 {
        if (!std.process.can_spawn) {
            std.debug.print("Cannot retrieve commit hash ({s} does not support spawning a child process)\n", .{ @tagName(std.builtin.os.tag) });
            return std.build.ExecError.ExecNotSupported;
        }

        const result = std.ChildProcess.exec(.{
            .allocator = self.builder.allocator,
            .argv = &.{ "git", "rev-parse", "HEAD" },
            .cwd = self.builder.build_root,
            .env_map = self.builder.env_map,
        }) catch |err| {
            std.debug.print("Unable to execute git rev-parse: {s}\n", .{ @errorName(err) });
            return err;
        };

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("git rev-parse failed with code {}\n", .{ code });
                    return error.UnexpectedExitCode;
                }
            },
            else => {
                std.debug.print("git rev-parse terminated unexpectedly\n", .{});
                return error.UncleanExit;
            },
        }

        return result.stdout;
    }

};
