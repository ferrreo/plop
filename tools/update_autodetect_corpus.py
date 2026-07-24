#!/usr/bin/env python3
"""Refresh plop's licensed autodetection corpus and compact token profiles."""

from __future__ import annotations

import collections
import math
import pathlib
import re
import shutil
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
NAMES = (ROOT / "zig-out/zhl_full/names").read_text().splitlines()
OUT = ROOT / "tests/fixtures/autodetect"

ALIASES = {
    "bat": "batch", "be": "berry", "cdc": "cadence", "clj": "clojure",
    "cmd": "batch", "docker": "dockerfile", "gd": "gdscript", "kql": "kusto",
    "asm-x86_64": "x86_64", "js-regexp": "regexp", "lisp": "common-lisp", "make": "makefile",
    "mbt": "moonbit", "mbti": "moonbit", "mipsasm": "mips",
    "mmd": "mermaid", "nu": "nushell", "perl6": "raku", "pot": "po",
    "proto": "protobuf", "ps": "powershell", "ps1": "powershell", "ql": "codeql",
}

LINGUIST_NAMES = {
    "1c-query": "1C Enterprise", "actionscript-3": "ActionScript", "apache": "ApacheConf", "c": "C",
    "asm": "Assembly", "bash": "Shell", "batch": "Batchfile", "berry": "Berry",
    "cpp": "C++", "csharp": "C#",
    "coq": "Rocq Prover", "desktop": "desktop", "dream-maker": "DM",
    "ftl": "FreeMarker", "gdresource": "Godot Resource", "ignore": "Ignore List",
    "kts": "Gradle Kotlin DSL", "lisp": "Common Lisp", "moonbit": "MoonBit", "nar": "Nasal",
    "perl6": "Raku", "protobuf": "Protocol Buffer", "properties": "Java Properties", "qmldir": "QML",
    "reg": "Windows Registry Entries", "rosmsg": "ROS Interface",
    "regexp": "Regular Expression", "shellsession": "ShellSession", "system-verilog": "SystemVerilog",
    "talonscript": "Talon", "typespec": "TypeSpec", "vb": "Visual Basic .NET",
    "terraform": "HCL", "wasm": "WebAssembly", "wit": "WebAssembly Interface Type", "wolfram": "Wolfram Language",
    "xsl": "XSLT", "zsh": "Shell",
}

LINGUIST_FILES = {
    "hcl": "samples/HCL/example.nomad",
    "javascript": "samples/JavaScript/http.js",
    "python": "samples/Python/flask-view.py",
    "sql": "samples/SQL/create_stuff.sql",
    "yaml": "samples/YAML/database.yml.mysql",
}

# Valid, project-authored holdouts for syntaxes absent from Linguist or where its
# language bucket merges dialects that zhl exposes separately.
AUTHORED = {
    "ada": ("with Ada.Text_IO; use Ada.Text_IO;\nprocedure Sync is begin Put_Line(\"ready\"); end Sync;",
            "with Ada.Containers.Vectors;\nprocedure Queue_Work is begin null; end Queue_Work;"),
    "angular-expression": ("account?.owner?.name | uppercase", "items | filter:query | orderBy:'createdAt'"),
    "angular-let-declaration": ("@let total = cart.items.length;\n@let ready = total > 0;", "@let user = profile.user;"),
    "angular-template": ("<button (click)=\"save()\" [disabled]=\"form.invalid\">{{ label }}</button>",
                         "<li *ngFor=\"let item of items; trackBy: trackItem\">{{ item.name }}</li>"),
    "ara": ("namespace App\\Jobs;\nasync function sync(User $user): void { await queue($user); }",
            "namespace App\\Http;\nfinal class Health { public fn check(): bool { return true; } }"),
    "arm": (".syntax unified\n.global add_values\nadd_values:\n    add r0, r0, r1\n    bx lr",
            ".thumb\n.global reset_handler\nreset_handler:\n    ldr r0, =stack_top\n    bx r0"),
    "asm-x86_64": ("global _start\nsection .text\n_start:\n    mov rax, 60\n    xor rdi, rdi\n    syscall",
                   "section .text\nglobal copy_word\ncopy_word:\n    mov rax, [rsi]\n    mov [rdi], rax\n    ret"),
    "beancount": ("option \"title\" \"Household\"\n2026-01-01 open Assets:Bank:Checking USD\n2026-01-02 * \"Market\" \"Food\"\n  Expenses:Food  42.50 USD\n  Assets:Bank:Checking",
                  "2026-01-01 open Income:Salary USD\n2026-01-31 * \"Employer\" \"Payroll\"\n  Assets:Bank:Checking  2500 USD\n  Income:Salary"),
    "bird": ("router id 192.0.2.1;\nprotocol bgp upstream { local as 64512; neighbor 198.51.100.1 as 64500; import all; export none; }",
             "protocol device {}\nprotocol kernel { ipv4 { import all; export all; }; learn; }"),
    "bird2": ("protocol bgp edge { ipv6 { import filter accept_routes; export all; }; local as 64512; neighbor 2001:db8::1 as 64500; }",
              "protocol static routes_v4 { ipv4; route 192.0.2.0/24 blackhole; }"),
    "dax": ("Revenue YTD := TOTALYTD(SUM(Sales[Revenue]), 'Date'[Date])\nMargin := DIVIDE([Revenue] - [Cost], [Revenue])",
            "Active Customers := CALCULATE(DISTINCTCOUNT(Sales[CustomerId]), Sales[Status] = \"Active\")"),
    "es-tag-xml": ("const template = xml`<service name=\"${name}\"><port>${port}</port></service>`;",
                   "export const feed = html`<article data-id=\"${item.id}\">${item.title}</article>`;"),
    "fortran-fixed-form": ("      PROGRAM REPORT\n      INTEGER I\n      DO 10 I = 1, 3\n         PRINT *, I\n   10 CONTINUE\n      END",
                           "      SUBROUTINE SCALE(A,N)\n      REAL A(N)\n      RETURN\n      END"),
    "fortran-free-form": ("program report\n  implicit none\n  integer :: i\n  do i = 1, 3\n    print *, i\n  end do\nend program report",
                          "module metrics\ncontains\n  real function average(values)\n    real :: values(:)\n    average = sum(values) / size(values)\n  end function\nend module"),
    "fsl": ("STRUCT(Data)\n{ DATA(float4, Position, POSITION); };\nVS_MAIN VSOutput main(VSInput input) { return output; }",
            "RES(Tex2D(float4), sourceTexture, UPDATE_FREQ_NONE, t0);\nPS_MAIN float4 main(FSInput input) : SV_Target { return Sample(sourceTexture, input.uv); }"),
    "git-rebase": ("pick a1b2c3d add encrypted store\nreword d4e5f6a document API\nsquash 123abcd fix tests",
                   "pick 9a8b7c6 add cache\nfixup 5d4e3f2 correct eviction"),
    "haxe": ("package app;\nclass Main { static function main() { final server = new Server(); server.listen(8080); } }",
             "typedef Paste = { final id:String; final expiresAt:Date; }\nclass Store { public function get(id:String):Null<Paste> return null; }"),
    "hjson": ("{\n  # deployment defaults\n  host: localhost\n  ports: [8080, 8081]\n  enabled: true\n}",
             "{\n  service: paste\n  ttlDays: 7\n  themes: [dark, light]\n}"),
    "jssm": ("machine: Upload;\nUpload 'select' -> Reading;\nReading 'success' -> Stored;\nReading 'failure' -> Error;",
             "machine: Worker;\nIdle 'job' -> Running;\nRunning 'done' -> Idle;"),
    "jsx": ("export function PasteCard({ paste }) { return <article className=\"paste\"><code>{paste.body}</code></article>; }",
            "const Status = ({ ready }) => <span className={ready ? 'ready' : 'waiting'}>{ready ? 'Ready' : 'Waiting'}</span>;"),
    "llvm": ("define i32 @add(i32 %a, i32 %b) {\nentry:\n  %sum = add i32 %a, %b\n  ret i32 %sum\n}",
             "declare i32 @puts(ptr)\ndefine i32 @main() {\nentry:\n  %result = call i32 @puts(ptr @message)\n  ret i32 0\n}"),
    "log": ("2026-07-24T18:20:01Z INFO request_id=otter status=201 duration_ms=0.42\n2026-07-24T18:20:02Z WARN cache_miss paste=lynx-skunk-koala",
            "2026-07-24 18:21:04 ERROR worker=2 message=\"store unavailable\"\n2026-07-24 18:21:05 INFO worker=2 message=\"recovered\""),
    "logo": ("to polygon :sides :length\n  repeat :sides [ forward :length right 360 / :sides ]\nend",
             "to spiral :size\n  if :size > 100 [stop]\n  forward :size right 91\n  spiral :size + 2\nend"),
    "markdown-nix": ("# Package\n\nThis module provides the development environment.\n\nOptions are documented below.\n\n```nix\n{ pkgs, ... }: { environment.systemPackages = [ pkgs.zig ]; }\n```",
                     "## Development shell\n\nThe shell contains compiler and source-control tools.\n\nUse it for local builds.\n\n```nix\npkgs.mkShell { packages = with pkgs; [ zig git ]; }\n```"),
    "mips": (".text\n.globl sum\nsum:\n    addu $v0, $a0, $a1\n    jr $ra\n    nop",
             ".data\nmessage: .asciiz \"ready\"\n.text\nmain:\n    li $v0, 4\n    syscall"),
    "narrat": ("main:\n  talk player \"The relay is online.\"\n  choice:\n    \"Continue\":\n      jump dashboard",
               "dashboard:\n  set $visits (add $visits 1)\n  notify \"Welcome back\"\n  return"),
    "po": ("msgid \"Create encrypted paste\"\nmsgstr \"Créer un collage chiffré\"\n\nmsgid \"Expires after\"\nmsgstr \"Expire après\"",
           "msgctxt \"button\"\nmsgid \"Save\"\nmsgstr \"Speichern\""),
    "potx": ("<?xml version=\"1.0\"?><localization><trans-unit id=\"save\"><source>Save</source><target/></trans-unit></localization>",
             "<?xml version=\"1.0\"?><localization><trans-unit id=\"cancel\"><source>Cancel</source><target/></trans-unit></localization>"),
    "qmldir": ("module Paste.Ui\nplugin pasteui\ntypeinfo plugins.qmltypes\nPasteView 1.0 PasteView.qml",
               "module Relay.Controls\nsingleton Theme 1.0 Theme.qml\nButton 1.0 Button.qml"),
    "qss": ("QPushButton#submit { background-color: #2563eb; border-radius: 4px; }\nQLineEdit:focus { border: 1px solid #60a5fa; }",
            "QWidget#sidebar { background: #111827; }\nQLabel[status=\"error\"] { color: #ef4444; }"),
    "rel": ("def active_users = relation { user | user.enabled and user.last_seen > @days_ago(30) };\n@inspect active_users",
            "def visible_pastes = relation { paste | not paste.deleted and paste.expires_at > @now() };"),
    "riscv": (".section .text\n.globl add_values\nadd_values:\n    add a0, a0, a1\n    ret",
              ".section .text\n_start:\n    li a7, 93\n    li a0, 0\n    ecall"),
    "sassdoc": ("/// Creates a responsive spacing value.\n/// @param {Number} $step - Scale position.\n/// @return {Length}\n@function spacing($step) { @return $step * 0.25rem; }",
                "/// Primary action color.\n/// @type Color\n$action-color: #2563eb !default;"),
    "solidity": ("pragma solidity ^0.8.24;\ncontract Vault { mapping(address => uint256) public balance; function deposit() external payable { balance[msg.sender] += msg.value; } }",
                 "pragma solidity ^0.8.24;\ncontract Counter { uint256 public value; function increment() external { value++; } }"),
    "splunk": ("index=web status>=500 | stats count by host, status | sort -count",
               "index=api action=create | timechart span=5m p95(duration_ms) by route"),
    "systemd": ("[Unit]\nDescription=Encrypted paste relay\nAfter=network.target\n[Service]\nExecStart=/usr/local/bin/plop\nRestart=on-failure\n[Install]\nWantedBy=multi-user.target",
                "[Timer]\nOnCalendar=hourly\nPersistent=true\n[Install]\nWantedBy=timers.target"),
    "tasl": ("namespace paste\ntype PasteId { value: text -> required }\nclass StoredPaste :: Entity { id: PasteId }",
             "namespace relay\ntype Ttl { seconds: integer -> required }\nclass Request :: Message { ttl: Ttl }"),
    "terraform": ("terraform { required_version = \">= 1.8\" }\nresource \"aws_s3_bucket\" \"pastes\" { bucket = var.bucket_name }",
                  "terraform { required_providers { random = { source = \"hashicorp/random\" } } }\nresource \"random_id\" \"suffix\" { byte_length = 4 }"),
    "wenyan": ("吾有一數。曰三。名之曰「甲」。\n吾有一數。曰五。名之曰「乙」。\n加「甲」以「乙」。書之。",
               "吾有一列。名之曰「資料」。\n充「資料」以一。充「資料」以二。\n夫「資料」。書之。"),
    "x86": ("section .text\nglobal add_values\nadd_values:\n    mov eax, [esp+4]\n    add eax, [esp+8]\n    ret",
            "section .text\nglobal clear_flag\nclear_flag:\n    xor eax, eax\n    ret"),
    "x86_64": (".text\n.globl add_values\nadd_values:\n    mov %rdi, %rax\n    add %rsi, %rax\n    ret",
               ".text\n.globl zero_buffer\nzero_buffer:\n    xor %rax, %rax\n    mov %rax, (%rdi)\n    ret"),
    "zsh": ("#!/usr/bin/env zsh\nsetopt extended_glob null_glob\nfor file in **/*.log(.N); do\n  print -r -- $file\ndone",
            "#!/usr/bin/env zsh\nautoload -Uz compinit && compinit\ntypeset -A services\nservices[paste]=8080"),
}

TOKEN_RE = re.compile(rb"[A-Za-z_][A-Za-z0-9_]{1,31}|[^\w\s]{1,3}")


def normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.lower())


def tokens(data: bytes) -> set[bytes]:
    return set(TOKEN_RE.findall(data[:4096]))


def hash_token(token: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in token.lower():
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def readable_files(directory: pathlib.Path) -> list[pathlib.Path]:
    result = []
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.stat().st_size < 8 or path.stat().st_size > 2_000_000:
            continue
        data = path.read_bytes()
        if b"\0" not in data:
            result.append(path)
    return result


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: update_autodetect_corpus.py /path/to/github-linguist")
    linguist = pathlib.Path(sys.argv[1]).resolve()
    revision = subprocess.check_output(["git", "-C", linguist, "rev-parse", "HEAD"], text=True).strip()
    sample_dirs = {normalized(path.name): path for path in (linguist / "samples").iterdir() if path.is_dir()}

    sources: dict[str, tuple[str, str, bytes, list[bytes]]] = {}
    training: dict[str, list[set[bytes]]] = {}
    for grammar in NAMES:
        target = ALIASES.get(grammar, grammar)
        if target in AUTHORED:
            train, test = AUTHORED[target]
            training[target] = [tokens(train.encode()), tokens(test.encode())]
            sources[target] = ("project", f"AUTHORED[{target}]", test.encode(), [train.encode()])
            continue
        if target in sources:
            continue
        directory = (linguist / "samples" / LINGUIST_NAMES[target]) if target in LINGUIST_NAMES else sample_dirs.get(normalized(target))
        if directory is None or not directory.is_dir():
            raise SystemExit(f"no fixture source mapping for {target}")
        files = readable_files(directory)
        if not files:
            raise SystemExit(f"no readable Linguist sample for {target}: {directory}")
        candidates = [path for path in files if 200 <= path.stat().st_size <= 16_384] or files
        test_path = linguist / LINGUIST_FILES[target] if target in LINGUIST_FILES else sorted(
            candidates, key=lambda path: (abs(path.stat().st_size - 4096), str(path))
        )[0]
        train_paths = [path for path in files if path != test_path][:32] or [test_path]
        training[target] = [tokens(path.read_bytes()) for path in train_paths]
        sources[target] = (
            "linguist",
            str(test_path.relative_to(linguist)),
            test_path.read_bytes()[:16_384],
            [path.read_bytes()[:16_384] for path in train_paths],
        )
        training[target].append(tokens(test_path.read_bytes()))

    class_frequency: collections.Counter[bytes] = collections.Counter()
    for documents in training.values():
        class_frequency.update(set().union(*documents))
    class_count = len(training)
    profiles = {}
    for language, documents in training.items():
        frequency = collections.Counter(token for document in documents for token in document)
        ranked = []
        for token, count in frequency.items():
            if len(token) < 2 or class_frequency[token] >= class_count * 0.8:
                continue
            if len(documents) >= 3 and count < 2:
                continue
            idf = math.log((class_count + 1) / (class_frequency[token] + 1)) + 1
            ranked.append((idf * count / len(documents), token))
        profiles[language] = sorted(ranked, reverse=True)[:32]

    if OUT.exists():
        shutil.rmtree(OUT)
    files_dir = OUT / "files"
    files_dir.mkdir(parents=True)
    shutil.copyfile(linguist / "LICENSE", OUT / "LICENSE-LINGUIST-MIT.txt")
    shutil.copyfile(ROOT / "LICENSE", OUT / "LICENSE-PLOP-BSD-3-CLAUSE.txt")

    manifest = ["grammar\texpected\tfixture\tprovenance\tlicense"]
    fixture_rows = []
    for grammar in NAMES:
        expected = ALIASES.get(grammar, grammar)
        origin, upstream, source, _ = sources[expected]
        fixture = f"files/{grammar}.txt"
        (OUT / fixture).write_bytes(source)
        license_name = "MIT" if origin == "linguist" else "BSD-3-Clause"
        provenance = f"github-linguist/linguist@{revision}:{upstream}" if origin == "linguist" else "plop project-authored"
        manifest.append(f"{grammar}\t{expected}\t{fixture}\t{provenance}\t{license_name}")
        fixture_rows.append((grammar, expected, fixture, provenance, license_name))
    (OUT / "manifest.tsv").write_text("\n".join(manifest) + "\n")

    fixture_zig = [
        "// Generated by tools/update_autodetect_corpus.py. Do not edit.",
        "pub const Fixture = struct { grammar: []const u8, expected: []const u8, source: []const u8, provenance: []const u8, license: []const u8 };",
        "pub const fixtures = [_]Fixture{",
    ]
    for grammar, expected, fixture, provenance, license_name in fixture_rows:
        fixture_zig.append(
            f'    .{{ .grammar = "{grammar}", .expected = "{expected}", .source = @embedFile("fixtures/autodetect/{fixture}"), '
            f'.provenance = "{provenance}", .license = "{license_name}" }},'
        )
    fixture_zig.append("};")
    (ROOT / "tests/autodetect_fixtures.zig").write_text("\n".join(fixture_zig) + "\n")

    sorted_profiles = sorted(profiles.items())
    shard_count = 10
    for stale in (ROOT / "src").glob("detect_profiles_*.zig"):
        stale.unlink()
    for shard in range(shard_count):
        rows = sorted_profiles[shard::shard_count]
        profile_zig = [
            "// Generated by tools/update_autodetect_corpus.py. Do not edit.",
            "pub const Token = struct { hash: u64, weight: u8 };",
            "pub const Profile = struct { language: []const u8, tokens: []const Token };",
        ]
        for index, (_, ranked) in enumerate(rows):
            profile_zig.append(f"const tokens_{index} = [_]Token{{")
            for score, token in ranked:
                weight = min(255, max(1, round(score * 16)))
                profile_zig.append(f"    .{{ .hash = 0x{hash_token(token):016x}, .weight = {weight} }},")
            profile_zig.append("};")
        profile_zig.append("pub const profiles = [_]Profile{")
        for index, (language, _) in enumerate(rows):
            profile_zig.append(f'    .{{ .language = "{language}", .tokens = &tokens_{index} }},')
        profile_zig.append("};")
        (ROOT / f"src/detect_profiles_{shard}.zig").write_text("\n".join(profile_zig) + "\n")
    profile_root = ["// Generated by tools/update_autodetect_corpus.py. Do not edit.", "pub const shards = .{"]
    profile_root.extend(f'    @import("detect_profiles_{shard}.zig").profiles,' for shard in range(shard_count))
    profile_root.append("};")
    (ROOT / "src/detect_profiles.zig").write_text("\n".join(profile_root) + "\n")

    readme = f"""# Autodetection fixtures

This corpus covers all {len(NAMES)} zhl grammar names built by plop.

Fixtures marked `MIT` are excerpts from `github-linguist/linguist` pinned at
`{revision}`. Their exact source paths are recorded in `manifest.tsv`; license
text is in `LICENSE-LINGUIST-MIT.txt`. Fixtures marked `BSD-3-Clause` were
written for plop and are covered by `LICENSE-PLOP-BSD-3-CLAUSE.txt`.

Equivalent zhl aliases share one expected detector result because pasted
source has no filename with which to distinguish aliases.

Regenerate after building zhl's full grammar-name registry:

```sh
zig build -Doptimize=ReleaseFast
python3 tools/update_autodetect_corpus.py /path/to/github-linguist
```

Use Linguist revision `{revision}` to reproduce this exact corpus.
"""
    (OUT / "README.md").write_text(readme)
    print(f"generated {len(NAMES)} fixtures and {len(profiles)} detector profiles from Linguist {revision}")


if __name__ == "__main__":
    main()
