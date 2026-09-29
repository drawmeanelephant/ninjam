//! NINJAM password hashing (docs/PROTOCOL.md §4.3):
//!   inner = SHA1(username ':' password)
//!   reply = SHA1(inner || challenge)

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;

pub fn innerHash(username: []const u8, password: []const u8, out: *[20]u8) void {
    var h = Sha1.init(.{});
    h.update(username);
    h.update(":");
    h.update(password);
    h.final(out);
}

pub fn replyHash(inner: *const [20]u8, challenge: *const [8]u8, out: *[20]u8) void {
    var h = Sha1.init(.{});
    h.update(inner);
    h.update(challenge);
    h.final(out);
}

pub fn passwordReply(username: []const u8, password: []const u8, challenge: *const [8]u8, out: *[20]u8) void {
    var inner: [20]u8 = undefined;
    innerHash(username, password, &inner);
    replyHash(&inner, challenge, out);
}

pub fn hexLower(src: []const u8, out: []u8) void {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        out[i * 2] = digits[src[i] >> 4];
        out[i * 2 + 1] = digits[src[i] & 0xF];
    }
}

test "sha1 known answer: spec §10 alice/secret" {
    // SHA1("alice:secret") = 6985e52cea44a28695d5c440bd42f57e9f50b7b1
    var inner: [20]u8 = undefined;
    innerHash("alice", "secret", &inner);
    var hexbuf: [40]u8 = undefined;
    hexLower(&inner, &hexbuf);
    try std.testing.expectEqualStrings("6985e52cea44a28695d5c440bd42f57e9f50b7b1", &hexbuf);

    // challenge 0123456789abcdef ->
    // SHA1(inner || challenge) = 63fd01e27c12cc2ad826ae47b4d6b2c9fd20a42e
    const challenge = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    var reply: [20]u8 = undefined;
    replyHash(&inner, &challenge, &reply);
    hexLower(&reply, &hexbuf);
    try std.testing.expectEqualStrings("63fd01e27c12cc2ad826ae47b4d6b2c9fd20a42e", &hexbuf);
}
