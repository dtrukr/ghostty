const std = @import("std");

const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");

pub const Key = struct {
    hash: u64,
};

pub fn keyPath(
    mode: configpkg.SmartBackgroundKey,
    path: []const u8,
    trusted_local: bool,
) []const u8 {
    return switch (mode) {
        .pwd => normalizePath(path),
        .project => if (trusted_local) projectKeyPath(path) else normalizePath(path),
    };
}

pub fn hashKey(
    mode: configpkg.SmartBackgroundKey,
    host: ?[]const u8,
    path: []const u8,
    trusted_local: bool,
) u64 {
    const key_path = keyPath(mode, path, trusted_local);

    var hasher = std.hash.Wyhash.init(0);
    if (host) |h| {
        hasher.update(h);
        hasher.update(&[_]u8{0});
    }
    hasher.update(key_path);
    return hasher.final();
}

pub fn tintedBackground(
    key_hash: u64,
    base_bg: terminal.color.RGB,
    base_fg: terminal.color.RGB,
    strength_: f32,
    min_contrast: f64,
) terminal.color.RGB {
    const strength = std.math.clamp(strength_, 0.0, 1.0);
    if (strength <= 0) return base_bg;

    const hue = @as(f32, @floatFromInt(key_hash % 360)) / 360.0;
    const base_l = @as(f32, @floatCast(base_bg.perceivedLuminance()));
    const target_l = std.math.clamp(base_l, 0.25, 0.75);
    const hue_rgb = hslToRgb(hue, 0.65, target_l);

    // Clamp strength down if contrast with the configured foreground would
    // become too low. This is best-effort and only applies to the computed
    // default background (apps can still override colors dynamically).
    var t: f32 = strength;
    var out: terminal.color.RGB = mix(base_bg, hue_rgb, t);
    var i: usize = 0;
    while (i < 8 and out.contrast(base_fg) < min_contrast and t > 0.0) : (i += 1) {
        t *= 0.5;
        out = mix(base_bg, hue_rgb, t);
    }

    return out;
}

fn normalizePath(path: []const u8) []const u8 {
    // OSC 7 should report a directory path; trim trailing separators so that
    // "/foo/bar" and "/foo/bar/" map to the same key.
    const trimmed = std.mem.trimRight(u8, path, &[_]u8{std.fs.path.sep});
    return if (trimmed.len == 0) path else trimmed;
}

fn projectKeyPath(path: []const u8) []const u8 {
    var current = normalizePath(path);
    if (!std.fs.path.isAbsolute(current)) return current;

    while (true) {
        if (hasVcsMarker(current)) return current;

        const parent = std.fs.path.dirname(current) orelse return current;
        if (parent.len == current.len) return current;
        current = parent;
    }
}

fn hasVcsMarker(dir_path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return false;
    defer dir.close();

    _ = dir.statFile(".git") catch {
        _ = dir.statFile(".hg") catch {
            _ = dir.statFile(".svn") catch return false;
        };
        return true;
    };
    return true;
}

fn mix(a: terminal.color.RGB, b: terminal.color.RGB, t: f32) terminal.color.RGB {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = mixU8(a.r, b.r, clamped),
        .g = mixU8(a.g, b.g, clamped),
        .b = mixU8(a.b, b.b, clamped),
    };
}

fn mixU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    const out = af + (bf - af) * t;
    return @intFromFloat(@round(std.math.clamp(out, 0.0, 255.0)));
}

fn hslToRgb(h: f32, s: f32, l: f32) terminal.color.RGB {
    const sat = std.math.clamp(s, 0.0, 1.0);
    const light = std.math.clamp(l, 0.0, 1.0);

    if (sat == 0) {
        const v: u8 = @intFromFloat(@round(light * 255.0));
        return .{ .r = v, .g = v, .b = v };
    }

    const q: f32 = if (light < 0.5)
        light * (1.0 + sat)
    else
        light + sat - light * sat;
    const p: f32 = 2.0 * light - q;

    const r = hueToRgb(p, q, h + (1.0 / 3.0));
    const g = hueToRgb(p, q, h);
    const b = hueToRgb(p, q, h - (1.0 / 3.0));

    return .{
        .r = @intFromFloat(@round(r * 255.0)),
        .g = @intFromFloat(@round(g * 255.0)),
        .b = @intFromFloat(@round(b * 255.0)),
    };
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < (1.0 / 6.0)) return p + (q - p) * 6.0 * t;
    if (t < (1.0 / 2.0)) return q;
    if (t < (2.0 / 3.0)) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

test "smart_background: hashKey is deterministic" {
    const testing = std.testing;
    const h1 = hashKey(.pwd, null, "/tmp/foo", true);
    const h2 = hashKey(.pwd, null, "/tmp/foo", true);
    try testing.expectEqual(h1, h2);
}

test "smart_background: project key uses VCS root when available" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a fake repo root marker.
    try tmp.dir.makeDir(".git");
    try tmp.dir.makePath("a/b/c");

    const alloc = testing.allocator;
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const leaf = try tmp.dir.realpathAlloc(alloc, "a/b/c");
    defer alloc.free(leaf);

    const root_hash = hashKey(.project, null, root, true);
    const leaf_hash = hashKey(.project, null, leaf, true);
    try testing.expectEqual(root_hash, leaf_hash);
}

test "smart_background: tintedBackground strength=0 returns base color" {
    const testing = std.testing;
    const base_bg: terminal.color.RGB = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    const base_fg: terminal.color.RGB = .{ .r = 0xF0, .g = 0xF0, .b = 0xF0 };
    const out = tintedBackground(1234, base_bg, base_fg, 0.0, 1.0);
    try testing.expectEqualDeep(base_bg, out);
}
