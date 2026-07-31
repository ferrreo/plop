const std = @import("std");
const ploof = @import("ploof");
const options = @import("build_options");
const grammars = @import("zhl_grammars");
const full_grammars = @import("zhl_grammars_full");
const highlight = @import("highlight.zig");
const store_module = @import("store.zig");
const theme = @import("theme.zig");

const Store = store_module.Store;
const max_paste_bytes = options.max_paste_bytes;
const html_preview_bytes = 128 * 1024;
const image_preview_bytes = 512 * 1024;
const api_preview_bytes = 128 * 1024;
const response_bytes = highlight.rendered_bytes_max + 64 * 1024;
const stylesheet_path = stylesheetPath();
const favicon_bytes = @embedFile("brand_favicon");
const favicon_path = faviconPath();
const favicon_url = options.site_url ++ favicon_path;
const sweep_interval_seconds = 60 * 60;
const sweeper_stack_bytes = 256 * 1024;

fn stylesheetPath() []const u8 {
    @setEvalBranchQuota(100_000);
    return std.fmt.comptimePrint("/assets/app-{x}.css", .{std.hash.Wyhash.hash(0, theme.css)});
}

fn faviconPath() []const u8 {
    @setEvalBranchQuota(100_000);
    return std.fmt.comptimePrint("/assets/favicon-{x}{s}", .{
        std.hash.Wyhash.hash(0, favicon_bytes),
        options.favicon_extension,
    });
}

const State = struct {
    store: Store,
    highlight_cache: highlight.Cache,
};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;
const TrustedMarkup = ploof.Html.TrustedHtml(highlight.rendered_bytes_max);

const preferred_languages = [_][]const u8{
    "zig",  "c",    "cpp", "rust",     "python", "javascript", "typescript",
    "json", "html", "css", "markdown", "bash",
};
const language_options = languageOptions();

fn languageOptions() []const u8 {
    @setEvalBranchQuota(10_000);
    var html: []const u8 = "<option value=\"auto\" selected>Auto detect</option><option value=\"text\">Plain text</option>";
    inline for (preferred_languages) |name| {
        const metadata = grammars.findByName(name) orelse @compileError("preferred zhl language is missing");
        html = html ++ "<option value=\"" ++ metadata.canonical ++ "\">" ++ displayName(metadata.canonical, metadata.display_name) ++ "</option>";
    }
    inline for (full_grammars.languages) |language_entry| {
        const name = language_entry.canonical;
        var preferred = false;
        for (preferred_languages) |preferred_name| preferred = preferred or std.mem.eql(u8, preferred_name, name);
        if (!preferred)
            html = html ++ "<option value=\"" ++ name ++ "\">" ++ name ++ "</option>";
    }
    return html;
}

fn displayName(canonical: []const u8, fallback: []const u8) []const u8 {
    return if (std.mem.eql(u8, canonical, "zig")) "Zig" else fallback;
}

const shell_head =
    "<!doctype html><html lang=\"en\" data-theme=\"" ++ options.theme ++ "\"><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
    "<meta name=\"color-scheme\" content=\"dark light\"><title>" ++ options.page_title ++ "</title>" ++
    "<meta name=\"description\" content=\"" ++ options.meta_description ++ "\">" ++
    "<meta property=\"og:type\" content=\"website\"><meta property=\"og:site_name\" content=\"" ++ options.page_title ++ "\">" ++
    "<meta property=\"og:image\" content=\"" ++ favicon_url ++ "\"><meta property=\"og:image:type\" content=\"" ++ options.favicon_mime ++ "\">" ++
    "<meta property=\"og:image:alt\" content=\"" ++ options.brand_name ++ " logo\"><meta name=\"twitter:card\" content=\"summary\">" ++
    "<meta name=\"twitter:image\" content=\"" ++ favicon_url ++ "\"><meta name=\"twitter:image:alt\" content=\"" ++ options.brand_name ++ " logo\">";
const shell_body =
    "<link rel=\"icon\" type=\"" ++ options.favicon_mime ++ "\" href=\"" ++ favicon_path ++ "\">" ++
    "<link rel=\"stylesheet\" href=\"" ++ stylesheet_path ++ "\"></head><body><main class=\"shell\"><header class=\"site-header\">" ++
    "<a class=\"brand\" href=\"/\" aria-label=\"" ++ options.brand_name ++ " home\">" ++ theme.icon ++
    "<span>" ++ options.brand_name ++ "</span></a>" ++
    "<nav class=\"site-nav\" aria-label=\"Primary\"><a href=\"/openapi.json\">API</a></nav></header>";
const home_shell_start = shell_head ++
    "<meta property=\"og:title\" content=\"" ++ options.page_title ++ "\"><meta property=\"og:description\" content=\"" ++ options.meta_description ++ "\">" ++
    "<meta property=\"og:url\" content=\"" ++ options.site_url ++ "\"><meta name=\"twitter:title\" content=\"" ++ options.page_title ++ "\">" ++
    "<meta name=\"twitter:description\" content=\"" ++ options.meta_description ++ "\">" ++ shell_body;
const password_shell_start = shell_head ++
    "<meta property=\"og:title\" content=\"Protected paste · " ++ options.page_title ++ "\">" ++
    "<meta property=\"og:description\" content=\"Password required to view this paste.\"><meta property=\"og:url\" content=\"{{view.embed_url}}\">" ++
    "<meta name=\"twitter:title\" content=\"Protected paste · " ++ options.page_title ++ "\">" ++
    "<meta name=\"twitter:description\" content=\"Password required to view this paste.\">" ++ shell_body;
const paste_shell_start = shell_head ++
    "<meta property=\"og:title\" content=\"{{view.id}} · " ++ options.page_title ++ "\">" ++
    "<meta property=\"og:description\" content=\"{{view.language}} paste · {{view.size_label}} · expires {{view.expires_at}}\">" ++
    "<meta property=\"og:url\" content=\"{{view.embed_url}}\"><meta name=\"twitter:title\" content=\"{{view.id}} · " ++ options.page_title ++ "\">" ++
    "<meta name=\"twitter:description\" content=\"{{view.language}} paste · {{view.size_label}} · expires {{view.expires_at}}\">" ++ shell_body;
const shell_end = "</main></body></html>";
const home_script =
    "<script>" ++
    "const f=document.querySelector('#paste-form'),i=document.querySelector('#image-file')," ++
    "t=f.querySelector('textarea'),p=document.querySelector('#image-preview'),b=document.querySelector('#submit-button'),s=document.querySelector('#form-status');let previewUrl='';" ++
    "i.addEventListener('change',()=>{const file=i.files[0];t.required=!file;i.removeAttribute('aria-invalid');if(previewUrl)URL.revokeObjectURL(previewUrl);previewUrl='';" ++
    "if(file){t.value='';t.hidden=true;p.hidden=false;previewUrl=URL.createObjectURL(file);p.src=previewUrl;p.alt=file.name}else{t.hidden=false;p.hidden=true;p.removeAttribute('src');p.alt=''}s.textContent=file?'image selected: '+file.name:''});" ++
    "t.addEventListener('paste',e=>{const item=[...e.clipboardData.items].find(item=>item.kind==='file'&&item.type.startsWith('image/')),file=item?.getAsFile();if(!file)return;e.preventDefault();const transfer=new DataTransfer();transfer.items.add(file);i.files=transfer.files;i.dispatchEvent(new Event('change'))});" ++
    "f.addEventListener('submit',async e=>{if(!i.files.length)return;e.preventDefault();" ++
    "const file=i.files[0],allowed=['image/png','image/jpeg','image/gif','image/webp'];" ++
    "if(file.size>" ++ std.fmt.comptimePrint("{d}", .{max_paste_bytes}) ++ "){s.textContent='image exceeds server limit';i.setAttribute('aria-invalid','true');return}" ++
    "if(!allowed.includes(file.type)){s.textContent='use PNG, JPEG, GIF, or WebP';i.setAttribute('aria-invalid','true');return}" ++
    "b.disabled=true;b.textContent='encrypting…';s.textContent='reading image…';" ++
    "try{const data=await new Promise((ok,no)=>{const r=new FileReader();r.onload=()=>ok(r.result);r.onerror=()=>no(new Error('could not read image'));r.readAsDataURL(file)});" ++
    "const response=await fetch('/api/pastes',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({" ++
    "content:data.slice(data.indexOf(',')+1),kind:'image',mime:file.type,password:f.password.value," ++
    "ttl_seconds:Number(f.ttl_days.value)*86400})});const result=await response.json();" ++
    "if(!response.ok)throw new Error(result.error_message||'upload failed');location.assign(result.url)" ++
    "}catch(error){s.textContent=error.message;b.disabled=false;b.textContent='Create encrypted paste'}});</script>";

const HomePage = page(
    "home",
    struct { processing_time: []const u8, max_mib: usize },
    home_shell_start ++
        "<section class=\"compose\">" ++
        "<div class=\"panel\"><div class=\"panel-header\"><div><h2>New paste</h2>" ++
        "<p>Text or image · up to {{view.max_mib}} MiB</p></div></div>" ++
        "<form id=\"paste-form\" class=\"editor\" method=\"post\" action=\"/pastes\">" ++
        "<div class=\"field-heading\"><label for=\"paste-content\">Content</label></div>" ++
        "<textarea id=\"paste-content\" name=\"content\" required autofocus placeholder=\"Paste text or code here\"></textarea>" ++
        "<img id=\"image-preview\" class=\"image-preview\" hidden=\"hidden\" alt=\"Selected image preview\">" ++
        "<fieldset class=\"options\"><legend>Paste options</legend><label class=\"control\"><span>Image <small>optional</small></span>" ++
        "<input id=\"image-file\" type=\"file\" accept=\"image/png,image/jpeg,image/gif,image/webp\"></label>" ++
        "<label class=\"control\"><span>Language</span><div class=\"select-wrap\"><select name=\"language\">" ++ language_options ++
        "</select></div></label>" ++
        "<label class=\"control\"><span>Expires after</span><div class=\"select-wrap\"><select name=\"ttl_days\"><option value=\"1\">1 day</option>" ++
        "<option value=\"7\" selected>7 days</option><option value=\"30\">30 days</option>" ++
        "<option value=\"90\">90 days</option></select></div></label>" ++
        "<label class=\"control control-grow\"><span>Password <small>optional</small></span>" ++
        "<input type=\"password\" name=\"password\" maxlength=\"256\" autocomplete=\"new-password\"></label>" ++
        "<button id=\"submit-button\" type=\"submit\">Create encrypted paste</button></fieldset>" ++
        "<p id=\"form-status\" class=\"form-status\" role=\"status\" aria-live=\"polite\"></p></form></div></section>" ++
        home_script ++
        "<footer class=\"page-stats\"><span><b>SSR</b> {{view.processing_time}}</span>" ++
        "<span><b>Storage</b> XChaCha20-Poly1305</span><span><b>Limit</b> {{view.max_mib}} MiB</span></footer>" ++ shell_end,
    32 * 1024,
);

const PasswordPage = page(
    "password",
    struct { bad: bool, embed_url: []const u8, processing_time: []const u8 },
    password_shell_start ++
        "<section class=\"unlock panel\"><div class=\"unlock-copy\"><p class=\"eyebrow\">Protected paste</p>" ++
        "<h1>Password required</h1><p>Enter the paste password to decrypt and render its contents.</p></div>" ++
        "<form class=\"password\" method=\"post\"><label class=\"control control-grow\"><span>Paste password</span>" ++
        "<input type=\"password\" name=\"password\" autocomplete=\"current-password\" required autofocus></label>" ++
        "<button type=\"submit\">Unlock paste</button></form>" ++
        "{{#if view.bad}}<p class=\"notice error\" role=\"alert\">Wrong password. Try again.</p>{{/if}}</section>" ++
        "<footer class=\"page-stats\"><span><b>SSR</b> {{view.processing_time}}</span>" ++
        "<span><b>Password</b> Argon2id</span><span><b>Storage</b> Encrypted at rest</span></footer>" ++ shell_end,
    32 * 1024,
);

const paste_script =
    "<script>" ++
    "(()=>{const b=document.querySelector('#copy-link');if(!b)return;" ++
    "b.addEventListener('click',async()=>{" ++
    "try{await navigator.clipboard.writeText(location.href)}" ++
    "catch{const t=document.createElement('textarea');t.value=location.href;t.setAttribute('readonly','');" ++
    "t.style.cssText='position:fixed;left:-9999px';document.body.appendChild(t);t.select();" ++
    "try{document.execCommand('copy')}finally{t.remove()}}" ++
    "b.dataset.copied='';b.setAttribute('aria-label','Link copied');" ++
    "clearTimeout(b._t);b._t=setTimeout(()=>{delete b.dataset.copied;b.setAttribute('aria-label','Copy paste link')},1600)" ++
    "})})()</script>";

const PastePage = page(
    "paste",
    struct {
        id: []const u8,
        language: []const u8,
        expires_at: []const u8,
        markup: TrustedMarkup,
        image: bool,
        truncated: bool,
        show_raw: bool,
        raw_url: ploof.Url,
        embed_url: []const u8,
        size_bytes: usize,
        size_label: []const u8,
        highlight_cached: bool,
        processing_time: []const u8,
    },
    paste_shell_start ++
        "<article class=\"paste panel\"><header class=\"paste-header\"><div><p class=\"eyebrow\">Copy link</p>" ++
        "<h1><button type=\"button\" class=\"paste-title\" id=\"copy-link\" aria-label=\"Copy paste link\" title=\"Copy page URL\">" ++
        "<span class=\"paste-title-text\">{{view.id}}</span>" ++
        "<svg class=\"paste-title-icon paste-title-copy\" aria-hidden=\"true\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" ++
        "<rect x=\"9\" y=\"9\" width=\"13\" height=\"13\" rx=\"2\"></rect><path d=\"M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1\"></path></svg>" ++
        "<svg class=\"paste-title-icon paste-title-done\" aria-hidden=\"true\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" ++
        "<path d=\"M20 6 9 17l-5-5\"></path></svg></button></h1></div>" ++
        "<nav class=\"paste-actions\" aria-label=\"Paste actions\">" ++
        "{{#if view.show_raw}}<a href=\"{{view.raw_url}}\">View raw</a>{{/if}}<a class=\"primary-link\" href=\"/\">New paste</a></nav></header>" ++
        "<dl class=\"paste-facts\"><div><dt>Language</dt><dd>{{view.language}}</dd></div>" ++
        "<div><dt>Expires</dt><dd>{{view.expires_at}}</dd></div><div><dt>Size</dt><dd>{{view.size_label}}</dd></div></dl>" ++
        "<div class=\"source-frame\">{{#if view.image}}<div class=\"image\">{{view.markup}}</div>" ++
        "{{else}}<pre><code>{{view.markup}}</code></pre>{{/if}}</div>" ++
        "{{#if view.truncated}}<p class=\"notice\">Preview truncated. Use raw endpoint for full paste.</p>{{/if}}" ++
        "</article><footer class=\"page-stats\"><span><b>SSR</b> {{view.processing_time}}</span>" ++
        "<span><b>Render</b> {{#if view.image}}image preview{{else}}{{#if view.highlight_cached}}zhl cache hit{{else}}zhl fresh{{/if}}{{/if}}</span>" ++
        "<span><b>Storage</b> XChaCha20-Poly1305</span></footer>" ++
        paste_script ++ shell_end,
    response_bytes,
);

const CreateForm = struct {
    content: []const u8,
    language: []const u8 = "auto",
    password: []const u8 = "",
    ttl_days: u16 = 7,
};
const ApiCreate = struct {
    content: []const u8,
    language: []const u8 = "auto",
    password: []const u8 = "",
    ttl_seconds: u32 = 7 * 24 * 60 * 60,
    kind: []const u8 = "text",
    mime: []const u8 = "text/plain; charset=utf-8",
};
const UnlockForm = struct { password: []const u8 };

const FormCreateEndpoint = ploof.Endpoint(.{ .body = ploof.Form.typed(CreateForm, .{
    .encoded_wire_bytes_max = max_paste_bytes * 3,
    .decoded_bytes_max = max_paste_bytes + 512,
    .segments_max = 8,
    .unknown_fields = .reject,
}) });
const ApiCreateEndpoint = ploof.Endpoint(.{
    .body = ploof.Json.typed(ApiCreate, .{
        .encoded_wire_bytes_max = max_paste_bytes * 2 + 4096,
        .decoded_bytes_max = max_paste_bytes * 2 + 4096,
        .parse_memory_bytes_max = max_paste_bytes + 4096,
        .unknown_fields = .reject,
    }),
    .response_json_bytes_max = 512,
});
const UnlockEndpoint = ploof.Endpoint(.{ .body = ploof.Form.typed(UnlockForm, .{
    .encoded_wire_bytes_max = 1024,
    .decoded_bytes_max = 512,
    .segments_max = 1,
    .unknown_fields = .reject,
}) });
const ApiReadEndpoint = ploof.Endpoint(.{
    .response_json_bytes_max = 1024 * 1024,
});

fn home(context: *Context) Response {
    const started = startTimer(context);
    var timing_buffer: [24]u8 = undefined;
    return withTiming(context, renderPage(context, HomePage, .{
        .processing_time = formatMillis(&timing_buffer, elapsedUs(context, started)),
        .max_mib = max_paste_bytes / (1024 * 1024),
    }), started);
}

fn createFromForm(context: *Context, input: FormCreateEndpoint.InputType) Response {
    const started = startTimer(context);
    const value = input.body;
    if (value.content.len > max_paste_bytes)
        return withTiming(context, context.textStatic(.payload_too_large, "paste too large"), started);
    if (value.ttl_days == 0 or value.ttl_days > 365)
        return withTiming(context, context.textStatic(.bad_request, "ttl_days must be 1..365"), started);
    if (value.password.len > store_module.password_bytes_max)
        return withTiming(context, context.textStatic(.bad_request, "password must be at most 256 bytes"), started);
    const selected = highlight.language(value.language, value.content);
    const id = create(context, .{
        .content = value.content,
        .language = selected,
        .password = value.password,
        .ttl_seconds = @as(u32, value.ttl_days) * 24 * 60 * 60,
    }) catch return withTiming(context, context.textStatic(.internal_server_error, "could not store paste"), started);
    var location_buffer: [80]u8 = undefined;
    const location = std.fmt.bufPrint(&location_buffer, "/p/{s}", .{id.slice()}) catch unreachable;
    var response = context.empty(.see_other);
    response.setHeader("Location", location) catch
        return withTiming(context, context.empty(.internal_server_error), started);
    return withTiming(context, response, started);
}

fn createFromApi(context: *Context, input: ApiCreateEndpoint.InputType) Response {
    const started = startTimer(context);
    const value = input.body;
    if (value.content.len > max_paste_bytes and !std.mem.eql(u8, value.kind, "image"))
        return jsonError(context, .payload_too_large, "paste too large", started);
    if (value.ttl_seconds == 0 or value.ttl_seconds > 365 * 24 * 60 * 60)
        return jsonError(context, .bad_request, "ttl_seconds must be 1..31536000", started);
    if (value.password.len > store_module.password_bytes_max)
        return jsonError(context, .bad_request, "password must be at most 256 bytes", started);
    var decoded: ?[]u8 = null;
    defer if (decoded) |bytes| context.state.store.allocator.free(bytes);
    var put = store_module.Put{
        .content = value.content,
        .language = highlight.language(value.language, value.content),
        .password = value.password,
        .ttl_seconds = value.ttl_seconds,
    };
    if (std.mem.eql(u8, value.kind, "image")) {
        if (!allowedImageMime(value.mime)) return jsonError(context, .bad_request, "unsupported image mime", started);
        const size = std.base64.standard.Decoder.calcSizeForSlice(value.content) catch
            return jsonError(context, .bad_request, "invalid base64 image", started);
        if (size > max_paste_bytes) return jsonError(context, .payload_too_large, "image too large", started);
        decoded = context.state.store.allocator.alloc(u8, size) catch
            return jsonError(context, .internal_server_error, "allocation failed", started);
        std.base64.standard.Decoder.decode(decoded.?, value.content) catch
            return jsonError(context, .bad_request, "invalid base64 image", started);
        put.content = decoded.?;
        put.language = "image";
        put.mime = value.mime;
        put.kind = .image;
    } else if (!std.mem.eql(u8, value.kind, "text")) {
        return jsonError(context, .bad_request, "kind must be text or image", started);
    }
    const id = create(context, put) catch return jsonError(context, .internal_server_error, "could not store paste", started);
    var url_buffer: [80]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "/p/{s}", .{id.slice()}) catch unreachable;
    const response = context.json(.created, .{
        .id = id.slice(),
        .url = url,
        .expires_in = value.ttl_seconds,
        .size_bytes = put.content.len,
        .kind = @tagName(put.kind),
        .processing_us = elapsedUs(context, started),
    }) catch context.empty(.internal_server_error);
    return withTiming(context, response, started);
}

fn show(context: *Context) Response {
    const started = startTimer(context);
    return showWithPassword(context, requestPassword(context), started);
}

fn unlock(context: *Context, input: UnlockEndpoint.InputType) Response {
    const started = startTimer(context);
    if (input.body.password.len > store_module.password_bytes_max)
        return withTiming(context, context.textStatic(.bad_request, "password must be at most 256 bytes"), started);
    return showWithPassword(context, input.body.password, started);
}

fn showWithPassword(context: *Context, password: []const u8, started: std.Io.Timestamp) Response {
    const id = context.request.param("id") orelse return context.empty(.not_found);
    var paste = context.state.store.get(id, password, now(context)) catch |err| switch (err) {
        error.PasswordRequired => return renderPassword(context, false, started),
        error.PasswordDenied => return renderPassword(context, true, started),
        error.NotFound => return withTiming(context, context.empty(.not_found), started),
        error.Expired => {
            context.state.highlight_cache.remove(id);
            return withTiming(context, context.empty(.gone), started);
        },
        else => {
            std.log.err("paste page read failed for {s}: {t}", .{ id, err });
            return withTiming(context, context.empty(.internal_server_error), started);
        },
    };
    defer paste.deinit(context.state.store.allocator);

    const allocator = context.state.store.allocator;
    const markup_buffer = allocator.alloc(u8, highlight.rendered_bytes_max) catch |err| {
        std.log.err("paste page markup allocation failed: {t}", .{err});
        return context.empty(.internal_server_error);
    };
    defer allocator.free(markup_buffer);
    var raw_buffer: [80]u8 = undefined;
    const raw_bytes = std.fmt.bufPrint(&raw_buffer, "/p/{s}/raw", .{id}) catch unreachable;
    const show_raw = password.len == 0;
    var highlight_cached = false;
    const markup, const truncated = if (paste.kind == .image)
        imageMarkup(paste.content, paste.mime, if (show_raw) raw_bytes else null, markup_buffer)
    else cached: {
        const was_truncated = paste.content.len > html_preview_bytes;
        if (context.state.highlight_cache.get(id, markup_buffer)) |cached_markup| {
            highlight_cached = true;
            break :cached .{ cached_markup, was_truncated };
        }
        const rendered, const truncated = textMarkup(paste.content, paste.language, markup_buffer);
        context.state.highlight_cache.put(id, rendered);
        break :cached .{ rendered, truncated };
    };
    const trusted = TrustedMarkup.unsafeAssumeSanitized(markup) catch |err| {
        std.log.err("paste page trusted markup rejected: {t}", .{err});
        return context.empty(.internal_server_error);
    };
    const raw_url = ploof.Url.local(if (show_raw) raw_bytes else "/") catch unreachable;
    var expiry_buffer: [32]u8 = undefined;
    var size_buffer: [24]u8 = undefined;
    var timing_buffer: [24]u8 = undefined;
    var embed_url_buffer: [options.site_url.len + 80]u8 = undefined;
    const embed_url = pasteEmbedUrl(id, &embed_url_buffer) catch
        return withTiming(context, context.empty(.internal_server_error), started);
    const response = renderPage(context, PastePage, .{
        .id = id,
        .language = paste.language,
        .expires_at = formatUtc(&expiry_buffer, paste.expires_at),
        .markup = trusted,
        .image = paste.kind == .image,
        .truncated = truncated,
        .show_raw = show_raw,
        .raw_url = raw_url,
        .embed_url = embed_url,
        .size_bytes = paste.content.len,
        .size_label = formatBytes(&size_buffer, paste.content.len),
        .highlight_cached = highlight_cached,
        .processing_time = formatMillis(&timing_buffer, elapsedUs(context, started)),
    });
    return withTiming(context, response, started);
}

fn raw(context: *Context) Context.StreamResponse(RawProducer) {
    const started = startTimer(context);
    const id = context.request.param("id") orelse return rawError(context, .not_found, started);
    const password = context.request.headers.first("x-paste-password") orelse "";
    const paste = context.state.store.get(id, password, now(context)) catch |err| switch (err) {
        error.PasswordRequired, error.PasswordDenied => return rawError(context, .unauthorized, started),
        error.NotFound => return rawError(context, .not_found, started),
        error.Expired => {
            context.state.highlight_cache.remove(id);
            return rawError(context, .gone, started);
        },
        else => return rawError(context, .internal_server_error, started),
    };
    const content = paste.content;
    const size_bytes = content.len;
    const allocation = paste.allocation;
    const media_type = staticMediaType(paste.kind, paste.mime);
    var response = context.streamUnknown(.ok, ploof.response.media.octet_stream, RawProducer{
        .allocator = context.state.store.allocator,
        .allocation = allocation,
        .content = content,
    }, &.{});
    response.setMediaType(media_type) catch unreachable;
    response.setHeaderStatic("Cache-Control", "private, max-age=60") catch {};
    var size_buffer: [24]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buffer, "{d}", .{size_bytes}) catch unreachable;
    response.setHeader("X-Paste-Bytes", size) catch {};
    return withTiming(context, response, started);
}

const RawProducer = struct {
    allocator: std.mem.Allocator,
    allocation: ?[]u8,
    content: []const u8,
    cursor: usize = 0,

    pub fn poll(
        self: *RawProducer,
        output: []u8,
        _: ploof.response_stream.Wake,
    ) ploof.response_stream.PollError!ploof.response_stream.PollResult {
        if (self.cursor == self.content.len) return .{ .done = &.{} };
        const count = @min(output.len, self.content.len - self.cursor);
        @memcpy(output[0..count], self.content[self.cursor..][0..count]);
        self.cursor += count;
        return .{ .progress = count };
    }

    pub fn join(self: *RawProducer) void {
        if (self.allocation) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
            self.allocation = null;
        }
    }

    pub fn abort(_: *RawProducer) void {}
};

fn rawError(
    context: *Context,
    status: ploof.response.Status,
    started: std.Io.Timestamp,
) Context.StreamResponse(RawProducer) {
    var response = context.streamUnknown(.ok, ploof.response.media.octet_stream, RawProducer{
        .allocator = context.state.store.allocator,
        .allocation = null,
        .content = "",
    }, &.{});
    response.setStatus(status) catch unreachable;
    return withTiming(context, response, started);
}

fn getApi(context: *Context, _: ApiReadEndpoint.InputType) Response {
    const started = startTimer(context);
    const id = context.request.param("id") orelse return context.empty(.not_found);
    var paste = context.state.store.get(id, requestPassword(context), now(context)) catch |err| switch (err) {
        error.PasswordRequired, error.PasswordDenied => return jsonError(context, .unauthorized, "password required or wrong", started),
        error.NotFound => return jsonError(context, .not_found, "paste not found", started),
        error.Expired => {
            context.state.highlight_cache.remove(id);
            return jsonError(context, .gone, "paste expired", started);
        },
        else => return jsonError(context, .internal_server_error, "read failed", started),
    };
    defer paste.deinit(context.state.store.allocator);
    const preview = paste.content[0..@min(paste.content.len, api_preview_bytes)];
    var encoded: ?[]u8 = null;
    defer if (encoded) |bytes| context.state.store.allocator.free(bytes);
    const content = if (paste.kind == .image) encoded_image: {
        const length = std.base64.standard.Encoder.calcSize(preview.len);
        encoded = context.state.store.allocator.alloc(u8, length) catch
            return jsonError(context, .internal_server_error, "allocation failed", started);
        break :encoded_image std.base64.standard.Encoder.encode(encoded.?, preview);
    } else preview;
    var raw_buffer: [80]u8 = undefined;
    const raw_url = std.fmt.bufPrint(&raw_buffer, "/p/{s}/raw", .{id}) catch unreachable;
    var created_buffer: [24]u8 = undefined;
    var expires_buffer: [24]u8 = undefined;
    const response = context.json(.ok, .{
        .id = id,
        .kind = @tagName(paste.kind),
        .language = paste.language,
        .mime = paste.mime,
        .created_at = formatIsoUtc(&created_buffer, paste.created_at),
        .expires_at = formatIsoUtc(&expires_buffer, paste.expires_at),
        .content = content,
        .content_encoding = if (paste.kind == .image) "base64" else "utf-8",
        .truncated = preview.len != paste.content.len,
        .raw = raw_url,
        .size_bytes = paste.content.len,
        .processing_us = elapsedUs(context, started),
    }) catch context.empty(.internal_server_error);
    return withTiming(context, response, started);
}

fn openapi(context: *Context) Response {
    const started = startTimer(context);
    return withTiming(context, context.jsonStatic(.ok, @embedFile("openapi.json")), started);
}

fn stylesheet(context: *Context) Response {
    var response = context.textStatic(.ok, theme.css);
    response.setMediaType(.{ .value = "text/css; charset=utf-8" }) catch unreachable;
    response.setHeaderStatic("Cache-Control", "public, max-age=31536000, immutable") catch unreachable;
    return response;
}

fn favicon(context: *Context) Response {
    var response = context.bytesStatic(.ok, favicon_bytes);
    response.setMediaType(.{ .value = options.favicon_mime }) catch unreachable;
    response.setHeaderStatic("Cache-Control", "public, max-age=31536000, immutable") catch unreachable;
    return response;
}

const App = ploof.Application(.{
    .State = State,
    .response_body_bytes_max = response_bytes,
    .routes = .{
        ploof.get("/", home),
        ploof.post("/pastes", FormCreateEndpoint.handle(createFromForm)),
        ploof.post("/api/pastes", ApiCreateEndpoint.handle(createFromApi)),
        ploof.get("/api/pastes/:id", ApiReadEndpoint.handle(getApi)),
        ploof.get("/p/:id", show),
        ploof.post("/p/:id", UnlockEndpoint.handle(unlock)),
        ploof.get("/p/:id/raw", raw),
        ploof.get("/openapi.json", openapi),
        ploof.get(stylesheet_path, stylesheet),
        ploof.get(favicon_path, favicon),
    },
});
const Runner = ploof.ServerRunner(App, .{
    .workers_max = options.max_workers,
    // ponytail: fixed workspaces scale with max paste * slots * workers; raise
    // request_slots only after RSS and latency measurements justify the cost.
    .limits = .{
        .connection_slots = 64,
        .request_slots = 2,
        .receive_buffers = 64,
        .response_bytes_per_request = response_bytes,
        .submission_entries = 128,
        .completion_entries = 256,
    },
});
var runner: Runner align(@alignOf(Runner)) = Runner.init();

pub fn main(init: std.process.Init) !void {
    const key_text = init.environ_map.get("PLOP_MASTER_KEY") orelse {
        std.debug.print("PLOP_MASTER_KEY must be 64 hexadecimal characters\n", .{});
        return error.MissingMasterKey;
    };
    if (key_text.len != 64) return error.InvalidMasterKey;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, key_text) catch return error.InvalidMasterKey;
    const data_dir = init.environ_map.get("PLOP_DATA_DIR") orelse "data";
    try std.Io.Dir.cwd().createDirPath(init.io, data_dir);
    const directory = try std.Io.Dir.cwd().openDir(init.io, data_dir, .{ .iterate = true });
    const port = if (init.environ_map.get("PLOP_PORT")) |value|
        try std.fmt.parseUnsigned(u16, value, 10)
    else
        8080;
    const workers = if (init.environ_map.get("PLOP_WORKERS")) |value|
        try std.fmt.parseUnsigned(u16, value, 10)
    else
        1;
    if (workers == 0 or workers > options.max_workers) return error.InvalidWorkerCount;
    var state = State{
        .store = .{
            .allocator = init.gpa,
            .io = init.io,
            .dir = directory,
            .key = key,
            .max_bytes = max_paste_bytes,
        },
        .highlight_cache = .init(init.gpa, init.io),
    };
    defer state.highlight_cache.deinit();
    const sweeper = try std.Thread.spawn(.{ .stack_size = sweeper_stack_bytes }, sweepLoop, .{&state});
    sweeper.detach();
    runner.runOrExit(&state, .{
        .listener = .{ .address = .{ .ipv4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } } },
        .worker_count = workers,
    });
}

fn sweepLoop(state: *State) void {
    const interval = std.Io.Clock.Duration{ .clock = .awake, .raw = .fromSeconds(sweep_interval_seconds) };
    while (true) {
        interval.sleep(state.store.io) catch |err| {
            std.log.err("expiry sweeper stopped: {t}", .{err});
            return;
        };
        const timestamp = std.Io.Clock.real.now(state.store.io).toSeconds();
        const stats = state.store.sweepExpired(timestamp) catch |err| {
            std.log.err("expiry sweep failed: {t}", .{err});
            continue;
        };
        if (stats.deleted != 0) state.highlight_cache.clearAll();
        if (stats.deleted != 0 or stats.errors != 0)
            std.log.info("expiry sweep: scanned={d} deleted={d} errors={d}", .{
                stats.scanned,
                stats.deleted,
                stats.errors,
            });
    }
}

fn page(comptime name: []const u8, comptime View: type, comptime source: []const u8, comptime encoded_max: u32) type {
    @setEvalBranchQuota(100_000_000);
    return ploof.HtmlTemplate.Template(.{
        .View = View,
        .encoded_bytes_max = encoded_max,
        .source = ploof.HtmlSource.SourceSpec{
            .kind = .document,
            .graph_name = name,
            .file_path = name ++ ".html",
            .bytes = source,
        },
    });
}

fn renderPage(context: *Context, comptime Page: type, view: Page.View) Response {
    @setEvalBranchQuota(100_000_000);
    const output = context.response_body orelse {
        std.log.err("{s} response body workspace unavailable", .{@typeName(Page)});
        return context.empty(.internal_server_error);
    };
    var writer = TemplateWriter{ .writer = std.Io.Writer.fixed(output) };
    Page.render(&writer, view, &.{}) catch |err| {
        std.log.err("{s} render failed: {t}", .{ @typeName(Page), err });
        return context.empty(.internal_server_error);
    };
    return context.htmlBorrowed(.ok, output[0..writer.writer.end]);
}

fn renderPassword(context: *Context, bad: bool, started: std.Io.Timestamp) Response {
    var timing_buffer: [24]u8 = undefined;
    const id = context.request.param("id") orelse return context.empty(.not_found);
    var embed_url_buffer: [options.site_url.len + 80]u8 = undefined;
    const embed_url = pasteEmbedUrl(id, &embed_url_buffer) catch
        return withTiming(context, context.empty(.internal_server_error), started);
    return withTiming(context, renderPage(context, PasswordPage, .{
        .bad = bad,
        .embed_url = embed_url,
        .processing_time = formatMillis(&timing_buffer, elapsedUs(context, started)),
    }), started);
}

fn pasteEmbedUrl(id: []const u8, output: []u8) ![]const u8 {
    return std.fmt.bufPrint(output, "{s}/p/{s}", .{ options.site_url, id });
}

fn create(context: *Context, input: store_module.Put) !Id {
    var entropy: [6]u8 = undefined;
    for (0..16) |_| {
        try context.state.store.io.randomSecure(&entropy);
        const id = Id.fromAnimals(&entropy);
        context.state.store.put(id.slice(), input, now(context)) catch |err| {
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return id;
    }
    return error.IdCollision;
}

fn textMarkup(content: []const u8, language_name: []const u8, output: []u8) struct { []const u8, bool } {
    var length = @min(content.len, html_preview_bytes);
    while (!std.unicode.utf8ValidateSlice(content[0..length])) length -= 1;
    const rendered = highlight.render(content[0..length], language_name, output) catch
        highlight.render(content[0..length], "text", output) catch "preview unavailable";
    return .{ rendered, length != content.len };
}

fn imageMarkup(
    content: []const u8,
    mime: []const u8,
    raw_url: ?[]const u8,
    output: []u8,
) struct { []const u8, bool } {
    if (content.len > image_preview_bytes) {
        const url = raw_url orelse return .{ "protected image exceeds inline preview limit", true };
        const prefix = "<img alt=\"image paste\" src=\"";
        const suffix = "\">";
        if (prefix.len + url.len + suffix.len > output.len)
            return .{ "image preview unavailable", true };
        var cursor = copyAt(output, 0, prefix);
        cursor = copyAt(output, cursor, url);
        cursor = copyAt(output, cursor, suffix);
        return .{ output[0..cursor], false };
    }
    const preview = content[0..@min(content.len, image_preview_bytes)];
    const prefix = "<img alt=\"image paste\" src=\"data:";
    const separator = ";base64,";
    const suffix = "\">";
    const encoded_len = std.base64.standard.Encoder.calcSize(preview.len);
    const total = prefix.len + mime.len + separator.len + encoded_len + suffix.len;
    if (total > output.len) return .{ "image preview unavailable", true };
    var cursor: usize = 0;
    cursor = copyAt(output, cursor, prefix);
    cursor = copyAt(output, cursor, mime);
    cursor = copyAt(output, cursor, separator);
    _ = std.base64.standard.Encoder.encode(output[cursor..][0..encoded_len], preview);
    cursor += encoded_len;
    cursor = copyAt(output, cursor, suffix);
    return .{ output[0..cursor], preview.len != content.len };
}

fn jsonError(context: *Context, comptime status: ploof.response.Status, message: []const u8, started: std.Io.Timestamp) Response {
    const response = context.json(status, .{
        .error_message = message,
        .processing_us = elapsedUs(context, started),
    }) catch context.empty(.internal_server_error);
    return withTiming(context, response, started);
}

fn startTimer(context: *Context) std.Io.Timestamp {
    return std.Io.Clock.awake.now(context.state.store.io);
}

fn elapsedUs(context: *Context, started: std.Io.Timestamp) u64 {
    const value = started.durationTo(std.Io.Clock.awake.now(context.state.store.io)).toMicroseconds();
    return @intCast(@max(value, 0));
}

fn formatMillis(output: *[24]u8, microseconds: u64) []const u8 {
    if (microseconds < 1000)
        return std.fmt.bufPrint(output, "0.{d:0>3} ms", .{microseconds}) catch unreachable;
    const tenths = (microseconds +| 50) / 100;
    return std.fmt.bufPrint(output, "{d}.{d} ms", .{ tenths / 10, tenths % 10 }) catch unreachable;
}

fn formatUtc(output: *[32]u8, timestamp: i64) []const u8 {
    if (timestamp < 0) return "invalid date";
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    return std.fmt.bufPrint(output, "{d:0>2} {s} {d}, {d:0>2}:{d:0>2} UTC", .{
        month_day.day_index + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch unreachable;
}

fn formatIsoUtc(output: *[24]u8, timestamp: i64) []const u8 {
    if (timestamp < 0) return "invalid-date";
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(output, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

fn formatBytes(output: *[24]u8, bytes: usize) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(output, "{d} B", .{bytes}) catch unreachable;
    const unit: usize = if (bytes < 1024 * 1024) 1024 else 1024 * 1024;
    const tenths = (bytes * 10 + unit / 2) / unit;
    return std.fmt.bufPrint(output, "{d}.{d} {s}", .{
        tenths / 10,
        tenths % 10,
        if (unit == 1024) "KiB" else "MiB",
    }) catch unreachable;
}

fn withTiming(context: *Context, original: anytype, started: std.Io.Timestamp) @TypeOf(original) {
    var response = original;
    const microseconds = elapsedUs(context, started);
    var timing_buffer: [48]u8 = undefined;
    const timing = std.fmt.bufPrint(&timing_buffer, "app;dur={d}.{d:0>3}", .{
        microseconds / 1000,
        microseconds % 1000,
    }) catch unreachable;
    var microseconds_buffer: [24]u8 = undefined;
    const microseconds_text = std.fmt.bufPrint(&microseconds_buffer, "{d}", .{microseconds}) catch unreachable;
    response.setHeader("Server-Timing", timing) catch {};
    response.setHeader("X-Processing-Time-Us", microseconds_text) catch {};
    return response;
}

fn now(context: *Context) i64 {
    return std.Io.Clock.real.now(context.state.store.io).toSeconds();
}

const TemplateWriter = struct {
    writer: std.Io.Writer,

    pub fn write(self: *TemplateWriter, bytes: []const u8) error{WriteFailed}!void {
        self.writer.writeAll(bytes) catch return error.WriteFailed;
    }
};

fn allowedImageMime(value: []const u8) bool {
    return std.mem.eql(u8, value, "image/png") or std.mem.eql(u8, value, "image/jpeg") or
        std.mem.eql(u8, value, "image/gif") or std.mem.eql(u8, value, "image/webp");
}

fn requestPassword(context: *Context) []const u8 {
    return context.request.headers.first("x-paste-password") orelse "";
}

fn staticMediaType(kind: store_module.Kind, mime: []const u8) ploof.response.MediaType {
    if (kind == .text) return ploof.response.media.text;
    if (std.mem.eql(u8, mime, "image/png")) return .{ .value = "image/png" };
    if (std.mem.eql(u8, mime, "image/jpeg")) return .{ .value = "image/jpeg" };
    if (std.mem.eql(u8, mime, "image/gif")) return .{ .value = "image/gif" };
    if (std.mem.eql(u8, mime, "image/webp")) return .{ .value = "image/webp" };
    return ploof.response.media.octet_stream;
}

fn copyAt(output: []u8, start: usize, input: []const u8) usize {
    @memcpy(output[start..][0..input.len], input);
    return start + input.len;
}

const Id = struct {
    bytes: [64]u8 = undefined,
    len: u8,

    fn fromAnimals(entropy: *const [6]u8) Id {
        var id = Id{ .len = 0 };
        var indices = [3]usize{
            std.mem.readInt(u16, entropy[0..2], .little) % animals.len,
            std.mem.readInt(u16, entropy[2..4], .little) % animals.len,
            std.mem.readInt(u16, entropy[4..6], .little) % animals.len,
        };
        if (indices[1] == indices[0]) indices[1] = (indices[1] + 1) % animals.len;
        while (indices[2] == indices[0] or indices[2] == indices[1])
            indices[2] = (indices[2] + 1) % animals.len;
        const rendered = std.fmt.bufPrint(&id.bytes, "{s}-{s}-{s}", .{
            animals[indices[0]],
            animals[indices[1]],
            animals[indices[2]],
        }) catch unreachable;
        id.len = @intCast(rendered.len);
        return id;
    }

    fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn format(self: Id, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.slice());
    }
};

const animals = [_][]const u8{
    "alpaca", "ant",     "badger", "bat",     "bear",    "beaver", "bison", "boar",   "bobcat",  "buffalo", "camel",   "caribou", "cat",     "chamois", "cheetah", "cobra",
    "condor", "cougar",  "coyote", "crab",    "crane",   "crow",   "deer",  "dingo",  "dog",     "dolphin", "donkey",  "dove",    "duck",    "eagle",   "eel",     "elk",
    "emu",    "falcon",  "ferret", "finch",   "fox",     "frog",   "gecko", "goat",   "goose",   "gopher",  "gorilla", "gull",    "hare",    "hawk",    "heron",   "horse",
    "hyena",  "ibis",    "iguana", "impala",  "jackal",  "jaguar", "jay",   "koala",  "lemur",   "leopard", "lion",    "lizard",  "llama",   "lobster", "lynx",    "macaw",
    "marten", "mink",    "mole",   "monkey",  "moose",   "moth",   "mouse", "mule",   "newt",    "ocelot",  "octopus", "orca",    "ostrich", "otter",   "owl",     "ox",
    "panda",  "panther", "parrot", "pelican", "penguin", "pika",   "pony",  "puma",   "quail",   "rabbit",  "raccoon", "ram",     "raven",   "rhino",   "robin",   "salmon",
    "seal",   "shark",   "sheep",  "skink",   "skunk",   "sloth",  "snail", "snake",  "sparrow", "squid",   "stork",   "swan",    "tapir",   "tern",    "tiger",   "toad",
    "toucan", "trout",   "turtle", "vole",    "vulture", "walrus", "wasp",  "weasel", "whale",   "wolf",    "wombat",  "yak",     "zebra",   "zebu",    "stoat",   "geese",
};

test "animal IDs, MIME allowlist, and bounded previews" {
    @setEvalBranchQuota(100_000_000);
    const zero = [_]u8{0} ** 6;
    const maximum = [_]u8{0xff} ** 6;
    const first = Id.fromAnimals(&zero);
    const last = Id.fromAnimals(&maximum);
    try std.testing.expectEqualStrings("alpaca-ant-badger", first.slice());
    try std.testing.expectEqualStrings("geese-alpaca-ant", last.slice());
    try std.testing.expectEqual(@as(usize, 128), animals.len);

    try std.testing.expect(allowedImageMime("image/png"));
    try std.testing.expect(allowedImageMime("image/jpeg"));
    try std.testing.expect(allowedImageMime("image/gif"));
    try std.testing.expect(allowedImageMime("image/webp"));
    try std.testing.expect(!allowedImageMime("image/svg+xml"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", staticMediaType(.text, "ignored").value);
    try std.testing.expectEqualStrings("image/png", staticMediaType(.image, "image/png").value);
    try std.testing.expectEqualStrings("application/octet-stream", staticMediaType(.image, "other").value);

    var output: [1024]u8 = undefined;
    const image, const image_truncated = imageMarkup("\x89PNG", "image/png", null, &output);
    try std.testing.expect(!image_truncated);
    try std.testing.expectEqualStrings("<img alt=\"image paste\" src=\"data:image/png;base64,iVBORw==\">", image);
    const unavailable, const unavailable_truncated = imageMarkup("image", "image/png", null, output[0..8]);
    try std.testing.expect(unavailable_truncated);
    try std.testing.expectEqualStrings("image preview unavailable", unavailable);
    const large_image = try std.testing.allocator.alloc(u8, image_preview_bytes + 1);
    defer std.testing.allocator.free(large_image);
    const streamed, const streamed_truncated = imageMarkup(large_image, "image/png", "/p/otter-vole-tiger/raw", &output);
    try std.testing.expect(!streamed_truncated);
    try std.testing.expectEqualStrings("<img alt=\"image paste\" src=\"/p/otter-vole-tiger/raw\">", streamed);
    const protected, const protected_truncated = imageMarkup(large_image, "image/png", null, &output);
    try std.testing.expect(protected_truncated);
    try std.testing.expectEqualStrings("protected image exceeds inline preview limit", protected);

    const text, const text_truncated = textMarkup("<&", "text", &output);
    try std.testing.expect(!text_truncated);
    try std.testing.expectEqualStrings("&lt;&amp;", text);
    const large_text = try std.testing.allocator.alloc(u8, html_preview_bytes + 1);
    defer std.testing.allocator.free(large_text);
    @memset(large_text, 'x');
    const large_output = try std.testing.allocator.alloc(u8, highlight.rendered_bytes_max);
    defer std.testing.allocator.free(large_output);
    const large_markup, const large_truncated = textMarkup(large_text, "text", large_output);
    try std.testing.expect(large_truncated);
    try std.testing.expectEqual(@as(usize, html_preview_bytes), large_markup.len);
    const trusted = try TrustedMarkup.unsafeAssumeSanitized(large_markup);
    const page_output = try std.testing.allocator.alloc(u8, response_bytes);
    defer std.testing.allocator.free(page_output);
    var writer = TemplateWriter{ .writer = std.Io.Writer.fixed(page_output) };
    try PastePage.render(&writer, .{
        .id = "otter-vole-tiger",
        .language = "text",
        .expires_at = "01 Jan 1970, 00:01 UTC",
        .markup = trusted,
        .image = false,
        .truncated = true,
        .show_raw = true,
        .raw_url = try ploof.Url.local("/p/otter-vole-tiger/raw"),
        .embed_url = "http://127.0.0.1:8080/p/otter-vole-tiger",
        .size_bytes = large_text.len,
        .size_label = "128.0 KiB",
        .highlight_cached = false,
        .processing_time = "0.001 ms",
    }, &.{});
    try std.testing.expect(std.mem.indexOf(u8, page_output[0..writer.writer.end], "Preview truncated") != null);
}

test "page durations and dates are human readable" {
    var timing_buffer: [24]u8 = undefined;
    var date_buffer: [32]u8 = undefined;
    var iso_buffer: [24]u8 = undefined;
    var size_buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0.003 ms", formatMillis(&timing_buffer, 3));
    try std.testing.expectEqualStrings("7.9 ms", formatMillis(&timing_buffer, 7920));
    try std.testing.expectEqualStrings("01 Jul 2021, 17:11 UTC", formatUtc(&date_buffer, 1625159473));
    try std.testing.expectEqualStrings("2021-07-01T17:11:13Z", formatIsoUtc(&iso_buffer, 1625159473));
    try std.testing.expectEqualStrings("999 B", formatBytes(&size_buffer, 999));
    try std.testing.expectEqualStrings("1.5 KiB", formatBytes(&size_buffer, 1536));
}

test "OpenAPI document is valid JSON and describes timed paste routes" {
    const document = @embedFile("openapi.json");
    try std.testing.expect(try std.json.validate(std.testing.allocator, document));
    try std.testing.expect(std.mem.indexOf(u8, document, "\"/api/pastes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"/p/{id}/raw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "X-Processing-Time-Us") != null);
}

test "build branding appears in document shell" {
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, "<title>" ++ options.page_title ++ "</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, ">" ++ options.brand_name ++ "</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, theme.icon) != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, "<style>") == null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, stylesheet_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, favicon_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, "property=\"og:title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, "property=\"og:url\" content=\"" ++ options.site_url ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_shell_start, "name=\"twitter:card\" content=\"summary\"") != null);
}

test "composer accepts clipboard images through the existing file input" {
    try std.testing.expect(std.mem.indexOf(u8, home_script, "addEventListener('paste'") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_script, "item?.getAsFile()") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_script, "new DataTransfer()") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_script, "i.dispatchEvent(new Event('change'))") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_script, "t.value='';t.hidden=true;p.hidden=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_script, "URL.createObjectURL(file)") != null);
}

test "paste title copies the page URL" {
    try std.testing.expect(std.mem.indexOf(u8, paste_script, "navigator.clipboard.writeText(location.href)") != null);
    try std.testing.expect(std.mem.indexOf(u8, paste_script, "dataset.copied") != null);
    try std.testing.expect(std.mem.indexOf(u8, paste_script, "querySelector('#copy-link')") != null);
    try std.testing.expect(std.mem.indexOf(u8, paste_script, "aria-label','Link copied'") != null);
}

test "language menu includes every zhl grammar after preferred choices" {
    try std.testing.expectEqual(full_grammars.languages.len + 2, std.mem.count(u8, language_options, "<option"));
    try std.testing.expect(std.mem.startsWith(u8, language_options, "<option value=\"auto\" selected>Auto detect</option>"));
    var previous: usize = 0;
    inline for (preferred_languages) |name| {
        const needle = std.fmt.comptimePrint("value=\"{s}\"", .{name});
        const position = std.mem.indexOf(u8, language_options, needle).?;
        try std.testing.expect(position >= previous);
        previous = position;
    }
    try std.testing.expect(std.mem.indexOf(u8, language_options, "value=\"csharp\"").? > previous);
    try std.testing.expect(std.mem.indexOf(u8, language_options, "value=\"actionscript-3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, language_options, ">Zig</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, language_options, ">Zig 0.16</option>") == null);
}

test "raw producer streams bounded chunks and releases plaintext" {
    const allocation = try std.testing.allocator.dupe(u8, "raw bytes");
    var producer = RawProducer{
        .allocator = std.testing.allocator,
        .allocation = allocation,
        .content = allocation,
    };
    var first: [4]u8 = undefined;
    const first_result = try producer.poll(&first, undefined);
    try std.testing.expectEqual(@as(usize, 4), first_result.progress);
    try std.testing.expectEqualStrings("raw ", &first);
    var second: [16]u8 = undefined;
    const second_result = try producer.poll(&second, undefined);
    try std.testing.expectEqual(@as(usize, 5), second_result.progress);
    try std.testing.expectEqualStrings("bytes", second[0..5]);
    try std.testing.expect((try producer.poll(&second, undefined)) == .done);
    producer.join();
    try std.testing.expect(producer.allocation == null);
}

test "Ploof routes create and retrieve encrypted pastes" {
    const testing = @import("ploof_testing");
    const Client = testing.ConfiguredClient(App, .{
        .request_bytes_max = 4096,
        .response_bytes_max = 64 * 1024,
        .response_capture_bytes_max = 64 * 1024,
    });
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var state = State{
        .store = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .dir = temporary.dir,
            .key = [_]u8{0x33} ** 32,
            .max_bytes = max_paste_bytes,
            .password_params = .{ .t = 1, .m = 8, .p = 1 },
        },
        .highlight_cache = .init(std.testing.allocator, std.testing.io),
    };
    defer state.highlight_cache.deinit();
    const storage = try std.testing.allocator.create(Client.Storage);
    defer std.testing.allocator.destroy(storage);
    storage.* = .{};
    var client = try Client.init(&state, storage);
    defer client.deinit() catch unreachable;
    const homepage = try client.request(.{ .method = "GET", .target = "/" });
    try std.testing.expect(std.mem.indexOf(u8, homepage.body, "<b>SSR</b>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage.body, "type=\"file\"") != null);
    try std.testing.expect(homepage.header("Server-Timing") != null);
    const styles = try client.request(.{ .method = "GET", .target = stylesheet_path });
    try std.testing.expectEqual(@as(u16, 200), styles.status);
    try std.testing.expectEqualStrings(theme.css, styles.body);
    try std.testing.expectEqualStrings(
        "public, max-age=31536000, immutable",
        styles.header("Cache-Control") orelse "",
    );
    const icon = try client.request(.{ .method = "GET", .target = favicon_path });
    try std.testing.expectEqual(@as(u16, 200), icon.status);
    try std.testing.expectEqualStrings(favicon_bytes, icon.body);
    try std.testing.expectEqualStrings(options.favicon_mime, icon.header("Content-Type") orelse "");
    try std.testing.expectEqualStrings(
        "public, max-age=31536000, immutable",
        icon.header("Cache-Control") orelse "",
    );
    const spec = try client.request(.{ .method = "GET", .target = "/openapi.json" });
    try std.testing.expectEqual(@as(u16, 200), spec.status);
    try std.testing.expect(std.mem.startsWith(u8, spec.body, "{"));
    try std.testing.expect(spec.header("X-Processing-Time-Us") != null);
    const invalid_form = try client.request(.{
        .method = "POST",
        .target = "/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        .body = "content=x&language=text&password=&ttl_days=0",
    });
    try std.testing.expectEqual(@as(u16, 400), invalid_form.status);
    const form_created = try client.request(.{
        .method = "POST",
        .target = "/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        .body = "content=hello+form&language=text&password=&ttl_days=7",
    });
    try std.testing.expectEqual(@as(u16, 303), form_created.status);
    try std.testing.expect(std.mem.startsWith(u8, form_created.header("location") orelse "", "/p/"));
    try std.testing.expect(form_created.header("Server-Timing") != null);
    const created = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"const std = @import(\\\"std\\\");\",\"language\":\"zig\",\"ttl_seconds\":60}",
    });
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try std.testing.expect(std.mem.indexOf(u8, created.body, "\"processing_us\":") != null);
    try std.testing.expect(created.header("X-Processing-Time-Us") != null);
    const marker = "\"id\":\"";
    const start = (std.mem.indexOf(u8, created.body, marker) orelse return error.TestUnexpectedResult) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, created.body, start, '"') orelse return error.TestUnexpectedResult;
    const generated_id = created.body[start..end];
    var words = std.mem.splitScalar(u8, generated_id, '-');
    var word_count: usize = 0;
    while (words.next()) |word| {
        word_count += 1;
        var found = false;
        for (animals) |animal| found = found or std.mem.eql(u8, word, animal);
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 3), word_count);
    var page_target: [80]u8 = undefined;
    const page_path = try std.fmt.bufPrint(&page_target, "/p/{s}", .{created.body[start..end]});
    var api_target: [96]u8 = undefined;
    const api_path = try std.fmt.bufPrint(&api_target, "/api/pastes/{s}", .{created.body[start..end]});
    const shown = try client.request(.{ .method = "GET", .target = page_path });
    try std.testing.expectEqual(@as(u16, 200), shown.status);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "zhl-") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "zhl fresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "property=\"og:title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "id=\"copy-link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "Copy link") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "navigator.clipboard.writeText(location.href)") != null);
    var expected_embed_url_buffer: [options.site_url.len + 80]u8 = undefined;
    const expected_embed_url = try std.fmt.bufPrint(&expected_embed_url_buffer, "{s}{s}", .{ options.site_url, page_path });
    try std.testing.expect(std.mem.indexOf(u8, shown.body, expected_embed_url) != null);
    const shown_again = try client.request(.{ .method = "GET", .target = page_path });
    try std.testing.expectEqual(@as(u16, 200), shown_again.status);
    try std.testing.expect(std.mem.indexOf(u8, shown_again.body, "zhl cache hit") != null);
    const fetched = try client.request(.{ .method = "GET", .target = api_path });
    try std.testing.expectEqual(@as(u16, 200), fetched.status);
    try std.testing.expect(std.mem.indexOf(u8, fetched.body, "const std") != null);
    try std.testing.expect(fetched.header("Server-Timing") != null);

    const protected = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"hidden\",\"password\":\"otter\",\"ttl_seconds\":60}",
    });
    const protected_start = (std.mem.indexOf(u8, protected.body, marker) orelse return error.TestUnexpectedResult) + marker.len;
    const protected_end = std.mem.indexOfScalarPos(u8, protected.body, protected_start, '"') orelse return error.TestUnexpectedResult;
    var protected_target: [96]u8 = undefined;
    const protected_path = try std.fmt.bufPrint(&protected_target, "/api/pastes/{s}", .{protected.body[protected_start..protected_end]});
    var protected_page_target: [96]u8 = undefined;
    const protected_page_path = try std.fmt.bufPrint(&protected_page_target, "/p/{s}", .{protected.body[protected_start..protected_end]});
    const denied = try client.request(.{ .method = "GET", .target = protected_path });
    try std.testing.expectEqual(@as(u16, 401), denied.status);
    const password_page = try client.request(.{ .method = "GET", .target = protected_page_path });
    try std.testing.expectEqual(@as(u16, 200), password_page.status);
    try std.testing.expect(std.mem.indexOf(u8, password_page.body, "Protected paste") != null);
    try std.testing.expect(std.mem.indexOf(u8, password_page.body, "Argon2id") != null);
    const wrong_page = try client.request(.{
        .method = "POST",
        .target = protected_page_path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        .body = "password=wrong",
    });
    try std.testing.expect(std.mem.indexOf(u8, wrong_page.body, "Wrong password") != null);
    const unlocked_page = try client.request(.{
        .method = "POST",
        .target = protected_page_path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        .body = "password=otter",
    });
    try std.testing.expectEqual(@as(u16, 200), unlocked_page.status);
    try std.testing.expect(std.mem.indexOf(u8, unlocked_page.body, "hidden") != null);
    const unlocked = try client.request(.{
        .method = "GET",
        .target = protected_path,
        .headers = &.{.{ .name = "X-Paste-Password", .value = "otter" }},
    });
    try std.testing.expectEqual(@as(u16, 200), unlocked.status);
    try std.testing.expect(std.mem.indexOf(u8, unlocked.body, "\"size_bytes\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, unlocked.body, "\"processing_us\":") != null);

    const image = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"iVBORw==\",\"kind\":\"image\",\"mime\":\"image/png\",\"ttl_seconds\":60}",
    });
    const image_start = (std.mem.indexOf(u8, image.body, marker) orelse return error.TestUnexpectedResult) + marker.len;
    const image_end = std.mem.indexOfScalarPos(u8, image.body, image_start, '"') orelse return error.TestUnexpectedResult;
    var image_target: [96]u8 = undefined;
    const image_api_path = try std.fmt.bufPrint(&image_target, "/api/pastes/{s}", .{image.body[image_start..image_end]});
    var image_page_target: [80]u8 = undefined;
    const image_page_path = try std.fmt.bufPrint(&image_page_target, "/p/{s}", .{image.body[image_start..image_end]});
    const image_page = try client.request(.{ .method = "GET", .target = image_page_path });
    try std.testing.expect(std.mem.indexOf(u8, image_page.body, "data:image/png;base64,iVBORw==") != null);
    const image_api = try client.request(.{ .method = "GET", .target = image_api_path });
    try std.testing.expect(std.mem.indexOf(u8, image_api.body, "\"mime\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_api.body, "\"content\":\"iVBORw==\"") != null);

    const defaults = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"defaults\"}",
    });
    try std.testing.expectEqual(@as(u16, 201), defaults.status);
    try std.testing.expect(std.mem.indexOf(u8, defaults.body, "\"expires_in\":604800") != null);
    const invalid_ttl = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"x\",\"ttl_seconds\":0}",
    });
    try std.testing.expectEqual(@as(u16, 400), invalid_ttl.status);
    try std.testing.expect(std.mem.indexOf(u8, invalid_ttl.body, "\"processing_us\":") != null);
    const invalid_kind = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"x\",\"kind\":\"file\"}",
    });
    try std.testing.expectEqual(@as(u16, 400), invalid_kind.status);
    const invalid_mime = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"eA==\",\"kind\":\"image\",\"mime\":\"image/svg+xml\"}",
    });
    try std.testing.expectEqual(@as(u16, 400), invalid_mime.status);
    const invalid_base64 = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"%%%\",\"kind\":\"image\",\"mime\":\"image/png\"}",
    });
    try std.testing.expectEqual(@as(u16, 400), invalid_base64.status);
    const long_password = try client.request(.{
        .method = "POST",
        .target = "/api/pastes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"content\":\"x\",\"password\":\"" ++ ("x" ** 257) ++ "\"}",
    });
    try std.testing.expectEqual(@as(u16, 400), long_password.status);
    const missing = try client.request(.{ .method = "GET", .target = "/api/pastes/missing-animal-path" });
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "paste not found") != null);
}
