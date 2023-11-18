const std = @import("std");
const config = @import("build_config.zig");
const @"Zig-TempAllocator" = @import("Zig-TempAllocator");
const TempAllocator = @"Zig-TempAllocator".TempAllocator;

pub fn build(b: *std.build.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOptions();
    const exe_name = if (mode == .Debug) "limp-debug" else "limp";

    const config_step = config.ConfigStep.create(b) catch unreachable;
    const config_pkg = std.build.Pkg {
        .name = "config",
        .source = .{ .generated = &config_step.generated_file },
    };
    _ = config_pkg;

    const exe = b.addExecutable(exe_name, .{
        .name = exe_name,
        .root_source_file = .{ .path = "src/main.zig" },
      //  .version: ?std.SemanticVersion = null,
        .target = target,
        .optimize = mode,
        .link_libc = true,
        .single_threaded = true,
    });
    //exe.addPackage(config_pkg);
    exe.addModule("TempAllocator", b.dependency("Zig-TempAllocator").module("TempAllocator"));
    exe.addModule("sx", b.dependency("Zig-SX").module("sx"));
    exe.addIncludePath("lua/");
    exe.addIncludePath("zlib/");
    var extraSpace = std.fmt.comptimePrint("{}", .{@sizeOf(TempAllocator)});
    exe.defineCMacro("LUA_EXTRASPACE", extraSpace);
    exe.defineCMacro("Z_SOLO", "");
    exe.defineCMacro("ZLIB_CONST", "");

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

    const zlib_c_files = [_][]const u8{
        "adler32.c",  "crc32.c",   "deflate.c", "inflate.c",
        "inftrees.c", "inffast.c", "trees.c",   "zutil.c",
    };

    const c_flags = [_][]const u8{
        "-std=c99",
        "-fno-strict-aliasing",
        "-O2",
        "-Wall",
        "-Wextra",
    };

    for (lua_c_files) |c_file| {
        exe.addCSourceFile("lua/" ++ c_file, &c_flags);
    }

    for (zlib_c_files) |c_file| {
        exe.addCSourceFile("zlib/" ++ c_file, &c_flags);
    }

    b.installArtifact(exe);
    var run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "run limp").dependOn(&run.step);
    if (b.args) |args| {
        run.addArgs(args);
    }

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });

    const test_run = b.addRunArtifact(tests);
    b.step("test", "test limp").dependOn(&test_run.step);
}
