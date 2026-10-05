pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe_name: []const u8 = b.option([]const u8, "artifact_name", "Use a custom name for the output executable") orelse if (optimize == .debug) "limp-debug" else b.fmt("limp-{t}-{t}", .{ target.result.cpu.arch, target.result.os.tag });

    const version: std.SemanticVersion = std.SemanticVersion.parse(zon.version) catch @panic("bad version string");

    const lua_extraspace = b.fmt("{}", .{@sizeOf(Temp_Allocator)});

    const lua_c: translate_c.Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("lua/headers.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "Temp_Allocator", .module = b.dependency("Temp_Allocator", .{}).module("Temp_Allocator") },
                .{ .name = "sx", .module = b.dependency("sx", .{}).module("sx") },
                .{ .name = "zon", .module = b.createModule(.{ .root_source_file = b.path("build.zig.zon") }) },
                .{ .name = "lua_c", .module = lua_c.mod },
            },
        }),
        .version = version,
    });
    exe.root_module.addIncludePath(b.path("lua/"));
    exe.root_module.addCMacro("LUA_EXTRASPACE", lua_extraspace);

    // zig fmt: off
    const lua_c_files = [_][]const u8{
        "lapi.c",    "lcode.c",    "lctype.c",   "ldebug.c",
        "ldo.c",     "ldump.c",    "lfunc.c",    "lgc.c",
        "llex.c",    "lmem.c",     "lobject.c",  "lopcodes.c",
        "lparser.c", "lstate.c",   "lstring.c",  "ltable.c",
        "ltm.c",     "lundump.c",  "lvm.c",      "lzio.c",

        "lauxlib.c", "lbaselib.c", "lcorolib.c", "ldblib.c",
        "liolib.c",  "lmathlib.c", "loadlib.c",  "loslib.c",
        "lstrlib.c", "ltablib.c",  "lutf8lib.c", "linit.c",
    };
    // zig fmt: on

    const c_flags = [_][]const u8{
        "-std=c99",
        "-fno-strict-aliasing",
        "-O2",
        "-Wall",
        "-Wextra",
    };

    inline for (lua_c_files) |c_file| {
        exe.root_module.addCSourceFile(.{
            .file = b.path("lua/" ++ c_file),
            .flags = &c_flags,
        });
    }

    b.installArtifact(exe);
    var run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "run limp").dependOn(&run.step);
    run.addPassthruArgs();

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "test limp").dependOn(&b.addRunArtifact(tests).step);
}

const zon = @import("build.zig.zon");
const Temp_Allocator = @import("Temp_Allocator").Temp_Allocator;
const translate_c = @import("translate_c");
const std = @import("std");
