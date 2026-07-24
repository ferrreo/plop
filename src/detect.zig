const std = @import("std");
const model = @import("detect_profiles.zig");

const token_slots = 512;

pub fn strongLanguage(source: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "#!/")) {
        const first_line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
        if (std.mem.indexOf(u8, first_line, "zsh") != null) return "zsh";
        if (std.mem.indexOf(u8, first_line, "fish") != null) return "fish";
        if (std.mem.indexOf(u8, first_line, "Rscript") != null) return "r";
        if (std.mem.indexOf(u8, first_line, "bash") != null or std.mem.endsWith(u8, first_line, "/sh")) return "bash";
    }
    if (hasLinePrefix(source, "zig build ") and std.mem.indexOf(u8, source, "-Doptimize=") != null) return "bash";
    if (hasLinePrefix(source, "`pragma protect")) return "verilog";
    if (hasLinePrefix(source, "C4Context") or hasLinePrefix(source, "sequenceDiagram") or
        hasLinePrefix(source, "flowchart ") or hasLinePrefix(source, "graph ")) return "mermaid";
    if (std.mem.indexOf(u8, source, "```nix") != null) return "markdown-nix";
    if (hasLinePrefix(source, "job \"") or hasLinePrefix(source, "group \"") and
        std.mem.indexOf(u8, source, "task \"") != null) return "hcl";
    if (hasLinePrefix(source, "terraform {") or std.mem.indexOf(u8, source, "required_providers {") != null) return "terraform";
    if (containsIgnoreCase(source, "create or replace package")) return "plsql";
    if (std.mem.indexOf(u8, source, "Object subclass: #") != null or
        std.mem.indexOf(u8, source, "instanceVariableNames:") != null) return "smalltalk";
    if (hasLinePrefix(source, "$ ") and (std.mem.indexOf(u8, source, "\n...") != null or
        std.mem.indexOf(u8, source, "\n==>") != null)) return "shellsession";
    if (hasLinePrefix(source, "RewriteCond ") or hasLinePrefix(source, "RewriteRule ") or
        hasLinePrefix(source, "ServerSignature ")) return "apache";
    if (std.mem.indexOf(u8, source, "Shader \"") != null and std.mem.indexOf(u8, source, "SubShader") != null) return "shaderlab";
    if (std.mem.indexOf(u8, source, "PS_MAIN ") != null or std.mem.indexOf(u8, source, "RES(Tex2D") != null) return "fsl";
    if (hasLinePrefix(source, "shader_type ") or std.mem.indexOf(u8, source, "hint_black_albedo") != null) return "gdshader";
    if (std.mem.indexOf(u8, source, "SV_Target") != null or
        std.mem.indexOf(u8, source, "sampler2D ") != null and std.mem.indexOf(u8, source, "half3 ") != null or
        hasLinePrefix(source, "cbuffer ")) return "hlsl";
    if (std.mem.indexOf(u8, source, "#include <") != null or std.mem.indexOf(u8, source, "typedef struct") != null) {
        if (std.mem.indexOf(u8, source, "std::") != null or std.mem.indexOf(u8, source, "namespace ") != null or
            std.mem.indexOf(u8, source, "template<") != null) return "cpp";
        return "c";
    }
    if (hasLineWith(source, "namespace ", "{") and std.mem.indexOf(u8, source, "const int ") != null) return "cpp";
    if (std.mem.indexOf(u8, source, "<localization>") != null and std.mem.indexOf(u8, source, "<trans-unit ") != null) return "potx";
    if (std.mem.indexOf(u8, source, "<xsl:stylesheet") != null or std.mem.indexOf(u8, source, "<xsl:transform") != null) return "xsl";
    if (std.mem.startsWith(u8, trimmed, "<?xml") or std.mem.startsWith(u8, trimmed, "\xef\xbb\xbf<?xml")) return "xml";
    if (std.mem.startsWith(u8, trimmed, "<!doctype html") or std.mem.startsWith(u8, trimmed, "<html")) return "html";
    if (std.mem.startsWith(u8, trimmed, "{") and std.mem.indexOf(u8, source, "\":") != null or
        std.mem.startsWith(u8, trimmed, "[") and std.mem.indexOf(u8, source, ",") != null) return "json";
    if (std.mem.startsWith(u8, trimmed, "[package]") and std.mem.indexOf(u8, source, "name = ") != null) return "toml";
    if (std.mem.indexOf(u8, source, ":root {") != null or
        std.mem.indexOf(u8, source, ".paste {") != null) return "css";

    const has_types = hasLinePrefix(source, "interface ") or hasLinePrefix(source, "export interface ") or
        hasLinePrefix(source, "type ") or hasLinePrefix(source, "export type ") or
        std.mem.indexOf(u8, source, ": string") != null or std.mem.indexOf(u8, source, ": number") != null or
        std.mem.indexOf(u8, source, ": boolean") != null or std.mem.indexOf(u8, source, "import type ") != null or
        std.mem.indexOf(u8, source, "public abstract ") != null;
    const has_jsx = std.mem.indexOf(u8, source, "className=") != null or
        std.mem.indexOf(u8, source, "=> <") != null or std.mem.indexOf(u8, source, "return <") != null;
    if (has_types and has_jsx) return "tsx";
    if (has_types and (std.mem.indexOf(u8, source, " from '") != null or
        std.mem.indexOf(u8, source, " from \"") != null or std.mem.indexOf(u8, source, ".map(") != null)) return "typescript";
    if (hasLinePrefix(source, "interface ") and std.mem.indexOf(u8, source, ": string") != null) return "typescript";
    if (std.mem.indexOf(u8, source, "public static void main(") != null or
        std.mem.indexOf(u8, source, "System.out.println(") != null) return "java";
    if (hasLinePrefix(source, "import Foundation") and std.mem.indexOf(u8, source, "func ") != null) return "swift";
    if (hasLinePrefix(source, "fun ") and std.mem.indexOf(u8, source, "println(") != null) return "kotlin";
    if (std.mem.indexOf(u8, source, "var util = require(") != null or
        std.mem.indexOf(u8, source, "module.exports") != null or
        std.mem.indexOf(u8, source, "console.log(") != null) return "javascript";
    if (std.mem.indexOf(u8, source, "](") != null and
        (std.mem.startsWith(u8, trimmed, "[") or std.mem.startsWith(u8, trimmed, "---\n") or
            markdownHeading(trimmed)) or
        std.mem.startsWith(u8, trimmed, "---\n") and std.mem.indexOf(u8, source, "\n# ") != null) return "markdown";
    if (std.mem.indexOf(u8, source, "<- function(") != null) return "r";
    if (std.mem.indexOf(u8, source, "[DEFAULT]") != null and std.mem.indexOf(u8, source, "=") != null) return "ini";
    if (hasLinePrefix(source, "production:") and hasLinePrefix(source, "adapter:")) return "yaml";
    if (source.len <= 512 and yamlMappings(source) >= 2 and hasLinePrefix(source, "- ")) return "yaml";
    if (hasLinePrefix(source, "CREATE TABLE ") and (containsIgnoreCase(source, "varchar2") or
        containsIgnoreCase(source, "grant create"))) return "sql";
    if (containsIgnoreCase(source, "create keyspace ") or containsIgnoreCase(source, "allow filtering")) return "cql";
    if (hasLinePrefix(source, "global class ") and std.mem.indexOf(u8, source, "List<") != null) return "apex";
    if (containsIgnoreCase(source, "select ") and containsIgnoreCase(source, " from ")) return "sql";
    if (hasLinePrefix(source, "@public") and std.mem.indexOf(u8, source, "uint256") != null) return "vyper";
    if (hasLinePrefix(source, "from .") and hasLinePrefix(source, "class ") and hasLinePrefix(source, "    def ")) return "python";
    if (hasLinePrefix(source, "def ") and std.mem.indexOf(u8, source, "):") != null) return "python";
    if (hasLinePrefix(source, "require '") and hasLinePrefix(source, "def ") and hasLinePrefix(source, "end")) return "ruby";
    if (std.mem.indexOf(u8, source, "fn main(") != null and
        (std.mem.indexOf(u8, source, "let mut ") != null or std.mem.indexOf(u8, source, "println!(") != null)) return "rust";
    if (hasUpperAssignments(source, 3)) return "dotenv";
    return null;
}

pub fn language(source: []const u8) ?[]const u8 {
    var set = TokenSet{};
    var index: usize = 0;
    while (index < source.len) {
        if (std.ascii.isAlphabetic(source[index]) or source[index] == '_') {
            const start = index;
            index += 1;
            while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '_')) : (index += 1) {}
            if (index - start >= 2) set.put(hash(source[start..index]));
            continue;
        }
        if (!std.ascii.isWhitespace(source[index]) and !std.ascii.isAlphanumeric(source[index])) {
            const start = index;
            index += 1;
            while (index < source.len and index - start < 3 and
                !std.ascii.isWhitespace(source[index]) and
                !std.ascii.isAlphanumeric(source[index]) and source[index] != '_') : (index += 1)
            {}
            set.put(hash(source[start..index]));
            continue;
        }
        index += 1;
    }

    var best: ?[]const u8 = null;
    var best_score: u16 = 0;
    var best_matches: u8 = 0;
    inline for (model.shards) |profiles| {
        for (profiles) |profile| {
            var score: u16 = 0;
            var matches: u8 = 0;
            for (profile.tokens) |token| {
                if (!set.has(token.hash)) continue;
                score +|= token.weight;
                matches += 1;
            }
            if (matches >= 2 and score > best_score) {
                best = profile.language;
                best_score = score;
                best_matches = matches;
            }
        }
    }
    return if (best_matches >= 2 and best_score >= 80) best else null;
}

const TokenSet = struct {
    slots: [token_slots]u64 = [_]u64{0} ** token_slots,

    fn put(self: *TokenSet, raw_hash: u64) void {
        const value = if (raw_hash == 0) 1 else raw_hash;
        var slot: usize = @intCast(value & (token_slots - 1));
        for (0..token_slots) |_| {
            if (self.slots[slot] == value) return;
            if (self.slots[slot] == 0) {
                self.slots[slot] = value;
                return;
            }
            slot = (slot + 1) & (token_slots - 1);
        }
    }

    fn has(self: *const TokenSet, raw_hash: u64) bool {
        const value = if (raw_hash == 0) 1 else raw_hash;
        var slot: usize = @intCast(value & (token_slots - 1));
        for (0..token_slots) |_| {
            if (self.slots[slot] == 0) return false;
            if (self.slots[slot] == value) return true;
            slot = (slot + 1) & (token_slots - 1);
        }
        return false;
    }
};

fn hash(token: []const u8) u64 {
    var value: u64 = 0xcbf29ce484222325;
    for (token) |byte| {
        value ^= std.ascii.toLower(byte);
        value *%= 0x100000001b3;
    }
    return value;
}

fn hasLinePrefix(source: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line|
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), prefix)) return true;
    return false;
}

fn hasLineWith(source: []const u8, prefix: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, prefix) and std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

fn markdownHeading(source: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    const first = source[0..end];
    return std.mem.startsWith(u8, first, "# ") and std.mem.indexOf(u8, first, "://") == null;
}

fn containsIgnoreCase(source: []const u8, needle: []const u8) bool {
    if (needle.len > source.len) return false;
    for (0..source.len - needle.len + 1) |start|
        if (std.ascii.eqlIgnoreCase(source[start..][0..needle.len], needle)) return true;
    return false;
}

fn hasUpperAssignments(source: []const u8, required: u8) bool {
    if (std.mem.indexOf(u8, source, "\t") != null or std.mem.indexOf(u8, source, ";\n") != null or
        std.mem.indexOf(u8, source, ".include ") != null or std.mem.indexOf(u8, source, "$(") != null) return false;
    var count: u8 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (equals == 0) continue;
        var valid = true;
        for (line[0..equals]) |byte| valid = valid and (std.ascii.isUpper(byte) or std.ascii.isDigit(byte) or byte == '_');
        if (valid) count += 1;
        if (count >= required) return true;
    }
    return false;
}

fn yamlMappings(source: []const u8) u8 {
    var count: u8 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (colon > 0 and (colon + 1 == line.len or line[colon + 1] == ' ')) count += 1;
    }
    return count;
}

test "token profiles require meaningful source evidence" {
    try std.testing.expectEqualStrings("typescript", strongLanguage(
        "import { resolve } from 'node:path';\ntype WindowSnapshot = { width: number };\nconst snapshot: WindowSnapshot = resolveModule(moduleName);",
    ).?);
    try std.testing.expect(language("ordinary prose about a module and its documentation") == null);
}
