const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const magic = "PLOP\x00\x02\r\n";
const expiry_aad = "PLOP expiry v2";
const expiry_bytes = @sizeOf(i64);
const expiry_header_bytes = magic.len + Aead.nonce_length + Aead.tag_length + expiry_bytes;
const outer_bytes = expiry_header_bytes + Aead.nonce_length + Aead.tag_length;
const metadata_bytes = 8 + 8 + 1 + 1 + 1 + 1 + 16 + 32 + 4;
pub const password_bytes_max = 256;

pub const Kind = enum(u8) { text, image };

pub const Put = struct {
    content: []const u8,
    language: []const u8 = "text",
    mime: []const u8 = "text/plain; charset=utf-8",
    password: []const u8 = "",
    ttl_seconds: u32 = 7 * 24 * 60 * 60,
    kind: Kind = .text,
};

pub const Paste = struct {
    allocation: []u8,
    content: []const u8,
    language: []const u8,
    mime: []const u8,
    created_at: i64,
    expires_at: i64,
    kind: Kind,

    pub fn deinit(self: *Paste, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.allocation);
        allocator.free(self.allocation);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidId,
    InvalidInput,
    PasteTooLarge,
    NotFound,
    Expired,
    PasswordRequired,
    PasswordDenied,
    Corrupt,
};

pub const SweepStats = struct {
    scanned: u64 = 0,
    deleted: u64 = 0,
    errors: u64 = 0,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    key: [Aead.key_length]u8,
    max_bytes: usize,
    password_params: std.crypto.pwhash.argon2.Params = .owasp_2id,
    mutex: std.Io.Mutex = .init,

    pub fn put(self: *Store, id: []const u8, input: Put, now: i64) !void {
        if (!validId(id)) return Error.InvalidId;
        if (input.content.len > self.max_bytes) return Error.PasteTooLarge;
        if (input.language.len > 32 or input.mime.len > 96 or
            input.password.len > password_bytes_max or input.ttl_seconds == 0)
            return Error.InvalidInput;
        if (input.kind == .text and !std.unicode.utf8ValidateSlice(input.content))
            return Error.InvalidInput;

        const expires = std.math.add(i64, now, input.ttl_seconds) catch return Error.InvalidInput;
        const plain_len = metadata_bytes + input.language.len + input.mime.len + input.content.len;
        const plain = try self.allocator.alloc(u8, plain_len);
        defer {
            std.crypto.secureZero(u8, plain);
            self.allocator.free(plain);
        }
        var cursor: usize = 0;
        writeInt(i64, plain, &cursor, now);
        writeInt(i64, plain, &cursor, expires);
        plain[cursor] = @intFromEnum(input.kind);
        cursor += 1;
        plain[cursor] = @intCast(input.language.len);
        cursor += 1;
        plain[cursor] = @intCast(input.mime.len);
        cursor += 1;
        plain[cursor] = @intFromBool(input.password.len != 0);
        cursor += 1;
        const salt = plain[cursor..][0..16];
        try self.io.randomSecure(salt);
        cursor += 16;
        const password_hash = plain[cursor..][0..32];
        if (input.password.len != 0) {
            try std.crypto.pwhash.argon2.kdf(
                self.allocator,
                password_hash,
                input.password,
                salt,
                self.password_params,
                .argon2id,
                self.io,
            );
        } else @memset(password_hash, 0);
        cursor += 32;
        writeInt(u32, plain, &cursor, @intCast(input.content.len));
        cursor = copyAt(plain, cursor, input.language);
        cursor = copyAt(plain, cursor, input.mime);
        _ = copyAt(plain, cursor, input.content);

        const file = try self.allocator.alloc(u8, outer_bytes + plain.len);
        defer self.allocator.free(file);
        @memcpy(file[0..magic.len], magic);

        const expiry_nonce_start = magic.len;
        const expiry_tag_start = expiry_nonce_start + Aead.nonce_length;
        const expiry_cipher_start = expiry_tag_start + Aead.tag_length;
        const expiry_nonce = file[expiry_nonce_start..][0..Aead.nonce_length];
        try self.io.randomSecure(expiry_nonce);
        var expiry_plain: [expiry_bytes]u8 = undefined;
        std.mem.writeInt(i64, &expiry_plain, expires, .little);
        var expiry_tag: [Aead.tag_length]u8 = undefined;
        Aead.encrypt(
            file[expiry_cipher_start..][0..expiry_bytes],
            &expiry_tag,
            &expiry_plain,
            expiry_aad,
            expiry_nonce[0..Aead.nonce_length].*,
            self.key,
        );
        @memcpy(file[expiry_tag_start..][0..Aead.tag_length], &expiry_tag);

        const content_nonce_start = expiry_header_bytes;
        const content_tag_start = content_nonce_start + Aead.nonce_length;
        const content_nonce = file[content_nonce_start..][0..Aead.nonce_length];
        try self.io.randomSecure(content_nonce);
        var content_tag: [Aead.tag_length]u8 = undefined;
        Aead.encrypt(
            file[outer_bytes..],
            &content_tag,
            plain,
            magic,
            content_nonce[0..Aead.nonce_length].*,
            self.key,
        );
        @memcpy(file[content_tag_start..][0..Aead.tag_length], &content_tag);

        var name: [80]u8 = undefined;
        var temp: [84]u8 = undefined;
        const path = fileName(id, &name);
        const temp_path = tempName(id, &temp);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.dir.openFile(self.io, path, .{})) |existing| {
            var value = existing;
            value.close(self.io);
            return error.PathAlreadyExists;
        } else |err| if (err != error.FileNotFound) return err;
        self.dir.writeFile(self.io, .{
            .sub_path = temp_path,
            .data = file,
            .flags = .{ .truncate = true },
        }) catch |err| return err;
        errdefer self.dir.deleteFile(self.io, temp_path) catch {};
        try self.dir.rename(temp_path, self.dir, path, self.io);
    }

    pub fn get(self: *Store, id: []const u8, password: []const u8, now: i64) !Paste {
        if (!validId(id)) return Error.InvalidId;
        var name: [80]u8 = undefined;
        const path = fileName(id, &name);
        try self.mutex.lock(self.io);
        const file = self.dir.readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(outer_bytes + metadata_bytes + 32 + 96 + self.max_bytes),
        ) catch |err| {
            self.mutex.unlock(self.io);
            return if (err == error.FileNotFound) Error.NotFound else err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(file);
        if (file.len < outer_bytes + metadata_bytes or !std.mem.eql(u8, file[0..magic.len], magic))
            return Error.Corrupt;
        const header_expires = decryptHeaderExpiry(file[0..expiry_header_bytes], self.key) catch
            return Error.Corrupt;
        const plain = try self.allocator.alloc(u8, file.len - outer_bytes);
        errdefer {
            std.crypto.secureZero(u8, plain);
            self.allocator.free(plain);
        }
        Aead.decrypt(
            plain,
            file[outer_bytes..],
            file[expiry_header_bytes + Aead.nonce_length ..][0..Aead.tag_length].*,
            magic,
            file[expiry_header_bytes..][0..Aead.nonce_length].*,
            self.key,
        ) catch return Error.Corrupt;

        var cursor: usize = 0;
        const created = readInt(i64, plain, &cursor);
        const expires = readInt(i64, plain, &cursor);
        if (header_expires != expires) return Error.Corrupt;
        if (plain[cursor] > @intFromEnum(Kind.image)) return Error.Corrupt;
        const kind: Kind = @enumFromInt(plain[cursor]);
        cursor += 1;
        const language_len = plain[cursor];
        cursor += 1;
        const mime_len = plain[cursor];
        cursor += 1;
        const protected = plain[cursor] == 1;
        cursor += 1;
        const salt = plain[cursor..][0..16];
        cursor += 16;
        const expected_hash = plain[cursor..][0..32].*;
        cursor += 32;
        const content_len = readInt(u32, plain, &cursor);
        const needed = cursor + language_len + mime_len + content_len;
        if (needed != plain.len) return Error.Corrupt;
        if (expires <= now) {
            try self.mutex.lock(self.io);
            self.dir.deleteFile(self.io, path) catch {};
            self.mutex.unlock(self.io);
            return Error.Expired;
        }
        if (protected) {
            if (password.len == 0) return Error.PasswordRequired;
            var actual_hash: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &actual_hash);
            try std.crypto.pwhash.argon2.kdf(
                self.allocator,
                &actual_hash,
                password,
                salt,
                self.password_params,
                .argon2id,
                self.io,
            );
            if (!std.crypto.timing_safe.eql([32]u8, expected_hash, actual_hash))
                return Error.PasswordDenied;
        }
        const language = plain[cursor..][0..language_len];
        cursor += language_len;
        const mime = plain[cursor..][0..mime_len];
        cursor += mime_len;
        return .{
            .allocation = plain,
            .content = plain[cursor..],
            .language = language,
            .mime = mime,
            .created_at = created,
            .expires_at = expires,
            .kind = kind,
        };
    }

    pub fn sweepExpired(self: *Store, now: i64) !SweepStats {
        var stats = SweepStats{};
        var iterator = self.dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (pasteId(entry.name) == null) continue;
            stats.scanned +|= 1;
            const expires = self.readHeaderExpiry(entry.name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    stats.errors +|= 1;
                    continue;
                },
            };
            if (expires > now) continue;
            try self.mutex.lock(self.io);
            var deleted = true;
            self.dir.deleteFile(self.io, entry.name) catch |err| switch (err) {
                error.FileNotFound => deleted = false,
                else => {
                    deleted = false;
                    stats.errors +|= 1;
                },
            };
            self.mutex.unlock(self.io);
            if (deleted) stats.deleted +|= 1;
        }
        return stats;
    }

    fn readHeaderExpiry(self: *Store, path: []const u8) !i64 {
        var file = try self.dir.openFile(self.io, path, .{});
        defer file.close(self.io);
        var header: [expiry_header_bytes]u8 = undefined;
        const read = try file.readPositionalAll(self.io, &header, 0);
        if (read != header.len or !std.mem.eql(u8, header[0..magic.len], magic)) return Error.Corrupt;
        return decryptHeaderExpiry(&header, self.key);
    }
};

fn decryptHeaderExpiry(header: []const u8, key: [Aead.key_length]u8) !i64 {
    if (header.len != expiry_header_bytes) return Error.Corrupt;
    const nonce_start = magic.len;
    const tag_start = nonce_start + Aead.nonce_length;
    const cipher_start = tag_start + Aead.tag_length;
    var plain: [expiry_bytes]u8 = undefined;
    Aead.decrypt(
        &plain,
        header[cipher_start..],
        header[tag_start..][0..Aead.tag_length].*,
        expiry_aad,
        header[nonce_start..][0..Aead.nonce_length].*,
        key,
    ) catch return Error.Corrupt;
    return std.mem.readInt(i64, &plain, .little);
}

fn validId(id: []const u8) bool {
    if (id.len < 5 or id.len > 64) return false;
    for (id) |byte| if (!std.ascii.isLower(byte) and byte != '-') return false;
    return true;
}

fn pasteId(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".plop")) return null;
    const id = name[0 .. name.len - ".plop".len];
    return if (validId(id)) id else null;
}

fn fileName(id: []const u8, buffer: *[80]u8) []const u8 {
    @memcpy(buffer[0..id.len], id);
    @memcpy(buffer[id.len..][0..5], ".plop");
    return buffer[0 .. id.len + 5];
}

fn tempName(id: []const u8, buffer: *[84]u8) []const u8 {
    @memcpy(buffer[0..id.len], id);
    @memcpy(buffer[id.len..][0..9], ".plop.tmp");
    return buffer[0 .. id.len + 9];
}

fn writeInt(comptime T: type, output: []u8, cursor: *usize, value: T) void {
    std.mem.writeInt(T, output[cursor.*..][0..@sizeOf(T)], value, .little);
    cursor.* += @sizeOf(T);
}

fn readInt(comptime T: type, input: []const u8, cursor: *usize) T {
    const value = std.mem.readInt(T, input[cursor.*..][0..@sizeOf(T)], .little);
    cursor.* += @sizeOf(T);
    return value;
}

fn copyAt(output: []u8, start: usize, input: []const u8) usize {
    @memcpy(output[start..][0..input.len], input);
    return start + input.len;
}

test "encrypted round trip, password gate, and TTL deletion" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = Store{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dir = temporary.dir,
        .key = [_]u8{0x42} ** 32,
        .max_bytes = 1024,
        .password_params = .{ .t = 1, .m = 8, .p = 1 },
    };
    try store.put("otter-vole-tiger", .{
        .content = "const secret = true;",
        .language = "zig",
        .password = "correct horse",
        .ttl_seconds = 60,
    }, 100);

    const encrypted = try temporary.dir.readFileAlloc(
        std.testing.io,
        "otter-vole-tiger.plop",
        std.testing.allocator,
        .limited(2048),
    );
    defer std.testing.allocator.free(encrypted);
    try std.testing.expect(std.mem.indexOf(u8, encrypted, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, encrypted, "correct horse") == null);
    try std.testing.expect(std.mem.indexOf(u8, encrypted, "zig") == null);
    try std.testing.expectError(Error.PasswordRequired, store.get("otter-vole-tiger", "", 101));
    try std.testing.expectError(Error.PasswordDenied, store.get("otter-vole-tiger", "wrong", 101));
    var paste = try store.get("otter-vole-tiger", "correct horse", 101);
    defer paste.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("const secret = true;", paste.content);
    try std.testing.expectEqualStrings("zig", paste.language);

    try std.testing.expectError(Error.Expired, store.get("otter-vole-tiger", "correct horse", 160));
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "otter-vole-tiger.plop", .{}),
    );
}

test "hourly sweep reads encrypted expiry headers and deletes only expired pastes" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var store = Store{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dir = temporary.dir,
        .key = [_]u8{0x62} ** 32,
        .max_bytes = 1024,
    };
    try store.put("expired-paste", .{ .content = "old", .ttl_seconds = 10 }, 100);
    try store.put("current-paste", .{ .content = "new", .ttl_seconds = 20 }, 100);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "corrupt-paste.plop", .data = "PLOP" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-paste.txt", .data = "keep" });

    const stats = try store.sweepExpired(110);
    try std.testing.expectEqual(@as(u64, 3), stats.scanned);
    try std.testing.expectEqual(@as(u64, 1), stats.deleted);
    try std.testing.expectEqual(@as(u64, 1), stats.errors);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "expired-paste.plop", .{}),
    );
    var current = try store.get("current-paste", "", 110);
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new", current.content);
    var unrelated = try temporary.dir.openFile(std.testing.io, "not-a-paste.txt", .{});
    unrelated.close(std.testing.io);
}

test "store validates bounds, metadata, collisions, and missing pastes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = Store{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dir = temporary.dir,
        .key = [_]u8{0x19} ** 32,
        .max_bytes = 16,
        .password_params = .{ .t = 1, .m = 8, .p = 1 },
    };
    try std.testing.expectError(Error.InvalidId, store.put("bad/id", .{ .content = "x" }, 1));
    try std.testing.expectError(Error.PasteTooLarge, store.put("large-paste-id", .{ .content = "0123456789abcdefg" }, 1));
    try std.testing.expectError(Error.InvalidInput, store.put("zero-ttl-paste", .{ .content = "x", .ttl_seconds = 0 }, 1));
    try std.testing.expectError(Error.InvalidInput, store.put("bad-utf-paste", .{ .content = "\xff" }, 1));
    try std.testing.expectError(Error.InvalidInput, store.put("long-language-id", .{ .content = "x", .language = "x" ** 33 }, 1));
    try std.testing.expectError(Error.InvalidInput, store.put("long-mime-paste", .{ .content = "x", .mime = "x" ** 97 }, 1));
    try std.testing.expectError(Error.InvalidInput, store.put("long-password-id", .{ .content = "x", .password = "x" ** 257 }, 1));
    try std.testing.expectError(Error.NotFound, store.get("missing-paste-id", "", 1));

    try store.put("image-boundary-id", .{
        .content = "0123456789abcdef",
        .language = "image",
        .mime = "image/webp",
        .kind = .image,
        .ttl_seconds = 90,
    }, 10);
    try std.testing.expectError(error.PathAlreadyExists, store.put("image-boundary-id", .{ .content = "other" }, 10));
    var paste = try store.get("image-boundary-id", "", 11);
    defer paste.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.image, paste.kind);
    try std.testing.expectEqualStrings("image/webp", paste.mime);
    try std.testing.expectEqualStrings("0123456789abcdef", paste.content);
    try std.testing.expectEqual(@as(i64, 10), paste.created_at);
    try std.testing.expectEqual(@as(i64, 100), paste.expires_at);
}

test "store rejects truncated, tampered, and wrong-key files" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = Store{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dir = temporary.dir,
        .key = [_]u8{0x51} ** 32,
        .max_bytes = 128,
    };
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "truncated-paste-id.plop", .data = "PLOP" });
    try std.testing.expectError(Error.Corrupt, store.get("truncated-paste-id", "", 1));

    try store.put("tampered-paste-id", .{ .content = "authenticated" }, 1);
    const encrypted = try temporary.dir.readFileAlloc(
        std.testing.io,
        "tampered-paste-id.plop",
        std.testing.allocator,
        .limited(512),
    );
    defer std.testing.allocator.free(encrypted);
    encrypted[encrypted.len - 1] ^= 1;
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "tampered-paste-id.plop",
        .data = encrypted,
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(Error.Corrupt, store.get("tampered-paste-id", "", 2));

    try store.put("wrong-key-paste", .{ .content = "keyed" }, 1);
    var wrong_key = store;
    wrong_key.key = [_]u8{0x52} ** 32;
    try std.testing.expectError(Error.Corrupt, wrong_key.get("wrong-key-paste", "", 2));
}
