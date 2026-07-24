const std = @import("std");
const zhl = @import("zhl");
const selected = @import("zhl_grammars_selected");
const options = @import("shard_options");

const RenderMode = enum { html };
threadlocal var active_writer: ?*std.Io.Writer = null;

fn render(
    language_id: u32,
    source_ptr: [*]const u8,
    source_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
) callconv(.c) isize {
    var writer = std.Io.Writer.fixed(output_ptr[0..output_len]);
    active_writer = &writer;
    defer active_writer = null;
    const status = selected.dispatchHighlight(
        language_id,
        source_ptr[0..source_len],
        RenderMode.html,
        renderSelected,
    );
    return if (status == 0) @intCast(writer.end) else -@as(isize, @intCast(status));
}

fn renderSelected(comptime grammar: anytype, source: []const u8, comptime mode: RenderMode) u32 {
    _ = mode;
    renderGrammar(grammar, source, active_writer orelse return 100) catch return 100;
    return 0;
}

fn renderGrammar(comptime grammar: anytype, source: []const u8, writer: *std.Io.Writer) !void {
    const Engine = zhl.Engine(grammar, .{
        .max_line_bytes = 512 * 1024,
        .max_tokens_per_line = 4096,
        .max_regex_vm_stack = 4096,
    });
    var engine = Engine.init(.{});
    var state = Engine.State.initial();
    var scratch = Engine.Scratch.init();
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!first) try writer.writeByte('\n');
        first = false;
        var sink = zhl.sinks.TokenBuffer(4096).init();
        const result = try engine.highlightLine(line, state, &scratch, &sink);
        state = result.end_state;
        try zhl.renderers.renderHtmlLine(writer, line, sink.slice());
    }
}

comptime {
    @export(&render, .{ .name = std.fmt.comptimePrint("plop_zhl_render_{d}", .{options.shard}) });
}
