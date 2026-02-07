const GhosttyXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

xcframework: *XCFrameworkStep,
target: Target,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    // Only create the build graph we actually need for the requested target.
    //
    // This matters for developer setups that only have the macOS Command Line
    // Tools installed: iOS SDK discovery will fail without full Xcode, and we
    // don't want unrelated build commands (like `zig build test`) to require it.

    // The xcframework wraps our ghostty library so that we can link
    // it to the final app built with Swift.
    const xcframework = xcframework: {
        switch (target) {
            .native => {
                const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
                    b,
                    Config.genericMacOSTarget(b, null),
                ));
                break :xcframework XCFrameworkStep.create(b, .{
                    .name = "GhosttyKit",
                    .out_path = "macos/GhosttyKit.xcframework",
                    .libraries = &.{.{
                        .library = macos_native.output,
                        .headers = b.path("include"),
                        .dsym = macos_native.dsym,
                    }},
                });
            },

            .universal => {
                // Universal macOS build
                const macos_universal = try GhosttyLib.initMacOSUniversal(b, deps);

                // iOS
                const ios = try GhosttyLib.initStatic(b, &try deps.retarget(
                    b,
                    b.resolveTargetQuery(.{
                        .cpu_arch = .aarch64,
                        .os_tag = .ios,
                        .os_version_min = Config.osVersionMin(.ios),
                        .abi = null,
                    }),
                ));

                // iOS Simulator
                const ios_sim = try GhosttyLib.initStatic(b, &try deps.retarget(
                    b,
                    b.resolveTargetQuery(.{
                        .cpu_arch = .aarch64,
                        .os_tag = .ios,
                        .os_version_min = Config.osVersionMin(.ios),
                        .abi = .simulator,

                        // We force the Apple CPU model because the simulator
                        // doesn't support the generic CPU model as of Zig 0.14 due
                        // to missing "altnzcv" instructions, which is false. This
                        // surely can't be right but we can fix this if/when we get
                        // back to running simulator builds.
                        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
                    }),
                ));

                break :xcframework XCFrameworkStep.create(b, .{
                    .name = "GhosttyKit",
                    .out_path = "macos/GhosttyKit.xcframework",
                    .libraries = &.{
                        .{
                            .library = macos_universal.output,
                            .headers = b.path("include"),
                            .dsym = macos_universal.dsym,
                        },
                        .{
                            .library = ios.output,
                            .headers = b.path("include"),
                            .dsym = ios.dsym,
                        },
                        .{
                            .library = ios_sim.output,
                            .headers = b.path("include"),
                            .dsym = ios_sim.dsym,
                        },
                    },
                });
            },
        }
    };

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const GhosttyXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
