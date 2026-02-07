const std = @import("std");

const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");

const Allocator = std.mem.Allocator;

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

pub fn hashKeyFromKeyPath(host: ?[]const u8, key_path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (host) |h| {
        hasher.update(h);
        hasher.update(&[_]u8{0});
    }
    hasher.update(key_path);
    return hasher.final();
}

/// Like `keyPath`, but may allocate to return a stable key string.
///
/// Today this is primarily used to improve `.project` mode for Git worktrees,
/// where the worktree root should map to the main repo root for stable hashing.
pub fn keyPathAlloc(
    alloc: Allocator,
    mode: configpkg.SmartBackgroundKey,
    path: []const u8,
    trusted_local: bool,
) ![]const u8 {
    _ = trusted_local;
    // We use an arena for intermediate allocations and then dupe the final
    // result into the caller allocator so tests can free it.
    var arena_alloc: std.heap.ArenaAllocator = .init(alloc);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const key_path: []const u8 = switch (mode) {
        .pwd => normalizePath(path),
        // `.project` is best-effort: if the path doesn't exist locally, we fall
        // back to the normalized string key (see `projectKeyPathAlloc`).
        .project => try projectKeyPathAlloc(arena, path),
    };

    return try alloc.dupe(u8, key_path);
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
    // Keep the tint in a "pastel" range: lower saturation, and a slightly
    // higher lightness floor so the tint reads as a gentle shift.
    const target_l = std.math.clamp(base_l, 0.30, 0.85);
    const hue_rgb = hslToRgb(hue, 0.35, target_l);

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

fn projectKeyPathAlloc(alloc: Allocator, path: []const u8) ![]const u8 {
    var current = normalizePath(path);
    if (!std.fs.path.isAbsolute(current)) return current;

    // If the reported directory doesn't exist locally, do not walk upward
    // (which would often collapse to "/" and cause many unrelated paths to
    // share the same key). Fall back to a stable string key instead.
    {
        var dir = std.fs.openDirAbsolute(current, .{}) catch return current;
        dir.close();
    }

    while (true) {
        if (try hasVcsMarkerAlloc(alloc, current)) |root| return root;

        const parent = std.fs.path.dirname(current) orelse return current;
        if (parent.len == current.len) return current;
        current = parent;
    }
}

fn hasVcsMarkerAlloc(alloc: Allocator, dir_path: []const u8) !?[]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return null;
    defer dir.close();

    const canonical = try dir.realpathAlloc(alloc, ".");

    // Git (directory or worktree file)
    if (dir.statFile(".git")) |st| {
        switch (st.kind) {
            .directory => return canonical,
            .file => {
                // Best-effort: if this looks like a Git worktree, map to the
                // main repo root so multiple worktrees share a tint.
                if (try gitWorktreeMainRootAlloc(alloc, dir_path)) |main_root| {
                    return main_root;
                }
                return canonical;
            },
            else => return canonical,
        }
    } else |_| {}

    // Other VCS markers: treat as project root at this directory.
    _ = dir.statFile(".hg") catch {
        _ = dir.statFile(".svn") catch return null;
        return canonical;
    };
    return canonical;
}

fn gitWorktreeMainRootAlloc(alloc: Allocator, dir_path: []const u8) !?[]const u8 {
    // `dir_path` is the directory containing the `.git` file.
    // Worktree `.git` files look like: "gitdir: /path/to/repo/.git/worktrees/name"
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return null;
    defer dir.close();

    var file = dir.openFile(".git", .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (!std.mem.startsWith(u8, content, "gitdir:")) return null;

    const rest = std.mem.trimLeft(u8, content["gitdir:".len..], " \t");
    // Only consider this a worktree if it points into a `/worktrees/` directory.
    // This avoids unintentionally unifying colors for submodules (`/modules/`).
    if (std.mem.indexOf(u8, rest, "/worktrees/") == null) return null;

    const gitdir_abs = gitdir_abs: {
        if (std.fs.path.isAbsolute(rest)) break :gitdir_abs try alloc.dupe(u8, rest);
        // Relative gitdir is relative to the `.git` file directory.
        break :gitdir_abs try std.fs.path.resolve(alloc, &.{ dir_path, rest });
    };
    defer alloc.free(gitdir_abs);

    const common_git_dir = common_git_dir: {
        // Prefer commondir if present.
        const commondir_path = std.fs.path.join(alloc, &.{ gitdir_abs, "commondir" }) catch null;
        if (commondir_path) |p| {
            defer alloc.free(p);
            if (std.fs.openFileAbsolute(p, .{})) |cf| {
                defer cf.close();
                var cbuf: [1024]u8 = undefined;
                const cn = cf.readAll(&cbuf) catch 0;
                const cval = std.mem.trim(u8, cbuf[0..cn], " \t\r\n");
                if (cval.len > 0) {
                    if (std.fs.path.isAbsolute(cval)) break :common_git_dir try alloc.dupe(u8, cval);
                    break :common_git_dir try std.fs.path.resolve(alloc, &.{ gitdir_abs, cval });
                }
            } else |_| {}
        }

        // Fallback: strip trailing `/worktrees/<name>` from gitdir.
        if (std.mem.indexOf(u8, gitdir_abs, "/worktrees/")) |idx| {
            break :common_git_dir try alloc.dupe(u8, gitdir_abs[0..idx]);
        }

        return null;
    };
    defer alloc.free(common_git_dir);

    // Common case: common_git_dir ends in ".git" directory.
    if (std.mem.eql(u8, std.fs.path.basename(common_git_dir), ".git")) {
        const root = std.fs.path.dirname(common_git_dir) orelse return null;
        var root_dir = std.fs.openDirAbsolute(root, .{}) catch return try alloc.dupe(u8, root);
        defer root_dir.close();
        const rp = try root_dir.realpathAlloc(alloc, ".");
        return @as(?[]const u8, rp);
    }

    // Otherwise, just use the common dir itself as the key.
    var common_dir = std.fs.openDirAbsolute(common_git_dir, .{}) catch return try alloc.dupe(u8, common_git_dir);
    defer common_dir.close();
    const rp = try common_dir.realpathAlloc(alloc, ".");
    return @as(?[]const u8, rp);
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

test "smart_background: project key unifies git worktrees with main repo" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Main repo root marker.
    try tmp.dir.makeDir("repo");
    try tmp.dir.makeDir("repo/.git");
    try tmp.dir.makePath("repo/a/b");

    // Worktree root with .git file pointing at the main repo's gitdir.
    try tmp.dir.makeDir("wt");
    try tmp.dir.makePath("wt/a/b");
    try tmp.dir.makePath("repo/.git/worktrees/wt1");

    const repo_root = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo_root);
    const repo_leaf = try tmp.dir.realpathAlloc(alloc, "repo/a/b");
    defer alloc.free(repo_leaf);
    const wt_root = try tmp.dir.realpathAlloc(alloc, "wt");
    defer alloc.free(wt_root);
    const wt_leaf = try tmp.dir.realpathAlloc(alloc, "wt/a/b");
    defer alloc.free(wt_leaf);

    const gitdir = try std.fs.path.join(alloc, &.{ repo_root, ".git", "worktrees", "wt1" });
    defer alloc.free(gitdir);

    // Write worktree .git file.
    {
        var f = try tmp.dir.createFile("wt/.git", .{});
        defer f.close();
        try f.writer().print("gitdir: {s}\n", .{gitdir});
    }
    // Write commondir so we can resolve to the common .git.
    {
        var f = try tmp.dir.createFile("repo/.git/worktrees/wt1/commondir", .{});
        defer f.close();
        try f.writer().writeAll("../..\n");
    }

    const k1 = try keyPathAlloc(alloc, .project, repo_leaf, true);
    defer alloc.free(k1);
    const k2 = try keyPathAlloc(alloc, .project, wt_leaf, true);
    defer alloc.free(k2);

    try testing.expectEqualStrings(repo_root, k1);
    try testing.expectEqualStrings(repo_root, k2);
}

test "smart_background: tintedBackground strength=0 returns base color" {
    const testing = std.testing;
    const base_bg: terminal.color.RGB = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    const base_fg: terminal.color.RGB = .{ .r = 0xF0, .g = 0xF0, .b = 0xF0 };
    const out = tintedBackground(1234, base_bg, base_fg, 0.0, 1.0);
    try testing.expectEqualDeep(base_bg, out);
}

test "smart_background: tintedBackground stays in a gentle saturation range" {
    const testing = std.testing;
    const base_bg: terminal.color.RGB = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
    const base_fg: terminal.color.RGB = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };

    const out = tintedBackground(42, base_bg, base_fg, 1.0, 1.0);
    const sat = rgbApproxSaturation(out);
    // Pastel-ish: keep well below "neon". This is intentionally conservative to
    // allow small rounding differences.
    try testing.expect(sat <= 0.55);
}

fn rgbApproxSaturation(rgb: terminal.color.RGB) f32 {
    // A simple, robust proxy for saturation in RGB: (max-min)/max.
    const rf: f32 = @floatFromInt(rgb.r);
    const gf: f32 = @floatFromInt(rgb.g);
    const bf: f32 = @floatFromInt(rgb.b);
    const maxv = @max(rf, @max(gf, bf));
    const minv = @min(rf, @min(gf, bf));
    if (maxv <= 0.0) return 0.0;
    return (maxv - minv) / maxv;
}
