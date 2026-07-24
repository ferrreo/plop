#!/usr/bin/env sh
set -eu

zhl_root=$1
out=$2

case "$out" in
    */zig-out/zhl_full) ;;
    *) printf 'refusing unexpected output path: %s\n' "$out" >&2; exit 1 ;;
esac

rm -rf "$out"
mkdir -p "$out/all"

(
    cd "$zhl_root"
    OUT_DIR="$out/all" LANGS=full sh tools/select_grammars.sh >/dev/null
)

awk '/^pub const names =/,/^};/ {
    if ($0 ~ /^    "/) {
        gsub(/[",]/, "", $1)
        print $1
    }
}' "$out/all/root.zig" > "$out/names"

split -l 68 -d -a 1 "$out/names" "$out/chunk-"

shard=0
for chunk in "$out"/chunk-*; do
    langs=$(paste -sd, "$chunk")
    mkdir -p "$out/shard-$shard"
    (
        cd "$zhl_root"
        OUT_DIR="$out/shard-$shard" LANGS="$langs" sh tools/select_grammars.sh >/dev/null
    )
    shard=$((shard + 1))
done

if [ "$shard" -ne 3 ]; then
    printf 'expected 3 zhl shards, generated %s\n' "$shard" >&2
    exit 1
fi

catalog="$out/catalog.zig"
{
    echo 'const std = @import("std");'
    echo 'pub const shard_count: usize = 3;'
    echo 'pub const Language = struct { canonical: []const u8, shard: u8, id: u32 };'
    echo 'pub const languages = [_]Language{'
    shard=0
    for chunk in "$out"/chunk-*; do
        root="$out/shard-$shard/root.zig"
        awk '/^pub const names =/,/^};/ { if ($0 ~ /^    "/) { gsub(/[",]/, "", $1); print $1 } }' \
            "$root" > "$out/catalog-names"
        awk '/^pub const ids =/,/^};/ { if ($0 ~ /^    [0-9]/) { gsub(/,/, "", $1); print $1 } }' \
            "$root" > "$out/catalog-ids"
        paste "$out/catalog-names" "$out/catalog-ids" | while IFS="$(printf '\t')" read -r name id; do
            printf '    .{ .canonical = "%s", .shard = %s, .id = %s },\n' "$name" "$shard" "$id"
        done
        shard=$((shard + 1))
    done
    echo '};'
    cat <<'EOF'
pub fn find(name: []const u8) ?Language {
    for (languages) |language|
        if (std.mem.eql(u8, language.canonical, name)) return language;
    return null;
}
EOF
} > "$catalog"

printf 'zhl full registry: %s grammars in %s shards\n' "$(wc -l < "$out/names" | tr -d ' ')" "$shard"
