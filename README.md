# plop

Fast, local, encrypted pastebin built with Zig 0.16.0.
[Ploof](https://github.com/ferrreo/ploof) renders HTML and serves HTTP,
[zhl](https://github.com/ferrreo/zhl) highlights code server-side, and
[sigbench](https://github.com/ferrreo/sigbench) measures hot paths.

## Run

Requirements: Linux 6.1+, x86-64-v3, Zig 0.16.0.

```sh
umask 077
mkdir -p "$HOME/.config/plop"
openssl rand -hex 32 > "$HOME/.config/plop/master-key"
zig build -Doptimize=ReleaseSafe
PLOP_MASTER_KEY="$(cat "$HOME/.config/plop/master-key")" ./zig-out/bin/plop
```

Generate the master key once. Reuse and back up the same file for every
launch; losing or replacing it makes existing pastes unreadable.

Server listens on `127.0.0.1:8080`. Put Caddy, nginx, HAProxy, or Envoy in
front for TLS and response compression. Persistent encrypted files live in
`./data`.

Environment:

- `PLOP_MASTER_KEY`: required 32-byte key as 64 hex characters. Back it up;
  losing it makes every paste unrecoverable. Do not generate a new key in the
  launch command.
- `PLOP_DATA_DIR`: storage directory, default `data`.
- `PLOP_PORT`: loopback port, default `8080`.
- `PLOP_WORKERS`: active Ploof workers, default 1; cannot exceed build-time
  `max-workers`. Increase after measuring disk and Argon2 contention.

Build options:

```sh
zig build -Doptimize=ReleaseSafe -Dtheme=paper -Dicon=spark \
  -Dmax-paste-bytes=16777216 -Dmax-workers=4
```

Every build compiles zhl's full grammar set. A ReleaseFast x86-64-v3 build:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu \
  -Dcpu=x86_64_v3
```

The embedded full grammar set makes the resulting binary relatively large.

Install branding is also compile-time configurable:

```sh
zig build -Doptimize=ReleaseFast \
  -Dbrand-name="Acme Paste" \
  -Dpage-title="Acme Paste · Secure sharing" \
  -Dsite-url="https://paste.example.com" \
  -Dlogo-file=assets/acme.svg \
  -Dfavicon-file=assets/acme.svg
```

`logo-file` must be an inline SVG containing `class="logo"`. Without it,
`-Dicon=paw|spark` selects the bundled logo. `page-title` defaults to the
visible `brand-name`. `favicon-file` accepts SVG, PNG, or ICO and defaults to
the selected logo. `site-url` sets absolute Open Graph and Twitter card URLs;
set it to the public origin so shared paste links render correct previews.
`meta-description` changes the link-preview description. The optional
MIT-licensed PikaOS-compatible logo is `assets/pika-logo.svg`; plop still uses
the paw logo by default.

Defaults are `neon` (graphite/cobalt), `paw`, 16 MiB, and at most 2 workers;
`paper` selects a warmer editorial palette. Higher build limits reserve more
fixed Ploof memory. Browser light/dark mode follows `prefers-color-scheme` in
both themes.

## API

OpenAPI 3.1 JSON is served at `/openapi.json` and stored in
`src/openapi.json`.

```sh
curl -sS http://127.0.0.1:8080/api/pastes \
  -H 'content-type: application/json' \
  --data '{"content":"const x: u8 = 1;","language":"zig","ttl_seconds":604800}'

curl -sS 'http://127.0.0.1:8080/api/pastes/otter-vole-tiger'
curl -sS 'http://127.0.0.1:8080/p/otter-vole-tiger/raw'
```

Home page accepts image files and images pasted from the clipboard. API image
pastes use `kind: "image"`, an allowed image MIME, and base64 content. Allowed
types: PNG, JPEG, GIF, and WebP. JSON reads return a bounded preview; raw reads
return the whole paste. zhl's full build-time grammar set is available in the
language menu, with common choices first. `Auto detect` is selected by default.
It combines structural checks with token profiles generated from a licensed
real-world fixture for every zhl grammar, and accepts fenced-language or
`language:`/`lang=` hints. Equivalent source-only aliases map to a preferred
canonical grammar; callers can explicitly select a language whenever source
alone is ambiguous. Fixture source, license, exact upstream revision, and
regeneration instructions are in `tests/fixtures/autodetect/README.md`.
Protected API and raw reads send `X-Paste-Password`. Browser unlocks use POST,
so passwords do not enter URLs or referrer logs.
JSON responses include `processing_us`; every API/raw response also sends
`Server-Timing` and `X-Processing-Time-Us`. HTML footers show SSR handler time
in human-readable milliseconds, formatted UTC expiry, and useful paste/build
stats.

## Storage and limits

Each paste is one authenticated XChaCha20-Poly1305 file. Expiry and content are
separately encrypted and authenticated in that file, so the sweeper reads only
the fixed 56-byte expiry header. Passwords use Argon2id with OWASP parameters
and a random per-paste salt. Writes use a temp file plus atomic rename; expiry
is also checked and deleted on read.

HTML previews are bounded: text at 128 KiB, images at 512 KiB, JSON API at
128 KiB. Raw responses stream full content up to build-time maximum and wipe
the decrypted allocation after transmission. This keeps zhl, HTML, and JSON
expansion from multiplying memory use for large pastes. Ploof and zhl already
use fixed-capacity/data-driven paths and SIMD; no duplicate application SIMD
layer exists.

Rendered zhl markup uses a four-entry in-memory LRU. Cache access occurs only
after storage, TTL, and password checks; evicted markup is wiped before free.
This bounds cached plaintext-derived data to 4 MiB while avoiding repeated
highlight work for recently viewed pastes.

Syntax rules cover every semantic token class exported by zhl. CSS is served
once from a content-hashed URL with a one-year immutable cache policy; paste
pages do not inline or resend it.

One process must own data directory. No branches, revisions, accounts, search,
or background jobs besides expiry cleanup. A bounded 256 KiB thread sweeps
encrypted expiry headers hourly and removes expired files; files can remain for
at most one sweep interval when they are never read.

## Verify

```sh
zig build test
zig build integration-test
zig build -Doptimize=ReleaseSafe
zig build bench -Doptimize=ReleaseFast
```

Tests cover authenticated encryption at rest, password verification, hourly
expiry deletion, every zhl grammar fixture and semantic token class, bounded
raw streaming, immutable CSS, and full Ploof form/API create/read routes,
including fresh and cached highlight paths.
Integration coverage exercises live sockets, default and expiring TTLs,
protected browser/API/raw flows, images, timing metadata, and exact/over-limit
streamed pastes. It requires `bash`, `curl`, `jq`, and `base64`; set
`PLOP_TEST_PORT` if port 18080 is occupied.
