const std = @import("std");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");
const full_grammars = @import("zhl_grammars_full");
const detect = @import("detect.zig");

pub const preview_bytes_max = 512 * 1024;
pub const rendered_bytes_max = 1024 * 1024;
pub const cache_entries_max = 4;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: [cache_entries_max]Entry = [_]Entry{.{}} ** cache_entries_max,
    clock: u64 = 0,

    const Entry = struct {
        id: [64]u8 = undefined,
        id_len: u8 = 0,
        markup: ?[]u8 = null,
        last_used: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Cache) void {
        self.clearAll();
        self.* = undefined;
    }

    pub fn clearAll(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        for (&self.entries) |*entry| self.clear(entry);
        self.mutex.unlock(self.io);
    }

    pub fn get(self: *Cache, id: []const u8, output: []u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.entries) |*entry| {
            const markup = entry.markup orelse continue;
            if (!std.mem.eql(u8, id, entry.id[0..entry.id_len])) continue;
            if (markup.len > output.len) return null;
            @memcpy(output[0..markup.len], markup);
            self.clock +%= 1;
            entry.last_used = self.clock;
            return output[0..markup.len];
        }
        return null;
    }

    pub fn put(self: *Cache, id: []const u8, markup: []const u8) void {
        if (id.len > 64 or markup.len > rendered_bytes_max) return;
        const owned = self.allocator.dupe(u8, markup) catch return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.entries) |*entry| {
            if (entry.markup != null and std.mem.eql(u8, id, entry.id[0..entry.id_len])) {
                std.crypto.secureZero(u8, owned);
                self.allocator.free(owned);
                return;
            }
        }

        // ponytail: four-entry linear LRU; add an index only if profiling shows churn.
        var victim = &self.entries[0];
        for (&self.entries) |*entry| {
            if (entry.markup == null) {
                victim = entry;
                break;
            }
            if (entry.last_used < victim.last_used) victim = entry;
        }
        self.clear(victim);
        @memcpy(victim.id[0..id.len], id);
        victim.id_len = @intCast(id.len);
        victim.markup = owned;
        self.clock +%= 1;
        victim.last_used = self.clock;
    }

    pub fn remove(self: *Cache, id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.entries) |*entry| {
            if (entry.markup != null and std.mem.eql(u8, id, entry.id[0..entry.id_len])) {
                self.clear(entry);
                return;
            }
        }
    }

    fn clear(self: *Cache, entry: *Entry) void {
        if (entry.markup) |markup| {
            std.crypto.secureZero(u8, markup);
            self.allocator.free(markup);
        }
        entry.* = .{};
    }
};

pub fn language(requested: []const u8, source: []const u8) []const u8 {
    if (!std.mem.eql(u8, requested, "auto")) {
        if (std.mem.eql(u8, requested, "text")) return "text";
        if (canonicalName(requested)) |canonical| return canonical;
        return "text";
    }
    const sample = source[0..@min(source.len, 4096)];
    if (detectLanguageHint(sample)) |detected| return detected;
    if (detect.strongLanguage(sample)) |detected| return detected;
    if (detect.language(sample)) |detected| return detected;
    if (detectSignature(sample)) |detected| return detected;
    return "text";
}

const Signature = struct { language_name: []const u8, marker: []const u8, line_prefix: bool = false };
const signatures = [_]Signature{
    .{ .language_name = "ada", .marker = "with Ada." },
    .{ .language_name = "dockerfile", .marker = "FROM ", .line_prefix = true },
    .{ .language_name = "diff", .marker = "diff --git " },
    .{ .language_name = "cmake", .marker = "cmake_minimum_required(" },
    .{ .language_name = "clojure", .marker = "(defn " },
    .{ .language_name = "coffeescript", .marker = "class App\n  constructor:" },
    .{ .language_name = "dart", .marker = "import 'package:" },
    .{ .language_name = "fish", .marker = "#!/usr/bin/env fish" },
    .{ .language_name = "gleam", .marker = "import gleam/" },
    .{ .language_name = "glsl", .marker = "#version " },
    .{ .language_name = "hcl", .marker = "terraform {" },
    .{ .language_name = "lua", .marker = "local function " },
    .{ .language_name = "makefile", .marker = ".PHONY:" },
    .{ .language_name = "mermaid", .marker = "sequenceDiagram" },
    .{ .language_name = "nix", .marker = "builtins." },
    .{ .language_name = "ocaml", .marker = "let rec " },
    .{ .language_name = "odin", .marker = ":: proc(" },
    .{ .language_name = "perl6", .marker = "use v6;" },
    .{ .language_name = "powershell", .marker = "Write-Host " },
    .{ .language_name = "protobuf", .marker = "syntax = \"proto" },
    .{ .language_name = "r", .marker = "<- function(" },
    .{ .language_name = "solidity", .marker = "pragma solidity" },
    .{ .language_name = "system-verilog", .marker = "endmodule" },
    .{ .language_name = "terraform", .marker = "resource \"" },
    .{ .language_name = "typst", .marker = "#set page(" },
    .{ .language_name = "vhdl", .marker = "library ieee;" },
    .{ .language_name = "wasm", .marker = "(module", .line_prefix = true },
    .{ .language_name = "wgsl", .marker = "@vertex" },
    .{ .language_name = "zsh", .marker = "#!/usr/bin/env zsh" },
};

fn detectSignature(source: []const u8) ?[]const u8 {
    for (signatures) |signature|
        if (if (signature.line_prefix)
            hasLinePrefix(source, signature.marker)
        else
            std.mem.indexOf(u8, source, signature.marker) != null) return signature.language_name;
    return null;
}

fn detectLanguageHint(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_count: u8 = 0;
    while (lines.next()) |raw_line| : (line_count += 1) {
        if (line_count == 5) break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "```"))
            if (canonicalToken(line[3..])) |detected| return detected;
        for ([_][]const u8{ "language:", "lang=" }) |marker| {
            const start = std.mem.indexOf(u8, line, marker) orelse continue;
            if (canonicalToken(line[start + marker.len ..])) |detected| return detected;
        }
    }
    return null;
}

fn canonicalToken(raw: []const u8) ?[]const u8 {
    const value = std.mem.trimStart(u8, raw, " \t");
    var end: usize = 0;
    while (end < value.len and (std.ascii.isAlphanumeric(value[end]) or
        std.mem.indexOfScalar(u8, "-_+#", value[end]) != null)) : (end += 1)
    {}
    return if (end == 0) null else canonicalName(value[0..end]);
}

pub fn render(source: []const u8, requested: []const u8, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    const selected = language(requested, source);
    if (std.mem.eql(u8, selected, "text")) {
        try zhl.renderers.renderHtmlLine(&writer, source, &.{});
        return output[0..writer.end];
    }
    const language_entry = full_grammars.find(selected) orelse return error.UnknownLanguage;
    const rendered_len = shard_renderers[language_entry.shard](
        language_entry.id,
        source.ptr,
        source.len,
        output.ptr,
        output.len,
    );
    if (rendered_len < 0) return error.HighlightFailed;
    return output[0..@intCast(rendered_len)];
}

fn canonicalName(name: []const u8) ?[]const u8 {
    if (full_grammars.find(name)) |language_entry| return language_entry.canonical;
    if (grammars.findByName(name)) |metadata|
        if (full_grammars.find(metadata.canonical)) |language_entry| return language_entry.canonical;
    return null;
}

const ShardRenderer = *const fn (u32, [*]const u8, usize, [*]u8, usize) callconv(.c) isize;
extern fn plop_zhl_render_0(u32, [*]const u8, usize, [*]u8, usize) callconv(.c) isize;
extern fn plop_zhl_render_1(u32, [*]const u8, usize, [*]u8, usize) callconv(.c) isize;
extern fn plop_zhl_render_2(u32, [*]const u8, usize, [*]u8, usize) callconv(.c) isize;
const shard_renderers = [_]ShardRenderer{
    &plop_zhl_render_0,
    &plop_zhl_render_1,
    &plop_zhl_render_2,
};

fn hasLinePrefix(source: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line|
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), prefix)) return true;
    return false;
}

test "auto-detects every supported grammar" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "#!/usr/bin/env bash\nset -euo pipefail\necho \"$HOME\"", .expected = "bash" },
        .{ .source = "#include <stdlib.h>\n\ntypedef struct { int x; } Item;", .expected = "c" },
        .{ .source = "#include <vector>\nstd::vector<int> values;", .expected = "cpp" },
        .{ .source = "using System;\nConsole.WriteLine(\"hello\");", .expected = "csharp" },
        .{ .source = ":root { --accent: blue; }\n.paste { color: var(--accent); }", .expected = "css" },
        .{ .source = "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"hi\") }", .expected = "go" },
        .{ .source = "<!doctype html><html></html>", .expected = "html" },
        .{ .source = "public static void main(String[] args) { System.out.println(\"hi\"); }", .expected = "java" },
        .{ .source = "function paste() { console.log('ok'); }", .expected = "javascript" },
        .{ .source = "export const App = () => <div className=\"paste\">hi</div>;", .expected = "jsx" },
        .{ .source = "{\"animal\":\"otter\"}", .expected = "json" },
        .{ .source = "fun main() { val animal = \"otter\"; println(animal) }", .expected = "kotlin" },
        .{ .source = "2026-07-30T19:04:11Z INFO request_id=otter status=201 duration_ms=0.42", .expected = "log" },
        .{ .source = "# Paste API\n\nUse [the endpoint](/api/pastes).", .expected = "markdown" },
        .{ .source = "<?php\nfunction paste() { echo 'hi'; }", .expected = "php" },
        .{ .source = "def plop():\n    return 1", .expected = "python" },
        .{ .source = "require 'json'\ndef paste\n  puts 'hi'\nend", .expected = "ruby" },
        .{ .source = "fn main() { let mut x = 1; println!(\"hi\"); }", .expected = "rust" },
        .{ .source = "SELECT body, expires_at FROM pastes WHERE id = 1;", .expected = "sql" },
        .{ .source = "import Foundation\nfunc greet() -> String { return \"hi\" }", .expected = "swift" },
        .{ .source = "[package]\nname = \"plop\"\nversion = \"1.0\"", .expected = "toml" },
        .{ .source = "interface Props { name: string }\nexport const App = (p: Props) => <div className=\"x\">{p.name}</div>;", .expected = "tsx" },
        .{ .source = "interface Paste { body: string; ttl: number }", .expected = "typescript" },
        .{ .source = "<?xml version=\"1.0\"?><paste><body>hi</body></paste>", .expected = "xml" },
        .{ .source = "name: plop\nfeatures:\n  - encrypted", .expected = "yaml" },
        .{ .source = "const std = @import(\"std\");", .expected = "zig" },
    };
    try std.testing.expectEqual(grammars.languages.len, cases.len);
    for (cases, grammars.languages) |case, metadata| {
        try std.testing.expectEqualStrings(metadata.canonical, case.expected);
        try std.testing.expectEqualStrings(case.expected, language("auto", case.source));
        try std.testing.expectEqualStrings(metadata.canonical, language(metadata.canonical, ""));
        var output: [4096]u8 = undefined;
        try std.testing.expect((try render(case.source, metadata.canonical, &output)).len > 0);
    }
    try std.testing.expectEqualStrings("javascript", language("js", ""));
    try std.testing.expectEqualStrings("yaml", language("yml", ""));
    try std.testing.expectEqualStrings("text", language("unknown", "key: value"));
}

test "autodetection resolves common ambiguities" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "typedef struct { int definition; } Item;", .expected = "c" },
        .{ .source = "[documentation](https://example.com)", .expected = "markdown" },
        .{ .source = "const value: string = items.map((item) => item.name);", .expected = "typescript" },
        .{ .source = "import { resolve } from 'node:path';\ntype WindowSnapshot = { width: number };\nconst snapshot: WindowSnapshot = resolveModule(moduleName);", .expected = "typescript" },
        .{ .source = "namespace app { const int value = 1; }", .expected = "cpp" },
        .{ .source = "with Ada.Text_IO; use Ada.Text_IO;\nprocedure Hello is\nbegin\nPut_Line(\"hello\");\nend Hello;", .expected = "ada" },
        .{ .source = "This definition: remains ordinary prose.", .expected = "text" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, language("auto", case.source));
}

test "multiline zig build command detects and renders as bash" {
    const source =
        \\zig build \
        \\  -Doptimize=ReleaseFast \
        \\  -Dtarget=x86_64-linux-gnu \
        \\  -Dcpu=x86_64_v3 \
        \\  -Dbrand-name="PikaOS Paste" \
        \\  -Dpage-title="PikaOS Paste" \
        \\  -Dsite-url="https://paste.pika-os.com" \
        \\  -Dlogo-file=assets/pika-logo.svg \
        \\  -Dfavicon-file=assets/pika-logo.svg
    ;
    try std.testing.expectEqualStrings("bash", language("auto", source));
    var output: [16 * 1024]u8 = undefined;
    try std.testing.expect((try render(source, "auto", &output)).len > 0);
}

test "licensed real-world fixtures cover every full zhl grammar" {
    const fixtures = @import("autodetect_fixtures").fixtures;
    try std.testing.expectEqual(full_grammars.languages.len, fixtures.len);
    const markup = try std.testing.allocator.alloc(u8, rendered_bytes_max);
    defer std.testing.allocator.free(markup);
    var failures: usize = 0;
    for (fixtures, full_grammars.languages) |fixture, grammar_entry| {
        try std.testing.expectEqualStrings(grammar_entry.canonical, fixture.grammar);
        try std.testing.expect(full_grammars.find(fixture.expected) != null);
        try std.testing.expect(fixture.provenance.len > 0);
        try std.testing.expect(fixture.license.len > 0);
        const actual = language("auto", fixture.source);
        if (!std.mem.eql(u8, fixture.expected, actual)) {
            std.debug.print("autodetect fixture {s}: expected {s}, found {s}\n", .{ fixture.grammar, fixture.expected, actual });
            failures += 1;
        }
        _ = render(fixture.source, fixture.grammar, markup) catch |err| {
            std.debug.print("render fixture {s}: {t}\n", .{ fixture.grammar, err });
            failures += 1;
            continue;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "autodetection covers extended zhl signatures" {
    try std.testing.expect(full_grammars.languages.len >= 200);
    for (signatures) |signature| try std.testing.expect(full_grammars.find(signature.language_name) != null);
}

test "every full zhl grammar resolves and renders" {
    var output: [4096]u8 = undefined;
    var hint: [128]u8 = undefined;
    for (full_grammars.languages) |language_entry| {
        try std.testing.expectEqualStrings(
            language_entry.canonical,
            language(language_entry.canonical, ""),
        );
        const hinted = try std.fmt.bufPrint(&hint, "// language: {s}", .{language_entry.canonical});
        try std.testing.expectEqualStrings(language_entry.canonical, language("auto", hinted));
        _ = try render("x", language_entry.canonical, &output);
    }
}

test "zhl rendering escapes HTML and preserves multiline state" {
    var output: [2048]u8 = undefined;
    const rendered = try render("const x = \"<&\";", "zig", &output);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zhl-keyword") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "&lt;&amp;") != null);
    const plain = try render("<&>\"'", "text", &output);
    try std.testing.expectEqualStrings("&lt;&amp;&gt;&quot;'", plain);
    const multiline = try render("/* start\nstill comment */", "zig", &output);
    try std.testing.expect(std.mem.count(u8, multiline, "zhl-operator") == 2);
    try std.testing.expect(std.mem.indexOf(u8, multiline, "still comment") != null);
    const crlf = try render("const a = 1;\r\nconst b = 2;", "zig", &output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, crlf, "\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, crlf, '\r') == null);
}

test "native log rendering escapes HTML" {
    var output: [4096]u8 = undefined;
    const rendered = try render("Jul 30 19:04:11 host systemd[4042]: Failed with <bad>", "log", &output);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zhl-keyword") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zhl-string") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "&lt;bad&gt;") != null);
}

test "highlight cache hits and evicts least recently used markup" {
    var cache = Cache.init(std.testing.allocator, std.testing.io);
    defer cache.deinit();
    var output: [32]u8 = undefined;

    cache.put("one", "first");
    cache.put("two", "second");
    cache.put("three", "third");
    cache.put("four", "fourth");
    try std.testing.expectEqualStrings("first", cache.get("one", &output).?);
    cache.put("five", "fifth");

    try std.testing.expect(cache.get("two", &output) == null);
    try std.testing.expectEqualStrings("first", cache.get("one", &output).?);
    try std.testing.expectEqualStrings("fifth", cache.get("five", &output).?);
    cache.remove("one");
    try std.testing.expect(cache.get("one", &output) == null);
}
