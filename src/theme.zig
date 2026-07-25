const std = @import("std");
const options = @import("build_options");

pub const icon = @embedFile("brand_logo");

pub const css = @embedFile("tokens.css") ++ common;

const common =
    \\*{box-sizing:border-box}
    \\html,body{overflow-x:clip}
    \\body{margin:0;min-height:100vh;background:var(--canvas);color:var(--ink);font:400 var(--text-base)/1.6 var(--font-body);text-rendering:optimizeLegibility}
    \\.shell{width:calc(100% - 2rem);max-width:70rem;margin-inline:auto;padding-block:var(--space-5) var(--space-7)}
    \\.site-header{display:flex;align-items:center;justify-content:space-between;gap:var(--space-4);min-width:0;margin-bottom:var(--space-7);min-height:2.75rem}
    \\.brand{display:inline-flex;align-items:center;gap:var(--space-2);color:var(--ink-strong);font:700 var(--text-lg)/1 var(--font-display);letter-spacing:-.025em;text-decoration:none}
    \\.logo{display:block;flex:0 0 auto;width:1.5rem;height:1.5rem;fill:var(--accent)}
    \\.site-nav{display:flex;flex:0 0 auto;align-items:center;gap:var(--space-5);font-size:var(--text-sm)}
    \\a{color:var(--accent);text-decoration-thickness:.08em;text-underline-offset:.22em}
    \\.compose,.panel,.editor{min-width:0}
    \\.eyebrow{margin:0 0 var(--space-2);color:var(--accent);font-size:var(--text-sm);font-weight:700;letter-spacing:.1em;text-transform:uppercase}
    \\h1,h2{font-family:var(--font-display);color:var(--ink-strong);letter-spacing:-.025em}
    \\h1{min-width:0;margin:0;font-size:clamp(2.1rem,6vw,3.45rem);line-height:1.06;overflow-wrap:anywhere}h2{margin:0;font-size:var(--text-md);line-height:1.2}
    \\.panel{overflow:hidden;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius-panel);box-shadow:0 1rem 2.5rem var(--shadow)}
    \\.panel-header{display:flex;align-items:center;justify-content:space-between;gap:var(--space-4);padding:var(--space-4) var(--space-5);border-bottom:1px solid var(--line)}
    \\.panel-header p{margin:var(--space-1) 0 0;color:var(--muted);font-size:var(--text-sm)}
    \\.field-heading{display:flex;align-items:center;justify-content:space-between;gap:var(--space-4);padding:var(--space-4) var(--space-5) var(--space-2);font-size:var(--text-sm)}
    \\.field-heading label{color:var(--ink-strong);font-weight:700}.field-heading span{color:var(--muted)}
    \\textarea{display:block;width:100%;min-height:clamp(20rem,50vh,34rem);resize:vertical;border:0;border-radius:0;outline:0;padding:var(--space-4) var(--space-5) var(--space-5);background:transparent;color:var(--ink);font:400 .9rem/1.65 var(--font-code);tab-size:4}
    \\textarea[hidden]{display:none}
    \\textarea::placeholder{color:var(--muted)}
    \\.image-preview{display:block;width:100%;height:clamp(20rem,50vh,34rem);object-fit:contain;padding:var(--space-4) var(--space-5) var(--space-5)}.image-preview[hidden]{display:none}
    \\.editor:focus-within .field-heading label{color:var(--accent)}
    \\.options{position:relative;display:grid;gap:var(--space-3);margin:0;padding:var(--space-4) var(--space-5);border:0;border-top:1px solid var(--line);background:var(--surface-raised)}
    \\.options legend{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
    \\.control{display:grid;align-content:end;gap:var(--space-2);min-width:0;color:var(--ink);font-size:var(--text-sm);font-weight:700}
    \\.control>span{display:inline-flex;align-items:baseline;gap:var(--space-1)}
    \\.control small{color:var(--muted);font-size:inherit;font-weight:400}
    \\input,select,button{width:100%;min-height:2.75rem;border:1px solid var(--line-strong);border-radius:var(--radius-control);outline:2px solid transparent;outline-offset:1px;background:var(--surface);color:var(--ink);font:400 .9rem var(--font-body);padding:var(--space-2) var(--space-3)}
    \\.select-wrap{position:relative;min-width:0}.select-wrap::after{content:"";position:absolute;top:50%;right:var(--space-3);width:.45rem;height:.45rem;border-right:1px solid var(--muted);border-bottom:1px solid var(--muted);transform:translateY(-70%) rotate(45deg);pointer-events:none}
    \\select{appearance:none;padding-right:var(--space-6)}
    \\input[type=file]{padding:var(--space-1);overflow:hidden;color:var(--muted)}
    \\input::file-selector-button{min-height:2rem;margin-right:var(--space-3);border:0;border-radius:.35rem;background:var(--accent-soft);color:var(--ink-strong);font:700 var(--text-sm) var(--font-body);padding:var(--space-1) var(--space-3);cursor:pointer}
    \\button{align-self:end;border-color:var(--action);background:var(--action);color:var(--action-ink);font-weight:700;cursor:pointer;white-space:nowrap;transition:transform var(--duration-fast) var(--ease-out),opacity var(--duration-fast) var(--ease-out)}
    \\button:active{transform:translateY(1px)}button:disabled,input:disabled,select:disabled{opacity:.5;cursor:not-allowed}
    \\:focus-visible{outline-color:var(--accent)}input[aria-invalid=true]{border-color:var(--danger)}
    \\.form-status{min-height:1lh;margin:0;padding:0 var(--space-5) var(--space-4);background:var(--surface-raised);color:var(--danger);font-size:var(--text-sm)}
    \\.unlock{max-width:42rem;margin:12vh auto 0;padding:var(--space-6)}.unlock-copy{max-width:34rem}.unlock-copy>p:last-child{margin:var(--space-3) 0 0;color:var(--muted)}
    \\.password{display:grid;gap:var(--space-3);margin-top:var(--space-5)}
    \\.notice{margin:0;padding:var(--space-3) var(--space-5);border-top:1px solid var(--line);color:var(--muted);font-size:var(--text-sm)}.error{color:var(--danger)}
    \\.paste-header{display:flex;align-items:flex-end;justify-content:space-between;gap:var(--space-5);padding:var(--space-5)}
    \\.paste-header h1{min-width:0;margin:0;font:700 clamp(1.55rem,4vw,2.45rem)/1.1 var(--font-code);overflow-wrap:anywhere}
    \\.paste-title{display:inline-flex;align-items:center;gap:.35em;max-width:100%;width:auto;min-height:0;margin:0;padding:.1em .15em .1em 0;border:0;border-radius:var(--radius-control);background:transparent;color:var(--ink-strong);font:inherit;letter-spacing:inherit;line-height:inherit;text-align:left;white-space:normal;cursor:pointer;transition:color var(--duration-fast) var(--ease-out)}
    \\.paste-title-text{min-width:0;overflow-wrap:anywhere}
    \\.paste-title-icon{flex:0 0 auto;width:.55em;height:.55em;color:var(--muted);transition:opacity var(--duration-fast) var(--ease-out),color var(--duration-fast) var(--ease-out),transform var(--duration-fast) var(--ease-out)}
    \\.paste-title-done{display:none;color:var(--accent)}
    \\.paste-title[data-copied] .paste-title-copy{display:none}.paste-title[data-copied] .paste-title-done{display:block}.paste-title[data-copied]{color:var(--accent)}
    \\.paste-actions{display:flex;flex-wrap:wrap;align-items:center;gap:var(--space-2);min-width:0}.paste-actions a{display:inline-flex;align-items:center;justify-content:center;min-height:2.75rem;border:1px solid var(--line-strong);border-radius:var(--radius-control);padding:var(--space-2) var(--space-3);font-size:var(--text-sm);font-weight:700;text-decoration:none;white-space:nowrap}
    \\.paste-actions .primary-link{border-color:var(--action);background:var(--action);color:var(--action-ink)}
    \\.paste-facts{display:grid;margin:0;border-block:1px solid var(--line);background:var(--surface-raised)}
    \\.paste-facts div{padding:var(--space-3) var(--space-5);border-bottom:1px solid var(--line)}.paste-facts div:last-child{border-bottom:0}
    \\.paste-facts dt{color:var(--muted);font-size:var(--text-sm)}.paste-facts dd{margin:var(--space-1) 0 0;color:var(--ink-strong);font-size:.9rem;font-variant-numeric:tabular-nums}
    \\.source-frame{background:var(--surface)}pre{max-height:72vh;margin:0;overflow:auto;padding:var(--space-5);font:400 .875rem/1.4 var(--font-code);tab-size:4;overscroll-behavior:contain}pre code{font:inherit}
    \\.image{display:grid;place-items:center;min-height:16rem;padding:var(--space-5)}.image img{display:block;max-width:100%;max-height:72vh;border-radius:var(--radius-control)}
    \\.page-stats{display:flex;flex-wrap:wrap;gap:var(--space-2) var(--space-5);margin-top:var(--space-4);color:var(--muted);font-size:var(--text-sm);font-variant-numeric:tabular-nums}
    \\.page-stats>span{display:inline-flex;align-items:baseline;gap:var(--space-1)}
    \\.page-stats b{color:var(--ink);font-weight:700}
    \\.zhl-plain,.zhl-punctuation{color:var(--ink)}
    \\.zhl-comment,.zhl-doc-comment,.zhl-container-doc-comment{color:var(--syntax-comment)}
    \\.zhl-string,.zhl-multiline-string,.zhl-char{color:var(--syntax-string)}
    \\.zhl-escape,.zhl-format-placeholder{color:var(--syntax-escape)}
    \\.zhl-number-integer,.zhl-number-float{color:var(--syntax-number)}
    \\.zhl-keyword{color:var(--syntax-keyword)}.zhl-operator{color:var(--syntax-operator)}
    \\.zhl-builtin{color:var(--syntax-builtin)}.zhl-function{color:var(--syntax-function)}.zhl-type-name{color:var(--syntax-type)}
    \\.zhl-field,.zhl-parameter{color:var(--syntax-field)}.zhl-label{color:var(--syntax-label)}
    \\.zhl-invalid{color:var(--syntax-invalid);text-decoration:underline wavy currentColor}
    \\@media(hover:hover){a:hover{color:var(--accent-hover)}button:hover{opacity:.86}.paste-title:hover{opacity:1;color:var(--accent)}.paste-title-icon{opacity:0}.paste-title:hover .paste-title-icon,.paste-title:focus-visible .paste-title-icon,.paste-title[data-copied] .paste-title-icon{opacity:1;color:var(--accent)}.paste-title:hover .paste-title-icon{transform:translateY(-.04em)}.paste-actions a:hover{border-color:var(--accent);color:var(--ink-strong)}.paste-actions .primary-link:hover{color:var(--action-ink);opacity:.86}}
    \\@media(min-width:40rem){.shell{padding-top:var(--space-6)}.options{grid-template-columns:repeat(2,minmax(0,1fr))}.options button{grid-column:1/-1}.password{grid-template-columns:1fr auto}.password button{width:auto}.paste-facts{grid-template-columns:repeat(3,1fr)}.paste-facts div{border-right:1px solid var(--line);border-bottom:0}.paste-facts div:last-child{border-right:0}}
    \\@media(min-width:56rem){.options{grid-template-columns:minmax(11rem,1.3fr) minmax(7.5rem,.7fr) minmax(7.5rem,.7fr) minmax(11rem,1fr) auto}.options button{grid-column:auto;width:auto}.paste-header{padding:var(--space-6) var(--space-5)}}
    \\@media(max-width:39.99rem){.shell{width:calc(100% - 1rem)}.site-header{margin-bottom:var(--space-6);padding-inline:.5rem}.panel-header,.field-heading,.paste-header{align-items:flex-start}.paste-header{flex-direction:column}.paste-actions{width:100%}.paste-actions a{flex:1}.page-stats{padding-inline:.5rem}.unlock{margin-top:4vh;padding:var(--space-5)}}
    \\@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition-duration:.01ms!important;animation-duration:.01ms!important;animation-iteration-count:1!important}}
;

test "selected build theme and icon include responsive light-dark states" {
    const zhl = @import("zhl");
    try std.testing.expect(std.mem.indexOf(u8, css, "Hallmark · genre: modern-minimal") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--font-body:\"Inter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "textarea{display:block;width:100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "textarea[hidden]{display:none}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".image-preview[hidden]{display:none}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "border-radius:0;outline:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".control small{color:var(--muted);font-size:inherit;font-weight:400}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".page-stats b{color:var(--ink);font-weight:700}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".paste-title{display:inline-flex") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".paste-title[data-copied]") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "select{appearance:none;padding-right:var(--space-6)}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "translateX") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "prefers-color-scheme") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ":focus-visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@media(min-width:40rem)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "prefers-reduced-motion") != null);
    var selector_buffer: [64]u8 = undefined;
    inline for (std.meta.fields(zhl.StyleId)) |field| {
        const style: zhl.StyleId = @enumFromInt(field.value);
        const selector = try std.fmt.bufPrint(&selector_buffer, ".{s}", .{style.cssClass()});
        try std.testing.expect(std.mem.indexOf(u8, css, selector) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, icon, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, if (std.mem.eql(u8, options.theme, "paper")) "[data-theme=\"paper\"]" else "[data-theme=\"neon\"]") != null);
}
