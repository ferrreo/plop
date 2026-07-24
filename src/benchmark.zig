const std = @import("std");
const sigbench = @import("sigbench");
const highlight = @import("highlight.zig");
const store_module = @import("store.zig");

const source =
    \\const std = @import("std");
    \\pub fn main() !void {
    \\    const message = "otter-vole-tiger";
    \\    std.debug.print("{s}\\n", .{message});
    \\}
;
const large_source = source ** 512;
const c_source =
    \\#include <stdint.h>
    \\typedef struct { uint64_t value; const char *name; } Paste;
    \\static uint64_t checksum(const Paste *paste) { return paste->value ^ 0x5a5a5a5aU; }
;
const typescript_source =
    \\import { resolve } from "node:path";
    \\type WindowSnapshot = { width: number };
    \\const snapshot: WindowSnapshot = resolveModule(moduleName);
;
const nushell_source = @embedFile("autodetect_nushell_fixture");
const large_c_source = c_source ** 256;
const store_id = "bench-store-paste";
const store_file = store_id ++ ".plop";
const sweep_entries = 64;
const payload_64k = [_]u8{0x5a} ** (64 * 1024);
var benchmark_store: store_module.Store = undefined;
var benchmark_cache: highlight.Cache = undefined;

fn highlightZig(b: *sigbench.Bencher) !void {
    var output: [32 * 1024]u8 = undefined;
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        const rendered = try highlight.render(source, "zig", &output);
        std.mem.doNotOptimizeAway(rendered.ptr);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn highlightLargeZig(b: *sigbench.Bencher) !void {
    var output: [highlight.rendered_bytes_max]u8 = undefined;
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        const rendered = try highlight.render(large_source, "zig", &output);
        std.mem.doNotOptimizeAway(rendered.ptr);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn highlightLargeC(b: *sigbench.Bencher) !void {
    var output: [highlight.rendered_bytes_max]u8 = undefined;
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        const rendered = try highlight.render(large_c_source, "c", &output);
        std.mem.doNotOptimizeAway(rendered.ptr);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn cachedHighlight(b: *sigbench.Bencher) !void {
    var output: [32 * 1024]u8 = undefined;
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        const rendered = benchmark_cache.get("bench-cache-paste", &output) orelse return error.CacheMiss;
        std.mem.doNotOptimizeAway(rendered[rendered.len - 1]);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn detectStructuralLanguage(b: *sigbench.Bencher) void {
    const started = sigbench.nowNs();
    for (0..b.iterations) |_|
        std.mem.doNotOptimizeAway(highlight.language("auto", c_source).ptr);
    b.finishCustom(sigbench.nowNs() - started);
}

fn detectTypeScript(b: *sigbench.Bencher) void {
    const started = sigbench.nowNs();
    for (0..b.iterations) |_|
        std.mem.doNotOptimizeAway(highlight.language("auto", typescript_source).ptr);
    b.finishCustom(sigbench.nowNs() - started);
}

fn detectTokenProfile(b: *sigbench.Bencher) void {
    const started = sigbench.nowNs();
    for (0..b.iterations) |_|
        std.mem.doNotOptimizeAway(highlight.language("auto", nushell_source).ptr);
    b.finishCustom(sigbench.nowNs() - started);
}

fn encrypt64K(b: *sigbench.Bencher) void {
    const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    var input: [64 * 1024]u8 = [_]u8{0x5a} ** (64 * 1024);
    var output: [input.len]u8 = undefined;
    var nonce: [Aead.nonce_length]u8 = [_]u8{0x23} ** Aead.nonce_length;
    const key = [_]u8{0x42} ** Aead.key_length;
    const started = sigbench.nowNs();
    for (0..b.iterations) |iteration| {
        var tag: [Aead.tag_length]u8 = undefined;
        nonce[0] = @truncate(iteration);
        Aead.encrypt(&output, &tag, &input, "PLOP", nonce, key);
        std.mem.doNotOptimizeAway(&tag);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn base64ImagePreview(b: *sigbench.Bencher) void {
    var input: [512 * 1024]u8 = [_]u8{0x7b} ** (512 * 1024);
    var output: [std.base64.standard.Encoder.calcSize(input.len)]u8 = undefined;
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        const encoded = std.base64.standard.Encoder.encode(&output, &input);
        std.mem.doNotOptimizeAway(encoded.ptr);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn storeWrite64K(b: *sigbench.Bencher) !void {
    benchmark_store.dir.deleteFile(benchmark_store.io, store_file) catch {};
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        try benchmark_store.put(store_id, .{ .content = &payload_64k }, 1);
        try benchmark_store.dir.deleteFile(benchmark_store.io, store_file);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn storeRead64K(b: *sigbench.Bencher) !void {
    benchmark_store.dir.deleteFile(benchmark_store.io, store_file) catch {};
    try benchmark_store.put(store_id, .{ .content = &payload_64k }, 1);
    defer benchmark_store.dir.deleteFile(benchmark_store.io, store_file) catch {};
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        var paste = try benchmark_store.get(store_id, "", 1);
        std.mem.doNotOptimizeAway(paste.content.ptr);
        paste.deinit(benchmark_store.allocator);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

fn sweepExpiryHeaders(b: *sigbench.Bencher) !void {
    const started = sigbench.nowNs();
    for (0..b.iterations) |_| {
        const stats = try benchmark_store.sweepExpired(1);
        std.mem.doNotOptimizeAway(stats.scanned);
    }
    b.finishCustom(sigbench.nowNs() - started);
}

pub const benchmarks = sigbench.group("plop", .{
    sigbench.benchWithThroughput("zhl-zig", "server-side Zig highlight", .{ .bytes = source.len }, highlightZig),
    sigbench.benchWithThroughput("zhl-zig-large", "server-side Zig highlight, large", .{ .bytes = large_source.len }, highlightLargeZig),
    sigbench.benchWithThroughput("zhl-c-large", "server-side C highlight, large", .{ .bytes = large_c_source.len }, highlightLargeC),
    sigbench.benchWithThroughput("highlight-cache-hit", "highlight cache hit", .{ .bytes = source.len }, cachedHighlight),
    sigbench.benchWithThroughput("language-autodetect-structural", "language auto-detection, structural", .{ .bytes = c_source.len }, detectStructuralLanguage),
    sigbench.benchWithThroughput("language-autodetect-typescript", "language auto-detection, TypeScript regression", .{ .bytes = typescript_source.len }, detectTypeScript),
    sigbench.benchWithThroughput("language-autodetect-profile", "language auto-detection, full token profile", .{ .bytes = nushell_source.len }, detectTokenProfile),
    sigbench.benchWithThroughput("xchacha-64k", "XChaCha20-Poly1305 64 KiB", .{ .bytes = 64 * 1024 }, encrypt64K),
    sigbench.benchWithThroughput("base64-512k", "image preview base64", .{ .bytes = 512 * 1024 }, base64ImagePreview),
    sigbench.benchWithThroughput("store-write-64k", "encrypted local write", .{ .bytes = 64 * 1024 }, storeWrite64K),
    sigbench.benchWithThroughput("store-read-64k", "encrypted local read", .{ .bytes = 64 * 1024 }, storeRead64K),
    sigbench.benchWithThroughput("expiry-sweep", "encrypted expiry header sweep", .{ .elements = sweep_entries }, sweepExpiryHeaders),
});

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, highlight.language("auto", typescript_source), "typescript")) return error.TypeScriptDetectionRegression;
    if (!std.mem.eql(u8, highlight.language("auto", nushell_source), "nushell")) return error.TokenProfileDetectionRegression;
    const path = ".zig-cache/plop-bench";
    try std.Io.Dir.cwd().createDirPath(init.io, path);
    const directory = try std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true });
    benchmark_store = .{
        .allocator = init.gpa,
        .io = init.io,
        .dir = directory,
        .key = [_]u8{0x42} ** 32,
        .max_bytes = payload_64k.len,
    };
    defer benchmark_store.dir.close(init.io);
    benchmark_cache = .init(init.gpa, init.io);
    defer benchmark_cache.deinit();
    var rendered_buffer: [32 * 1024]u8 = undefined;
    benchmark_cache.put("bench-cache-paste", try highlight.render(source, "zig", &rendered_buffer));
    for (0..sweep_entries) |index| {
        var id_buffer: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "sweep-{c}{c}", .{
            @as(u8, 'a') + @as(u8, @intCast(index / 26)),
            @as(u8, 'a') + @as(u8, @intCast(index % 26)),
        });
        var file_buffer: [80]u8 = undefined;
        const file = try std.fmt.bufPrint(&file_buffer, "{s}.plop", .{id});
        benchmark_store.dir.deleteFile(init.io, file) catch {};
        try benchmark_store.put(id, .{ .content = "x" }, 1);
    }
    try sigbench.run(init, &.{benchmarks}, .{});
}
