#!/usr/bin/env bash
set -euo pipefail

bin=${1:?plop binary required}
max_bytes=${2:?maximum paste bytes required}
max_workers=${3:?maximum workers required}
site_url=${4:?public site URL required}
port=${PLOP_TEST_PORT:-18080}
base="http://127.0.0.1:${port}"
work=$(mktemp -d)
pid=

cleanup() {
    status=$?
    if [[ -s "$work/server.log" ]]; then cat "$work/server.log"; fi
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf -- "$work"
    return "$status"
}
trap cleanup EXIT

if env -u PLOP_MASTER_KEY "$bin" >"$work/missing-key.log" 2>&1; then exit 1; fi
grep -q 'PLOP_MASTER_KEY must be 64 hexadecimal characters' "$work/missing-key.log"
if PLOP_MASTER_KEY=bad PLOP_DATA_DIR="$work/invalid-key" "$bin" >"$work/invalid-key.log" 2>&1; then exit 1; fi
if PLOP_MASTER_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
    PLOP_DATA_DIR="$work/invalid-worker" PLOP_WORKERS=$((max_workers + 1)) "$bin" >"$work/invalid-worker.log" 2>&1; then exit 1; fi

PLOP_MASTER_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
PLOP_DATA_DIR="$work/data" PLOP_PORT="$port" "$bin" >"$work/server.log" 2>&1 &
pid=$!
for _ in {1..100}; do
    if curl -fsS "$base/" -o "$work/home.html" 2>/dev/null; then break; fi
    if ! kill -0 "$pid" 2>/dev/null; then cat "$work/server.log"; exit 1; fi
    sleep 0.05
done
curl -fsS "$base/" -D "$work/home.headers" -o "$work/home.html"
grep -Eq '>SSR</b> [0-9]+\.[0-9]+ ms' "$work/home.html"
grep -qi '^server-timing:' "$work/home.headers"
grep -q 'property="og:title"' "$work/home.html"
grep -q "property=\"og:url\" content=\"$site_url\"" "$work/home.html"
grep -q 'name="twitter:card" content="summary"' "$work/home.html"
favicon=$(grep -o 'href="/assets/favicon-[0-9a-f]*\.[a-z]*"' "$work/home.html" | head -1 | cut -d '"' -f2)
[[ "$favicon" =~ ^/assets/favicon-[0-9a-f]+\.(svg|png|ico)$ ]]
curl -fsS "$base$favicon" -D "$work/favicon.headers" -o "$work/favicon"
grep -qi '^cache-control: public, max-age=31536000, immutable' "$work/favicon.headers"
stylesheet=$(grep -o 'href="/assets/app-[0-9a-f]*\.css"' "$work/home.html" | head -1 | cut -d '"' -f2)
[[ "$stylesheet" =~ ^/assets/app-[0-9a-f]+\.css$ ]]
curl -fsS "$base$stylesheet" -D "$work/styles.headers" -o "$work/styles.css"
grep -q 'prefers-color-scheme' "$work/styles.css"
grep -qi '^cache-control: public, max-age=31536000, immutable' "$work/styles.headers"

curl -fsS "$base/openapi.json" -D "$work/spec.headers" -o "$work/openapi.json"
jq -e '.openapi == "3.1.0" and .paths["/api/pastes"].post and .paths["/p/{id}/raw"].get' "$work/openapi.json" >/dev/null
grep -qi '^x-processing-time-us:' "$work/spec.headers"

curl -fsS "$base/pastes" -D "$work/form.headers" -o /dev/null \
    --data-urlencode 'content=hello form' --data 'language=text' --data 'ttl_days=7' --data 'password='
grep -Eq '^location: /p/[a-z]+-[a-z]+-[a-z]+' "$work/form.headers"

curl -fsS "$base/api/pastes" -H 'content-type: application/json' \
    --data '{"content":"const answer: u8 = 42;","language":"zig"}' \
    -D "$work/create.headers" -o "$work/create.json"
jq -e '.expires_in == 604800 and .size_bytes == 22 and .kind == "text" and (.processing_us >= 0)' "$work/create.json" >/dev/null
id=$(jq -r '.id' "$work/create.json")
[[ "$id" =~ ^[a-z]+-[a-z]+-[a-z]+$ ]]
IFS=- read -r animal_one animal_two animal_three <<<"$id"
[[ "$animal_one" != "$animal_two" && "$animal_one" != "$animal_three" && "$animal_two" != "$animal_three" ]]
grep -qi '^server-timing:' "$work/create.headers"

curl -fsS "$base/pastes" -D "$work/auto-form.headers" -o /dev/null \
    --data-urlencode 'content@tests/fixtures/regression/zig-build-command.txt' \
    --data 'language=auto' --data 'ttl_days=7' --data 'password='
auto_path=$(sed -n 's/^location: \([^\r]*\).*/\1/p' "$work/auto-form.headers")
[[ "$auto_path" =~ ^/p/[a-z]+-[a-z]+-[a-z]+$ ]]
curl -fsS "$base$auto_path" -o "$work/auto-page.html"
grep -q '<dd>bash</dd>' "$work/auto-page.html"

curl -fsS "$base/p/$id" -o "$work/page.html"
grep -q 'zhl-' "$work/page.html"
grep -Eq '[0-9]{2} [A-Z][a-z]{2} [0-9]{4}, [0-9]{2}:[0-9]{2} UTC' "$work/page.html"
grep -q 'zhl fresh' "$work/page.html"
grep -q "property=\"og:title\" content=\"$id ·" "$work/page.html"
grep -q "property=\"og:url\" content=\"$site_url/p/$id\"" "$work/page.html"
grep -Eq '>SSR</b> [0-9]+\.[0-9]+ ms' "$work/page.html"
curl -fsS "$base/p/$id" -o "$work/page-cached.html"
grep -q 'zhl cache hit' "$work/page-cached.html"
curl -fsS "$base/api/pastes/$id" -D "$work/get.headers" -o "$work/get.json"
jq -e '.content == "const answer: u8 = 42;" and .raw == "/p/'"$id"'/raw" and
    (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.processing_us >= 0)' "$work/get.json" >/dev/null
curl -fsS "$base/p/$id/raw" -D "$work/raw.headers" -o "$work/raw.txt"
printf 'const answer: u8 = 42;' >"$work/expected.txt"
cmp "$work/expected.txt" "$work/raw.txt"
grep -qi '^x-paste-bytes: 22' "$work/raw.headers"
grep -qi '^x-processing-time-us:' "$work/raw.headers"

curl -fsS "$base/api/pastes" -H 'content-type: application/json' \
    --data '{"content":"hidden","password":"otter vole","ttl_seconds":60}' -o "$work/protected.json"
protected_id=$(jq -r '.id' "$work/protected.json")
[[ $(curl -sS -D "$work/denied-api.headers" -o "$work/denied-api.json" -w '%{http_code}' "$base/api/pastes/$protected_id") == 401 ]]
jq -e '(.error_message | length > 0) and (.processing_us >= 0)' "$work/denied-api.json" >/dev/null
grep -qi '^server-timing:' "$work/denied-api.headers"
[[ $(curl -sS -D "$work/denied-raw.headers" -o /dev/null -w '%{http_code}' "$base/p/$protected_id/raw") == 401 ]]
grep -qi '^x-processing-time-us:' "$work/denied-raw.headers"
curl -fsS "$base/p/$protected_id" -o "$work/password.html"
grep -q 'method="post"' "$work/password.html"
grep -Eq '>SSR</b> [0-9]+\.[0-9]+ ms' "$work/password.html"
curl -fsS "$base/p/$protected_id?password=otter%20vole" -o "$work/query-password.html"
grep -q 'Protected paste' "$work/query-password.html"
curl -fsS "$base/p/$protected_id" --data-urlencode 'password=wrong' -o "$work/wrong.html"
grep -q 'Wrong password' "$work/wrong.html"
curl -fsS "$base/p/$protected_id" --data-urlencode 'password=otter vole' -o "$work/unlocked.html"
grep -q 'hidden' "$work/unlocked.html"
curl -fsS "$base/api/pastes/$protected_id" -H 'x-paste-password: otter vole' -o "$work/protected-get.json"
jq -e '.content == "hidden"' "$work/protected-get.json" >/dev/null
curl -fsS "$base/p/$protected_id/raw" -H 'x-paste-password: otter vole' -o "$work/protected.raw"
grep -qx 'hidden' "$work/protected.raw"

curl -fsS "$base/api/pastes" -H 'content-type: application/json' \
    --data '{"content":"iVBORw==","kind":"image","mime":"image/png","ttl_seconds":60}' -o "$work/image.json"
image_id=$(jq -r '.id' "$work/image.json")
curl -fsS "$base/p/$image_id" -o "$work/image.html"
grep -q 'data:image/png;base64,iVBORw==' "$work/image.html"
curl -fsS "$base/p/$image_id/raw" -D "$work/image.headers" -o "$work/image.raw"
printf '\211PNG' >"$work/image.expected"
cmp "$work/image.expected" "$work/image.raw"
grep -qi '^content-type: image/png' "$work/image.headers"

printf 'x' >"$work/ttl.txt"
jq -Rs '{content:.,ttl_seconds:1}' <"$work/ttl.txt" >"$work/ttl-request.json"
curl -fsS "$base/api/pastes" -H 'content-type: application/json' --data-binary @"$work/ttl-request.json" -o "$work/ttl.json"
ttl_id=$(jq -r '.id' "$work/ttl.json")
sleep 1.1
[[ $(curl -sS -o /dev/null -w '%{http_code}' "$base/api/pastes/$ttl_id") == 410 ]]

head -c "$max_bytes" /dev/zero | tr '\0' '\n' >"$work/large.txt"
jq -Rs '{content:.,language:"text",ttl_seconds:60}' <"$work/large.txt" >"$work/large-request.json"
curl -fsS "$base/api/pastes" -H 'content-type: application/json' --data-binary @"$work/large-request.json" -o "$work/large.json"
large_id=$(jq -r '.id' "$work/large.json")
jq -e --argjson size "$max_bytes" '.size_bytes == $size' "$work/large.json" >/dev/null
curl -fsS "$base/api/pastes/$large_id" -o "$work/large-get.json"
if (( max_bytes > 131072 )); then jq -e '.truncated == true' "$work/large-get.json" >/dev/null; fi
curl -fsS "$base/p/$large_id" -o "$work/large-page.html"
if (( max_bytes > 131072 )); then grep -q 'Preview truncated' "$work/large-page.html"; fi
curl -fsS "$base/p/$large_id/raw" -D "$work/large.headers" -o "$work/large.raw"
cmp "$work/large.txt" "$work/large.raw"
grep -qi "^x-paste-bytes: $max_bytes" "$work/large.headers"

printf x >>"$work/large.txt"
jq -Rs '{content:.,language:"text",ttl_seconds:60}' <"$work/large.txt" >"$work/oversize-text-request.json"
[[ $(curl -sS -o "$work/oversize-text.json" -w '%{http_code}' "$base/api/pastes" \
    -H 'content-type: application/json' --data-binary @"$work/oversize-text-request.json") == 413 ]]
jq -e '.error_message == "paste too large" and (.processing_us >= 0)' "$work/oversize-text.json" >/dev/null

base64 -w0 "$work/large.txt" >"$work/oversize.b64"
jq -Rs '{content:.,kind:"image",mime:"image/png",ttl_seconds:60}' <"$work/oversize.b64" >"$work/oversize-request.json"
[[ $(curl -sS -o "$work/oversize.json" -w '%{http_code}' "$base/api/pastes" \
    -H 'content-type: application/json' --data-binary @"$work/oversize-request.json") == 413 ]]
jq -e '.error_message == "image too large" and (.processing_us >= 0)' "$work/oversize.json" >/dev/null

echo 'integration tests passed'
