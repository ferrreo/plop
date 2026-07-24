const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const theme = b.option([]const u8, "theme", "Theme: neon or paper") orelse "neon";
    const icon = b.option([]const u8, "icon", "Icon: paw or spark") orelse "paw";
    const brand_name = b.option([]const u8, "brand-name", "Visible brand name") orelse "plop";
    const page_title = b.option([]const u8, "page-title", "HTML document title") orelse brand_name;
    const site_url = b.option([]const u8, "site-url", "Public origin for link preview metadata") orelse "http://127.0.0.1:8080";
    const meta_description = b.option([]const u8, "meta-description", "Link preview description") orelse
        "Encrypted, expiring text and image pastes.";
    if (!std.mem.eql(u8, theme, "neon") and !std.mem.eql(u8, theme, "paper"))
        @panic("-Dtheme must be neon or paper");
    if (!std.mem.eql(u8, icon, "paw") and !std.mem.eql(u8, icon, "spark"))
        @panic("-Dicon must be paw or spark");
    if (std.mem.indexOfAny(u8, brand_name, "<>&\"") != null or
        std.mem.indexOfAny(u8, page_title, "<>&\"") != null or
        std.mem.indexOfAny(u8, meta_description, "<>&\"") != null)
        @panic("branding text cannot contain <, >, &, or \"");
    if ((!std.mem.startsWith(u8, site_url, "https://") and !std.mem.startsWith(u8, site_url, "http://")) or
        std.mem.endsWith(u8, site_url, "/") or std.mem.indexOfAny(u8, site_url, "<>&\"") != null)
        @panic("-Dsite-url must be an http(s) origin without a trailing slash");
    const logo_file = b.option([]const u8, "logo-file", "Inline SVG logo file") orelse
        if (std.mem.eql(u8, icon, "spark")) "assets/spark.svg" else "assets/paw.svg";
    const favicon_file = b.option([]const u8, "favicon-file", "SVG, PNG, or ICO favicon file") orelse logo_file;
    const favicon_extension = std.fs.path.extension(favicon_file);
    const favicon_mime = if (std.mem.eql(u8, favicon_extension, ".svg"))
        "image/svg+xml"
    else if (std.mem.eql(u8, favicon_extension, ".png"))
        "image/png"
    else if (std.mem.eql(u8, favicon_extension, ".ico"))
        "image/x-icon"
    else
        @panic("-Dfavicon-file must end in .svg, .png, or .ico");

    const max_paste_bytes = b.option(
        usize,
        "max-paste-bytes",
        "Maximum decoded paste size (up to 16 MiB)",
    ) orelse 16 * 1024 * 1024;
    if (max_paste_bytes == 0 or max_paste_bytes > 16 * 1024 * 1024)
        @panic("-Dmax-paste-bytes must be between 1 and 16777216");
    const max_workers = b.option(u8, "max-workers", "Maximum Ploof workers (1..4)") orelse 2;
    if (max_workers == 0 or max_workers > 4)
        @panic("-Dmax-workers must be between 1 and 4");

    const options = b.addOptions();
    options.addOption([]const u8, "theme", theme);
    options.addOption([]const u8, "icon", icon);
    options.addOption([]const u8, "brand_name", brand_name);
    options.addOption([]const u8, "page_title", page_title);
    options.addOption([]const u8, "site_url", site_url);
    options.addOption([]const u8, "meta_description", meta_description);
    options.addOption([]const u8, "favicon_extension", favicon_extension);
    options.addOption([]const u8, "favicon_mime", favicon_mime);
    options.addOption(usize, "max_paste_bytes", max_paste_bytes);
    options.addOption(u8, "max_workers", max_workers);

    const ploof = b.dependency("ploof", .{}).module("ploof");
    const zhl_dep = b.dependency("zhl", .{ .target = target, .optimize = optimize, .langs = "full" });
    const zhl = zhl_dep.module("zhl");
    const zhl_grammars = zhl_dep.module("zhl_grammars");
    const sigbench = b.dependency("sigbench", .{ .target = target, .optimize = optimize }).module("sigbench");

    const zhlc = zhl_dep.artifact("zhlc");
    const generate_grammars = b.addSystemCommand(&.{
        "sh", "-c", "test -f src/grammars_ext/root.zig || ZHLC=\"$1\" sh tools/generate_grammars_ext.sh", "sh",
    });
    generate_grammars.addArtifactArg(zhlc);
    generate_grammars.setCwd(zhl_dep.path("."));
    const build_full_grammars = b.addSystemCommand(&.{ "sh", "tools/build_zhl_full.sh" });
    build_full_grammars.addDirectoryArg(zhl_dep.path("."));
    build_full_grammars.addArg(b.pathFromRoot("zig-out/zhl_full"));
    build_full_grammars.step.dependOn(&generate_grammars.step);
    const full_grammars = b.createModule(.{
        .root_source_file = b.path("zig-out/zhl_full/catalog.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zhl_shard_count = 3;
    var zhl_shards: [zhl_shard_count]*std.Build.Step.Compile = undefined;
    inline for (0..zhl_shard_count) |shard| {
        const shard_options = b.addOptions();
        shard_options.addOption(usize, "shard", shard);
        const selected = b.createModule(.{
            .root_source_file = b.path(b.fmt("zig-out/zhl_full/shard-{d}/root.zig", .{shard})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl },
                .{ .name = "zhl_grammars", .module = zhl_grammars },
            },
        });
        const shard_module = b.createModule(.{
            .root_source_file = b.path("src/zhl_shard.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl },
                .{ .name = "zhl_grammars_selected", .module = selected },
                .{ .name = "shard_options", .module = shard_options.createModule() },
            },
        });
        zhl_shards[shard] = b.addObject(.{
            .name = b.fmt("plop-zhl-{d}", .{shard}),
            .root_module = shard_module,
        });
        zhl_shards[shard].step.dependOn(&build_full_grammars.step);
        if (shard > 0) zhl_shards[shard].step.dependOn(&zhl_shards[shard - 1].step);
    }

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    app.addImport("ploof", ploof);
    app.addImport("ploof_testing", b.dependency("ploof", .{}).module("ploof_testing"));
    app.addImport("zhl", zhl);
    app.addImport("zhl_grammars", zhl_grammars);
    app.addImport("zhl_grammars_full", full_grammars);
    app.addAnonymousImport("brand_logo", .{ .root_source_file = b.path(logo_file) });
    app.addAnonymousImport("brand_favicon", .{ .root_source_file = b.path(favicon_file) });
    for (zhl_shards) |shard| app.addObject(shard);
    app.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "plop", .root_module = app });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run plop").dependOn(&run.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("ploof", ploof);
    tests_mod.addImport("ploof_testing", b.dependency("ploof", .{}).module("ploof_testing"));
    tests_mod.addImport("zhl", zhl);
    tests_mod.addImport("zhl_grammars", zhl_grammars);
    tests_mod.addImport("zhl_grammars_full", full_grammars);
    tests_mod.addImport("autodetect_fixtures", b.createModule(.{
        .root_source_file = b.path("tests/autodetect_fixtures.zig"),
    }));
    tests_mod.addAnonymousImport("brand_logo", .{ .root_source_file = b.path(logo_file) });
    tests_mod.addAnonymousImport("brand_favicon", .{ .root_source_file = b.path(favicon_file) });
    for (zhl_shards) |shard| tests_mod.addObject(shard);
    tests_mod.addOptions("build_options", options);
    const tests = b.addTest(.{ .root_module = tests_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const integration = b.addSystemCommand(&.{ "bash", "tests/integration.sh" });
    integration.addFileArg(exe.getEmittedBin());
    integration.addArg(b.fmt("{d}", .{max_paste_bytes}));
    integration.addArg(b.fmt("{d}", .{max_workers}));
    integration.addArg(site_url);
    b.step("integration-test", "Run live HTTP integration tests").dependOn(&integration.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    bench_mod.addImport("sigbench", sigbench);
    bench_mod.addImport("zhl", zhl);
    bench_mod.addImport("zhl_grammars", zhl_grammars);
    bench_mod.addImport("zhl_grammars_full", full_grammars);
    bench_mod.addAnonymousImport("autodetect_nushell_fixture", .{
        .root_source_file = b.path("tests/fixtures/autodetect/files/nushell.txt"),
    });
    for (zhl_shards) |shard| bench_mod.addObject(shard);
    const bench = b.addExecutable(.{ .name = "plop-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run sigbench benchmarks").dependOn(&run_bench.step);
}
