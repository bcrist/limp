const std = @import("std");
const config = @import("build_config.zig");
const TempAllocator = @import("pkg/Zig-TempAllocator/temp_allocator.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe_name = if (mode == .Debug) "limp-debug" else "limp";

    const config_step = config.ConfigStep.create(b) catch unreachable;
    const config_pkg = std.build.Pkg {
        .name = "config",
        .source = .{ .generated = &config_step.generated_file },
    };

    const exe = b.addExecutable(exe_name, "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackage(config_pkg);
    exe.addPackagePath("TempAllocator", "pkg/Zig-TempAllocator/temp_allocator.zig");
    exe.addPackagePath("sx", "pkg/Zig-SX/sx.zig");
    exe.linkLibC();
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

    inline for (lua_c_files) |c_file| {
        exe.addCSourceFile("lua/" ++ c_file, &c_flags);
    }

    inline for (zlib_c_files) |c_file| {
        exe.addCSourceFile("zlib/" ++ c_file, &c_flags);
    }

    exe.single_threaded = true;

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
