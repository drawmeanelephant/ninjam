//! NINJAM message payloads (docs/PROTOCOL.md §5) and message type IDs.

const std = @import("std");
const bufmod = @import("buf.zig");
const Reader = bufmod.Reader;
const Fixed = bufmod.Fixed;

// ---- message type ids -------------------------------------------------
pub const MSG_AUTH_CHALLENGE: u8 = 0x00;
pub const MSG_AUTH_REPLY: u8 = 0x01;
pub const MSG_CONFIG_CHANGE_NOTIFY: u8 = 0x02;
pub const MSG_USERINFO_CHANGE_NOTIFY: u8 = 0x03;
pub const MSG_DOWNLOAD_INTERVAL_BEGIN: u8 = 0x04;
pub const MSG_DOWNLOAD_INTERVAL_WRITE: u8 = 0x05;
pub const MSG_AUTH_USER: u8 = 0x80;
pub const MSG_SET_USERMASK: u8 = 0x81;
pub const MSG_SET_CHANNEL_INFO: u8 = 0x82;
pub const MSG_UPLOAD_INTERVAL_BEGIN: u8 = 0x83;
pub const MSG_UPLOAD_INTERVAL_WRITE: u8 = 0x84;
pub const MSG_CHAT_MESSAGE: u8 = 0xC0;
pub const MSG_KEEPALIVE: u8 = 0xFD;

// ---- protocol constants ------------------------------------------------
pub const PROTO_VER_MIN: u32 = 0x00020000;
pub const PROTO_VER_MAX: u32 = 0x0002ffff;
pub const PROTO_VER_CUR: u32 = 0x00020000;
/// 'O','G','G','v' — little-endian on the wire as 4F 47 47 76.
pub const FOURCC_OGGV: u32 = 0x7647474F;

pub fn type_name(t: u8) []const u8 {
    return switch (t) {
        MSG_AUTH_CHALLENGE => "AUTH_CHALLENGE",
        MSG_AUTH_REPLY => "AUTH_REPLY",
        MSG_CONFIG_CHANGE_NOTIFY => "CONFIG_CHANGE_NOTIFY",
        MSG_USERINFO_CHANGE_NOTIFY => "USERINFO_CHANGE_NOTIFY",
        MSG_DOWNLOAD_INTERVAL_BEGIN => "DOWNLOAD_INTERVAL_BEGIN",
        MSG_DOWNLOAD_INTERVAL_WRITE => "DOWNLOAD_INTERVAL_WRITE",
        MSG_AUTH_USER => "AUTH_USER",
        MSG_SET_USERMASK => "SET_USERMASK",
        MSG_SET_CHANNEL_INFO => "SET_CHANNEL_INFO",
        MSG_UPLOAD_INTERVAL_BEGIN => "UPLOAD_INTERVAL_BEGIN",
        MSG_UPLOAD_INTERVAL_WRITE => "UPLOAD_INTERVAL_WRITE",
        MSG_CHAT_MESSAGE => "CHAT_MESSAGE",
        MSG_KEEPALIVE => "KEEPALIVE",
        else => "UNKNOWN",
    };
}

pub const ParseError = error{ Truncated, BadValue };

// ---- 5.1 server_auth_challenge -----------------------------------------
pub const AuthChallenge = struct {
    challenge: [8]u8,
    server_caps: u32,
    protocol_version: u32,
    license: []const u8, // empty unless caps bit 0
};

pub fn parseChallenge(payload: []const u8) ParseError!AuthChallenge {
    if (payload.len < 16) return error.Truncated;
    var r = Reader.init(payload);
    var out = AuthChallenge{
        .challenge = undefined,
        .server_caps = 0,
        .protocol_version = 0,
        .license = "",
    };
    @memcpy(&out.challenge, try r.take(8));
    out.server_caps = try r.readU32le();
    out.protocol_version = try r.readU32le();
    if (out.server_caps & 1 != 0) {
        out.license = r.readNulstr() catch "";
    }
    return out;
}

// ---- 5.2 server_auth_reply ----------------------------------------------
pub const AuthReply = struct {
    flag_success: bool,
    /// effective username on success, error text on failure
    text: []const u8 = "",
    maxchan: ?u8 = null,
};

pub fn parseAuthReply(payload: []const u8) ParseError!AuthReply {
    if (payload.len < 1) return error.Truncated;
    var out = AuthReply{ .flag_success = (payload[0] & 1) != 0 };
    if (payload.len > 1) {
        var r = Reader.init(payload[1..]);
        out.text = r.readNulstr() catch payload[1..];
        if (r.remaining() >= 1) out.maxchan = r.readByte() catch null;
    }
    return out;
}

// ---- 5.3 config change ---------------------------------------------------
pub const Config = struct { bpm: u16, bpi: u16 };

pub fn parseConfig(payload: []const u8) ParseError!Config {
    if (payload.len < 4) return error.Truncated;
    var r = Reader.init(payload);
    return .{ .bpm = try r.readU16le(), .bpi = try r.readU16le() };
}

pub fn buildConfig(cfg: Config, out: *Fixed) Fixed.Error!void {
    out.clear();
    try out.addU16le(cfg.bpm);
    try out.addU16le(cfg.bpi);
}

// ---- 5.4 userinfo change notify -----------------------------------------
pub const UserInfoRecord = struct {
    active: bool,
    channel_id: u8,
    volume: i16,
    pan: i8,
    flags: u8,
    username: []const u8,
    channel_name: []const u8,
};

/// Collect all records into `sink`.
pub fn parseUserinfoRecords(payload: []const u8, sink: *UserInfoSink) !void {
    var r = Reader.init(payload);
    while (r.remaining() > 0) {
        const rec = UserInfoRecord{
            .active = (try r.readByte()) != 0,
            .channel_id = try r.readByte(),
            .volume = try r.readI16le(),
            .pan = try r.readI8(),
            .flags = try r.readByte(),
            .username = try r.readNulstr(),
            .channel_name = try r.readNulstr(),
        };
        try sink.append(rec);
    }
}

pub const UserInfoSink = struct {
    const max_records = 64;
    records: [max_records]UserInfoRecord = undefined,
    count: usize = 0,

    pub fn append(self: *UserInfoSink, rec: UserInfoRecord) !void {
        if (self.count >= max_records) return error.OutOfMemory;
        self.records[self.count] = rec;
        self.count += 1;
    }

    pub fn items(self: *const UserInfoSink) []const UserInfoRecord {
        return self.records[0..self.count];
    }
};

pub fn buildUserinfoRecord(rec: UserInfoRecord, out: *Fixed) Fixed.Error!void {
    try out.addByte(if (rec.active) 1 else 0);
    try out.addByte(rec.channel_id);
    try out.addI16le(rec.volume);
    try out.addI8(rec.pan);
    try out.addByte(rec.flags);
    try out.addNulstr(rec.username);
    try out.addNulstr(rec.channel_name);
}

// ---- 5.5/5.10 interval begin ---------------------------------------------
pub const IntervalBegin = struct {
    guid: [16]u8,
    estsize: u32,
    fourcc: u32,
    chidx: u8,
    username: []const u8 = "", // server-side (0x04) only
};

pub fn parseIntervalBegin(payload: []const u8) ParseError!IntervalBegin {
    if (payload.len < 25) return error.Truncated;
    var r = Reader.init(payload);
    var out = IntervalBegin{
        .guid = undefined,
        .estsize = 0,
        .fourcc = 0,
        .chidx = 0,
    };
    @memcpy(&out.guid, try r.take(16));
    out.estsize = try r.readU32le();
    out.fourcc = try r.readU32le();
    out.chidx = try r.readByte();
    out.username = r.readNulstr() catch "";
    return out;
}

pub fn buildUploadIntervalBegin(b: IntervalBegin, out: *Fixed) Fixed.Error!void {
    out.clear();
    try out.add(&b.guid);
    try out.addU32le(b.estsize);
    try out.addU32le(b.fourcc);
    try out.addByte(b.chidx);
}

// ---- 5.6/5.11 interval write ----------------------------------------------
pub const IntervalWrite = struct {
    guid: [16]u8,
    flags: u8, // bit 0 = final chunk
    data: []const u8,
};

pub fn parseIntervalWrite(payload: []const u8) ParseError!IntervalWrite {
    if (payload.len < 17) return error.Truncated;
    var out = IntervalWrite{
        .guid = undefined,
        .flags = payload[16],
        .data = payload[17..],
    };
    @memcpy(&out.guid, payload[0..16]);
    return out;
}

pub fn buildUploadIntervalWrite(w: IntervalWrite, out: *Fixed) Fixed.Error!void {
    out.clear();
    try out.add(&w.guid);
    try out.addByte(w.flags);
    try out.add(w.data);
}

// ---- 5.7 client_auth_user ---------------------------------------------------
pub const AuthUser = struct {
    passhash: [20]u8,
    username: []const u8,
    client_caps: u32,
    client_version: u32,
};

pub fn buildAuthUser(u: AuthUser, out: *Fixed) Fixed.Error!void {
    out.clear();
    try out.add(&u.passhash);
    try out.addNulstr(u.username);
    try out.addU32le(u.client_caps);
    try out.addU32le(u.client_version);
}

// ---- 5.8 client_set_usermask ------------------------------------------------
pub const UsermaskRecord = struct {
    username: []const u8,
    channelmask: u32,
};

pub fn parseUsermaskRecords(payload: []const u8, sink: *UserInfoMaskSink) !void {
    var r = Reader.init(payload);
    while (r.remaining() > 0) {
        const rec = UsermaskRecord{
            .username = try r.readNulstr(),
            .channelmask = try r.readU32le(),
        };
        try sink.append(rec);
    }
}

pub const UserInfoMaskSink = struct {
    const max_records = 64;
    records: [max_records]UsermaskRecord = undefined,
    count: usize = 0,

    pub fn append(self: *UserInfoMaskSink, rec: UsermaskRecord) !void {
        if (self.count >= max_records) return error.OutOfMemory;
        self.records[self.count] = rec;
        self.count += 1;
    }

    pub fn items(self: *const UserInfoMaskSink) []const UsermaskRecord {
        return self.records[0..self.count];
    }
};

pub fn buildUsermaskRecord(rec: UsermaskRecord, out: *Fixed) Fixed.Error!void {
    out.clear();
    try out.addNulstr(rec.username);
    try out.addU32le(rec.channelmask);
}

// ---- 5.9 client_set_channel_info ---------------------------------------------
pub const ChannelInfoRecord = struct {
    name: []const u8,
    volume: i16 = 0,
    pan: i8 = 0,
    flags: u8 = 0, // bit 0x80 = inactive/filler
};

pub fn buildChannelInfo(channels: []const ChannelInfoRecord, out: *Fixed) Fixed.Error!void {
    out.clear();
    try out.addU16le(4); // mpisize: per-record info size (volume+pan+flags)
    for (channels) |ch| {
        try out.addNulstr(ch.name);
        try out.addI16le(ch.volume);
        try out.addI8(ch.pan);
        try out.addByte(ch.flags);
    }
}

// ---- 5.12 chat ----------------------------------------------------------------
pub const ChatParms = struct {
    /// up to 5 positional NUL strings
    parms: [5][]const u8 = .{ "", "", "", "", "" },
    nparms: usize = 0,

    pub fn get(self: *const ChatParms, i: usize) []const u8 {
        if (i >= 5 or i >= self.nparms) return "";
        return self.parms[i];
    }
};

pub fn parseChat(payload: []const u8) ParseError!ChatParms {
    var out = ChatParms{};
    var r = Reader.init(payload);
    while (r.remaining() > 0 and out.nparms < 5) {
        out.parms[out.nparms] = try r.readNulstr();
        out.nparms += 1;
    }
    return out;
}

/// Reference builder always emits all five slots (trailing NULs included).
pub fn buildChat(parms: []const []const u8, out: *Fixed) Fixed.Error!void {
    out.clear();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const s: []const u8 = if (i < parms.len) parms[i] else "";
        try out.addNulstr(s);
    }
}

// ---- helpers ---------------------------------------------------------------------
pub fn isZeroGuid(guid: *const [16]u8) bool {
    for (guid) |b| if (b != 0) return false;
    return true;
}

// ==================================================================================
// tests (golden bytes from docs/PROTOCOL.md §10)
// ==================================================================================

const testing = std.testing;

test "parse challenge (spec §10.1)" {
    // S>C 00 10 00 00 00 | 01 23 45 67 89 AB CD EF | 00 03 00 00 | 00 00 02 00
    const payload = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    };
    const ch = try parseChallenge(&payload);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF }, &ch.challenge);
    try testing.expectEqual(@as(u32, 0x00000300), ch.server_caps);
    try testing.expectEqual(@as(u32, 0x00020000), ch.protocol_version);
    try testing.expectEqualStrings("", ch.license);
}

test "parse auth reply success with maxchan (spec §10.1)" {
    const payload = [_]u8{ 0x01, 'a', 'l', 'i', 'c', 'e', '@', 'i', 'p', 0x00, 0x20 };
    const rep = try parseAuthReply(&payload);
    try testing.expect(rep.flag_success);
    try testing.expectEqualStrings("alice@ip", rep.text);
    try testing.expectEqual(@as(u8, 32), rep.maxchan.?);
}

test "parse auth reply failure" {
    const payload = [_]u8{ 0x00, 'i', 'n', 'v', 'a', 'l', 'i', 'd', 0x00 };
    const rep = try parseAuthReply(&payload);
    try testing.expect(!rep.flag_success);
    try testing.expectEqualStrings("invalid", rep.text);
}

test "config parse/build roundtrip (spec §10.2)" {
    const payload = [_]u8{ 0x78, 0x00, 0x08, 0x00 };
    const cfg = try parseConfig(&payload);
    try testing.expectEqual(@as(u16, 120), cfg.bpm);
    try testing.expectEqual(@as(u16, 8), cfg.bpi);
    var f = Fixed{};
    try buildConfig(cfg, &f);
    try testing.expectEqualSlices(u8, &payload, f.slice());
}

test "userinfo records (spec §10.2 bob/guitar)" {
    const payload = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        'b',  'o',  'b',  0x00, 'g',  'u',
        'i',  't',  'a',  'r',  0x00,
    };
    var sink = UserInfoSink{};
    try parseUserinfoRecords(&payload, &sink);
    try testing.expectEqual(@as(usize, 1), sink.count);
    const rec = sink.records[0];
    try testing.expect(rec.active);
    try testing.expectEqual(@as(u8, 0), rec.channel_id);
    try testing.expectEqualStrings("bob", rec.username);
    try testing.expectEqualStrings("guitar", rec.channel_name);
}

test "userinfo empty payload = empty list" {
    var sink = UserInfoSink{};
    try parseUserinfoRecords(&[_]u8{}, &sink);
    try testing.expectEqual(@as(usize, 0), sink.count);
}

test "interval begin with username (spec §10.4)" {
    const payload = [_]u8{
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90,
        0x00, 0x00, 0x00, 0x00, // estsize
        0x4F, 0x47, 0x47, 0x76, // "OGGv"
        0x00, // chidx
        'a',
        'l',
        'i',
        'c',
        'e',
        0x00,
    };
    const b = try parseIntervalBegin(&payload);
    try testing.expectEqual(@as(u32, FOURCC_OGGV), b.fourcc);
    try testing.expectEqual(@as(u8, 0), b.chidx);
    try testing.expectEqualStrings("alice", b.username);
    try testing.expect(!isZeroGuid(&b.guid));
}

test "upload interval begin bytes (spec §10.4)" {
    var f = Fixed{};
    try buildUploadIntervalBegin(.{
        .guid = [1]u8{0xA1} ++ @as([15]u8, @splat(0)),
        .estsize = 0,
        .fourcc = FOURCC_OGGV,
        .chidx = 0,
    }, &f);
    const expect = [1]u8{0xA1} ++ @as([15]u8, @splat(0)) ++ [4]u8{ 0, 0, 0, 0 } ++ [4]u8{ 0x4F, 0x47, 0x47, 0x76 } ++ [1]u8{0x00};
    try testing.expectEqualSlices(u8, &expect, f.slice());
    try testing.expectEqual(@as(usize, 25), f.slice().len);
}

test "interval write roundtrip" {
    var f = Fixed{};
    try buildUploadIntervalWrite(.{
        .guid = @splat(1),
        .flags = 1,
        .data = "OggS-payload",
    }, &f);
    try testing.expectEqual(@as(usize, 17 + 12), f.slice().len);
    const w = try parseIntervalWrite(f.slice());
    try testing.expectEqual(@as(u8, 1), w.flags);
    try testing.expectEqualStrings("OggS-payload", w.data);
}

test "chat build emits five slots (spec §10.5)" {
    var f = Fixed{};
    try buildChat(&[_][]const u8{ "MSG", "hello everyone" }, &f);
    const expect = "MSG\x00" ++ "hello everyone\x00" ++ "\x00\x00\x00";
    try testing.expectEqualSlices(u8, expect, f.slice());
    try testing.expectEqual(@as(usize, 22), f.slice().len);
}

test "chat parse with trailing empty slots" {
    const payload = "MSG\x00" ++ "alice\x00" ++ "hi\x00" ++ "\x00\x00";
    const p = try parseChat(payload);
    try testing.expectEqual(@as(usize, 5), p.nparms);
    try testing.expectEqualStrings("MSG", p.get(0));
    try testing.expectEqualStrings("alice", p.get(1));
    try testing.expectEqualStrings("hi", p.get(2));
    try testing.expectEqualStrings("", p.get(3));
}

test "auth user bytes (spec §10.1 alice)" {
    var f = Fixed{};
    var hash: [20]u8 = undefined;
    for (&hash, 0..) |*b, i| b.* = @intCast(i); // placeholder bytes
    try buildAuthUser(.{
        .passhash = hash,
        .username = "alice",
        .client_caps = 0,
        .client_version = PROTO_VER_CUR,
    }, &f);
    // 20 hash + "alice\0" + 4 + 4 = 34 (matches spec size 0x22)
    try testing.expectEqual(@as(usize, 34), f.slice().len);
    // verify roundtrip parse
    var r = Reader.init(f.slice());
    try testing.expectEqualSlices(u8, &hash, try r.take(20));
    try testing.expectEqualStrings("alice", try r.readNulstr());
    try testing.expectEqual(@as(u32, 0), try r.readU32le());
    try testing.expectEqual(@as(u32, PROTO_VER_CUR), try r.readU32le());
}

test "channel info bytes (spec §10.3)" {
    var f = Fixed{};
    try buildChannelInfo(&[_]ChannelInfoRecord{.{ .name = "channel one" }}, &f);
    const expect = "\x04\x00" ++ "channel one\x00" ++ "\x00\x00\x00\x00";
    try testing.expectEqualSlices(u8, expect, f.slice());
    try testing.expectEqual(@as(usize, 18), f.slice().len);
}

test "zero guid helper" {
    const zero: [16]u8 = @splat(0);
    try testing.expect(isZeroGuid(&zero));
    const notzero = @as([15]u8, @splat(0)) ++ [1]u8{1};
    try testing.expect(!isZeroGuid(&notzero));
}
