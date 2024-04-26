const std = @import("std");
const @"Zig-TempAllocator" = @import("Zig-TempAllocator");
const Temp_Allocator = @"Zig-TempAllocator".Temp_Allocator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});
    const exe_name = if (mode == .Debug) "limp-debug" else "limp";
    const version_str = b.option([]const u8, "version", "override default version number") orelse "unreleased";
    const version: std.SemanticVersion = std.SemanticVersion.parse(version_str) catch .{ .major = 0, .minor = 0, .patch = 0 };

    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = .{ .path = "src/main.zig" },
        .version = version,
        .target = target,
        .optimize = mode,
        .link_libc = true,
        .single_threaded = true,
    });
    exe.root_module.addOptions("config", options);
    exe.root_module.addImport("Temp_Allocator", b.dependency("Zig-TempAllocator", .{}).module("Temp_Allocator"));
    exe.root_module.addImport("sx", b.dependency("Zig-SX", .{}).module("sx"));

    exe.addIncludePath(.{ .path = "lua/" });

    const extraSpace = std.fmt.comptimePrint("{}", .{@sizeOf(Temp_Allocator)});
    exe.defineCMacro("LUA_EXTRASPACE", extraSpace);

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

    const c_flags = [_][]const u8{
        "-std=c99",
        "-fno-strict-aliasing",
        "-O2",
        "-Wall",
        "-Wextra",
    };

    inline for (lua_c_files) |c_file| {
        exe.addCSourceFile(.{
            .file = .{ .path = "lua/" ++ c_file },
            .flags = &c_flags,
        });
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
