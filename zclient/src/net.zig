//! TCP transport with NINJAM message framing (docs/PROTOCOL.md §1, §2).
//! Frame = 1 type byte + uint32 LE size (<= 16384) + payload.
//! Built directly on std.posix to stay stable across zig std churn.

const std = @import("std");
const builtin = @import("builtin");
const bufmod = @import("buf.zig");
const clock = @import("clock.zig");

pub const max_payload: u32 = 16384;

pub const Message = struct {
    mtype: u8,
    payload: []const u8,
};

/// What became of a message handed to `sendMessageBounded`.
///
/// The distinction between the last two is the whole point, and it is not a
/// stylistic one. The NINJAM frame is `[u8 type][u32 LE len][payload]` on a
/// TCP byte stream with **no resync marker** — no magic word, no checksum, and
/// nothing that would let a reader notice it is one byte out of step (#31
/// established exactly this). So the three states are not a gradient:
///  - `.declined` and `.sent` both leave the reader correctly framed;
///  - `.partial` does not, and cannot be undone.
pub const SendOutcome = enum {
    /// Every byte of the frame is in the socket's send buffer.
    sent,
    /// Nothing at all was written. The socket could not take the whole frame
    /// and not one byte of it reached the wire, so the stream is exactly where
    /// it was. A caller may drop a bar and frame the next one normally.
    declined,
    /// Some but not all of the frame is on the wire. The peer is now mid-frame
    /// and will consume the *next* frame's bytes as the tail of this one, then
    /// parse whatever follows as a header. This is a dead connection, not a
    /// dropped bar, and no retry can repair it.
    partial,
};

/// The session's nonblocking writer owns a short write's tail, so it can finish
/// that frame later without corrupting TCP framing or holding up the clock.
pub const WriteOutcome = enum { sent, declined, pending };

pub const Error = error{
    BadFrame,
    EndOfStream,
    ConnectionClosed,
    WriteQueueFull,
} || std.posix.ReadError || std.posix.PollError || std.posix.UnexpectedError || std.mem.Allocator.Error;

pub const Conn = struct {
    io: std.Io = undefined,
    fd: std.posix.socket_t = -1,

    rbuf: [65536]u8 = undefined,
    rhead: usize = 0,
    rtail: usize = 0,

    // #14: bounded storage, not a backlog of stale audio. Uploads may leave
    // only ONE in-flight frame here; small control frames queue behind its
    // mandatory tail. A control flood fails explicitly rather than growing.
    wbuf: [4 * (max_payload + 5)]u8 = undefined,
    woff: usize = 0,
    wlen: usize = 0,

    last_recv_ms: i64 = 0,
    last_send_ms: i64 = 0,

    pub fn connect(io: std.Io, host: []const u8, port: u16) !Conn {
        // fast path: dotted-quad IPv4 literal
        if (std.Io.net.Ip4Address.parse(host, port)) |ip4| {
            const sa = sockaddrIn(ip4);
            return connectSockaddr(io, std.posix.AF.INET, @ptrCast(&sa), @intCast(@sizeOf(std.posix.sockaddr.in)));
        } else |_| {}

        // fast path: IPv6 literal. The CLI strips the brackets of
        // `--host [::1]:port`, so the text arrives bare (`::1`). A `%zone`
        // scope is refused here (error.UnresolvedScope) on purpose: getaddrinfo
        // below resolves scoped forms, and duplicating if_nametoindex would be
        // a second copy of one job.
        if (std.Io.net.Ip6Address.parse(host, port)) |ip6| {
            const sa = sockaddrIn6(ip6);
            return connectSockaddr(io, std.posix.AF.INET6, @ptrCast(&sa), @intCast(@sizeOf(std.posix.sockaddr.in6)));
        } else |_| {}

        // hostname: getaddrinfo (libc). AF.UNSPEC, not AF.INET: the resolver
        // returns both families in its own preference order (RFC 6724), and
        // the loop below connects to the first entry that answers — so a
        // v6-first resolver still reaches a v4-only server by falling through
        // the refused v6 attempt, and vice versa. Taking only the first entry
        // would be happy-eyeballs by luck rather than by construction.
        const host_z = std.heap.page_allocator.dupeZ(u8, host) catch return error.SystemResources;
        defer std.heap.page_allocator.free(host_z);
        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.UnknownHost;

        const hints: std.posix.addrinfo = .{
            .flags = .{},
            .family = std.posix.AF.UNSPEC,
            .socktype = std.posix.SOCK.STREAM,
            .protocol = std.posix.IPPROTO.TCP,
            .addrlen = 0,
            .canonname = null,
            .addr = null,
            .next = null,
        };
        var res: ?*std.posix.addrinfo = null;
        const rc = std.posix.system.getaddrinfo(host_z.ptr, port_str.ptr, &hints, &res);
        if (rc != @as(std.posix.system.EAI, @enumFromInt(0)) or res == null) return error.UnknownHost;
        defer if (res) |some| std.posix.system.freeaddrinfo(some);

        // getaddrinfo can return many entries; a host has at most two families
        // that matter here, and the fixed array is a deliberate bound rather
        // than an allocation. The addrs are borrowed from the list, which
        // outlives the connect loop below.
        var cands: [16]Candidate = undefined;
        var ncands: usize = 0;
        var it: ?*std.posix.addrinfo = res;
        while (it) |ai| : (it = ai.next) {
            if (ai.addrlen == 0 or ai.addr == null) continue;
            if (ncands == cands.len) break;
            cands[ncands] = .{ .family = ai.family, .addr = ai.addr.?, .len = @intCast(ai.addrlen) };
            ncands += 1;
        }
        return connectCandidates(io, cands[0..ncands]);
    }

    /// One place a host may be reached: an address of a specific family, in
    /// the form `connect` accepts. `addr` is borrowed and must outlive the
    /// connect attempt.
    pub const Candidate = struct {
        family: c_int,
        addr: *const std.posix.sockaddr,
        len: std.posix.socklen_t,
    };

    /// The connect loop proper, separated from where candidates come from
    /// (literals, getaddrinfo) so the fallthrough is testable without betting
    /// on the resolver's ordering of `localhost`.
    ///
    /// The property it exists to keep: **one failed candidate is not a failed
    /// host.** A v6-first resolver must still reach a v4-only server — the
    /// refused v6 connect falls through to the next entry — and a v4-only
    /// resolver reaches a v6-only one the same way. Taking the first entry and
    /// dying on it would be happy-eyeballs by luck rather than by construction.
    fn connectCandidates(io: std.Io, candidates: []const Candidate) !Conn {
        for (candidates) |c| {
            if (connectSockaddr(io, c.family, c.addr, c.len)) |conn| {
                return conn;
            } else |_| continue;
        }
        return error.UnknownHost;
    }

    fn openStreamSocket(family: c_int) !std.posix.socket_t {
        const rc = std.posix.system.socket(@intCast(family), std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketOpen;
        return @intCast(rc);
    }

    fn closeFd(fd: std.posix.socket_t) void {
        _ = std.posix.errno(std.posix.system.close(fd));
    }

    fn setNonblocking(fd: std.posix.socket_t) !void {
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.SocketFlags;
        var o: std.c.O = @bitCast(@as(u32, @intCast(flags)));
        o.NONBLOCK = true;
        if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o))) < 0) return error.SocketFlags;
    }

    fn sockaddrIn(ip4: std.Io.net.Ip4Address) std.posix.sockaddr.in {
        const In = std.posix.sockaddr.in;
        var sa: In = std.mem.zeroes(In);
        if (@hasField(In, "len")) sa.len = @sizeOf(In);
        sa.family = std.posix.AF.INET;
        sa.port = std.mem.nativeToBig(u16, ip4.port);
        // sockaddr stores network-order bytes in memory; bytes are already
        // in network order, so a native-endian reinterpretation is correct.
        sa.addr = @bitCast(ip4.bytes);
        return sa;
    }

    /// The IPv6 twin of `sockaddrIn`, for the literal fast path. The scoped
    /// `%zone` forms never reach here (see `connect`), so `scope_id` is the
    /// address's own interface index — 0 for every unscoped literal.
    fn sockaddrIn6(ip6: std.Io.net.Ip6Address) std.posix.sockaddr.in6 {
        const In6 = std.posix.sockaddr.in6;
        var sa: In6 = std.mem.zeroes(In6);
        if (@hasField(In6, "len")) sa.len = @sizeOf(In6);
        sa.family = std.posix.AF.INET6;
        sa.port = std.mem.nativeToBig(u16, ip6.port);
        sa.flowinfo = ip6.flow;
        sa.addr = ip6.bytes;
        sa.scope_id = ip6.interface.index;
        return sa;
    }

    /// Open a stream socket of `family`, connect it to `sa` (a `sockaddr.in`,
    /// a `sockaddr.in6`, or an addrinfo's own sockaddr — all the same bytes to
    /// `connect`), and return the non-blocking `Conn`.
    fn connectSockaddr(io: std.Io, family: c_int, sa: *const std.posix.sockaddr, len: std.posix.socklen_t) !Conn {
        const fd = try openStreamSocket(family);
        errdefer closeFd(fd);
        // latency-sensitive protocol: TCP_NODELAY
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1))) catch {};
        // blocking connect (like the reference client's jnetlib), then go async
        switch (std.posix.errno(std.posix.system.connect(fd, @ptrCast(sa), len))) {
            .SUCCESS, .INTR, .INPROGRESS => {},
            .ISCONN => {},
            else => return error.ConnectionRefused,
        }
        try setNonblocking(fd);
        if (builtin.os.tag == .macos) {
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1)));
        }
        return connected(io, fd);
    }

    fn connected(io: std.Io, fd: std.posix.socket_t) Conn {
        return .{
            .io = io,
            .fd = fd,
            .last_recv_ms = clock.nowMs(io),
            .last_send_ms = clock.nowMs(io),
        };
    }

    pub fn close(self: *Conn) void {
        closeFd(self.fd);
        self.fd = -1;
    }

    pub fn isConnected(self: *const Conn) bool {
        return self.fd >= 0;
    }

    /// Wait until the socket is readable or timeout_ms elapses. Returns true
    /// if readable.
    pub fn pollReadable(self: *Conn, timeout_ms: i32) !bool {
        if (self.fd < 0) return error.ConnectionClosed;
        var fds = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = try std.posix.poll(&fds, timeout_ms);
        return n > 0 and fds[0].revents != 0;
    }

    fn fillMore(self: *Conn) Error!void {
        if (self.fd < 0) return error.ConnectionClosed;
        // compact if full
        if (self.rtail == self.rbuf.len) {
            if (self.rhead > 0) {
                const live = self.rtail - self.rhead;
                std.mem.copyForwards(u8, self.rbuf[0..live], self.rbuf[self.rhead..self.rtail]);
                self.rhead = 0;
                self.rtail = live;
            } else {
                return error.BadFrame; // >64KiB buffered and still no full frame
            }
        }
        const n = std.posix.read(self.fd, self.rbuf[self.rtail..]) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return e,
        };
        if (n == 0) return error.EndOfStream;
        self.rtail += n;
        self.last_recv_ms = clock.nowMs(self.io);
    }

    fn ensureBuffered(self: *Conn, n: usize) Error!void {
        while (self.rtail - self.rhead < n) {
            const before = self.rtail - self.rhead;
            try self.fillMore();
            if (self.rtail - self.rhead == before) {
                // #14: even a partial inbound frame must return control to the
                // audio clock. Keep its bytes buffered until the next pass.
                return error.WouldBlock;
            }
        }
    }

    /// Read one framed message. `payload` receives a copy of the payload
    /// bytes; the returned Message points into it.
    pub fn readMessage(self: *Conn, payload: *bufmod.Buf) Error!Message {
        try self.ensureBuffered(5);
        const t = self.rbuf[self.rhead];
        var size_bytes: [4]u8 = undefined;
        @memcpy(&size_bytes, self.rbuf[self.rhead + 1 ..][0..4]);
        const size = std.mem.readInt(u32, &size_bytes, .little);
        if (t == 0xFF or size > max_payload) return error.BadFrame;
        try self.ensureBuffered(5 + @as(usize, size));
        payload.clear();
        try payload.add(self.rbuf[self.rhead + 5 ..][0..size]);
        self.rhead += 5 + @as(usize, size);
        return .{ .mtype = t, .payload = payload.items() };
    }

    fn writeAllRaw(self: *Conn, data: []const u8) Error!void {
        if (self.fd < 0) return error.ConnectionClosed;
        var off: usize = 0;
        while (off < data.len) {
            const rc = std.posix.system.write(self.fd, data[off..].ptr, data[off..].len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .AGAIN => {
                    var fds = [_]std.posix.pollfd{.{
                        .fd = self.fd,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = try std.posix.poll(&fds, 1000);
                },
                .INTR => {},
                else => return error.ConnectionClosed,
            }
        }
        self.last_send_ms = clock.nowMs(self.io);
    }

    pub fn sendMessage(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.BadFrame;
        var hdr: [5]u8 = undefined;
        hdr[0] = mtype;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        try self.writeAllRaw(&hdr);
        if (payload.len > 0) try self.writeAllRaw(payload);
    }

    /// #14: no polling, sleeping, or retry-on-EAGAIN on the session's write
    /// path. A partial frame remains owned here until its tail is flushed.
    /// Work is bounded by the fixed queue size, even if the peer keeps reading.
    pub fn flushWrites(self: *Conn) Error!bool {
        if (self.fd < 0) return error.ConnectionClosed;
        while (self.woff < self.wlen) {
            const bytes = self.wbuf[self.woff..self.wlen];
            const rc = if (builtin.os.tag == .macos)
                std.posix.system.write(self.fd, bytes.ptr, bytes.len)
            else
                std.posix.system.send(self.fd, bytes.ptr, bytes.len, std.posix.MSG.NOSIGNAL);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.ConnectionClosed;
                    self.woff += @intCast(rc);
                    self.last_send_ms = clock.nowMs(self.io);
                },
                .AGAIN, .INTR => return false,
                else => return error.ConnectionClosed,
            }
        }
        self.woff = 0;
        self.wlen = 0;
        return true;
    }

    fn appendFrame(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.BadFrame;
        const need = payload.len + 5;
        if (self.wlen + need > self.wbuf.len and self.woff > 0) {
            std.mem.copyForwards(u8, self.wbuf[0 .. self.wlen - self.woff], self.wbuf[self.woff..self.wlen]);
            self.wlen -= self.woff;
            self.woff = 0;
        }
        if (self.wlen + need > self.wbuf.len) return error.WriteQueueFull;
        const frame = self.wbuf[self.wlen..][0..need];
        frame[0] = mtype;
        std.mem.writeInt(u32, frame[1..5], @intCast(payload.len), .little);
        @memcpy(frame[5..], payload);
        self.wlen += need;
    }

    /// Control frames cannot be dropped, but must not block behind an upload.
    /// Preserve their order in the bounded queue and flush from the run loop.
    pub fn queueMessage(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        _ = try self.flushWrites();
        try self.appendFrame(mtype, payload);
        _ = try self.flushWrites();
    }

    /// Attempt an upload once. No bytes written => decline; some written =>
    /// retain only this frame's tail and tell the caller to drop the bar.
    /// Never append another upload behind a stalled frame.
    pub fn trySendMessage(self: *Conn, mtype: u8, payload: []const u8) Error!WriteOutcome {
        if (payload.len > max_payload) return error.BadFrame;
        if (!try self.flushWrites()) return .declined;
        // This is an optimization, not an atomicity promise: Linux buffer
        // accounting and Darwin AF_UNIX queue depth can overstate the room.
        if (self.sendRoom()) |room| {
            if (room < payload.len + 5) return .declined;
        }
        try self.appendFrame(mtype, payload);
        if (try self.flushWrites()) return .sent;
        if (self.woff > 0) return .pending;
        self.wlen = 0;
        return .declined;
    }

    /// Send `data`, giving the socket at most `budget_ms` **in total** to accept
    /// it. See `SendOutcome` for what the three results mean.
    ///
    /// This exists because `writeAllRaw` cannot be used by the audio clock. The
    /// socket is non-blocking (`setNonblocking` runs right after connect), so a
    /// peer that stops reading turns `write` into EAGAIN — and `writeAllRaw`'s
    /// answer is to `poll(POLLOUT, 1000)` **in a loop, discarding the return
    /// value**. It therefore does not wait "up to a second"; it waits a second,
    /// wakes, tries again, waits another second, and so on, *forever*, until
    /// the peer reads or the connection dies. `finalizeInterval` calls `send()`
    /// inline on the interval-generation path, so that unbounded wait is a
    /// direct stall of the audio clock — measured at >5 s and still not
    /// returning, for a single 16 KiB upload against a socket with an 8 KiB
    /// buffer (see `src/kujamba_timing.zig`, #14).
    ///
    /// The partial result is reported as `.partial` and is the *only* honest
    /// answer. An earlier version of this function returned a plain `false`,
    /// with a comment claiming a torn frame was benign because "both ends frame
    /// by the declared length, so the server simply never completes that guid".
    /// That is backwards, and it is the load-bearing bug #14's own mechanism
    /// exposes. The server frames by the declared length, so it *does* complete
    /// the frame — with the next bar's bytes as its missing payload — and then
    /// parses whatever comes after as a header from mid-stream. A fresh guid does
    /// not help, because the server never sees those bytes as a guid; they are
    /// the tail of the frame before. So the first torn frame costs the rest of
    /// the session's uploads, silently and permanently — which is the dead
    /// performance this PR exists to prevent, minus the honesty of a disconnect.
    /// Measured, before this fix: a half-full socket, a 16 KiB frame, a zero
    /// budget — `false`, and 6000 bytes on the wire.
    fn writeAllBounded(self: *Conn, data: []const u8, budget_ms: i32) Error!SendOutcome {
        if (self.fd < 0) return error.ConnectionClosed;
        if (data.len == 0) return .sent;
        // a deadline, not a per-attempt timeout: three brief stalls inside one
        // budget must not add up to three budgets
        const deadline_ms = clock.nowMs(self.io) + budget_ms;
        var off: usize = 0;
        while (off < data.len) {
            const rc = std.posix.system.write(self.fd, data[off..].ptr, data[off..].len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .AGAIN => {
                    // bytes already accepted are bytes the peer will read, so
                    // from here on the frame is torn no matter what we do
                    if (off > 0) return .partial;
                    const left = deadline_ms - clock.nowMs(self.io);
                    if (left <= 0) return .declined;
                    var fds = [_]std.posix.pollfd{.{
                        .fd = self.fd,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = try std.posix.poll(&fds, @intCast(left));
                },
                .INTR => {},
                else => return error.ConnectionClosed,
            }
        }
        self.last_send_ms = clock.nowMs(self.io);
        return .sent;
    }

    /// `sendMessage` with a hard bound on how long it may wait for the peer,
    /// and with a promise the caller is allowed to rely on: **`.declined` means
    /// not one byte of this frame reached the wire.** The stream is therefore
    /// still correctly framed, and the caller may abandon whatever it was
    /// sending and carry on.
    ///
    /// Only the upload path (#14) uses this. Giving up on a bar is strictly
    /// better than stalling the audio clock behind it; every other message keeps
    /// using `sendMessage`.
    ///
    /// `budget_ms = 0` never waits at all, which is what an upload wants: it
    /// asks the socket "can you take this whole thing?" and acts on the answer
    /// instead of discovering it a second later.
    pub fn sendMessageBounded(self: *Conn, mtype: u8, payload: []const u8, budget_ms: i32) Error!SendOutcome {
        if (payload.len > max_payload) return error.BadFrame;

        // The atomicity gate. `writable()` cannot do this job: POLLOUT means
        // "at least one byte free", which is true of a socket with 6 KiB of room
        // as well as one with 6 KiB *of a 16 KiB frame's worth* still owed. Ask
        // instead whether the whole frame fits, and decline before touching the
        // wire if it does not. Nothing is raced by doing this first: the session
        // has exactly one writer for this socket, so the only thing that can
        // change between the check and the write is the queue draining (which
        // adds room) or the kernel's own autotuning shrinking the buffer (which
        // is caught as `.partial` below, not silently).
        const need = 5 + payload.len;
        if (self.sendRoom()) |room| {
            if (room < need) return .declined;
        }

        var hdr: [5]u8 = undefined;
        hdr[0] = mtype;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        switch (try self.writeAllBounded(&hdr, budget_ms)) {
            .sent => {},
            .declined => return .declined,
            .partial => return .partial,
        }
        if (payload.len == 0) return .sent;
        switch (try self.writeAllBounded(payload, budget_ms)) {
            .sent => return .sent,
            // the header is already on the wire, so these bytes are not optional
            .declined, .partial => return .partial,
        }
    }

    /// Would the socket accept *something* right now?
    ///
    /// A zero-timeout `poll`, i.e. "is the peer keeping up" asked without paying
    /// to find out. Note what it is **not**: it does not say the socket can take
    /// any particular frame. POLLOUT is set as soon as one byte is free, so a
    /// socket with a few KiB free answers true while being unable to accept a
    /// 16 KiB upload — and trusting it there is exactly what tore frames.
    /// `sendMessageBounded` asks the real question itself, so this is only a
    /// cheap pre-gate now, never the authority.
    pub fn writable(self: *Conn) bool {
        if (self.fd < 0) return false;
        var fds = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, 0) catch return false;
        return n > 0 and (fds[0].revents & std.posix.POLL.OUT) != 0;
    }

    /// Bytes the kernel can accept on this socket right now, or null if this
    /// platform does not let us find out.
    ///
    /// `SO_SNDBUF` is the buffer's capacity and `TIOCOUTQ` is how much of it is
    /// still occupied, so the difference is the room. Both are needed: the
    /// capacity alone says nothing about how full the buffer is, which is the
    /// half-full case that tore frames.
    ///
    /// Null is not a licence to tear a frame. It only means the pre-check is
    /// unavailable, in which case `sendMessageBounded` falls back to the write
    /// loop and relies on `.partial` to catch a tear — a worse but still
    /// correct failure, never a silent one.
    pub fn sendRoom(self: *Conn) ?usize {
        if (self.fd < 0) return null;
        const cap = sendBufBytes(self.fd) orelse return null;
        const queued = outqBytes(self.fd) orelse return null;
        if (queued >= cap) return 0;
        return cap - queued;
    }
};

/// `SO_SNDBUF`, i.e. the send buffer's capacity in bytes.
fn sendBufBytes(fd: std.posix.socket_t) ?usize {
    const v = sockoptI32(fd, @intCast(std.posix.SO.SNDBUF)) orelse return null;

    if (v <= 0) return null;
    return @intCast(v);
}

/// Darwin's name for the send queue depth: "APPLE: Get number of bytes
/// currently in send socket buffer". Linux does not have it.
const so_nwrite: u32 = 0x1024;

/// `TIOCOUTQ` in the asm-generic Linux encoding, `_IOR('t', 17, int)`.
const tiocoutq_linux: c_ulong = 0x5411;

// Bound to the real libc `ioctl` symbol, and that is deliberate: Zig resolves
// an `extern` declaration by *name*, so a plausible-looking name like
// `ioctlTIOCOUTQ` compiles cleanly on macOS — where this branch is dead code and
// never referenced — and then fails at link time on Linux with
// "undefined symbol: ioctlTIOCOUTQ". The failure is build-only, and only on the
// one platform that takes this path, which is a good way to lose an afternoon.
extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *i32) c_int;

fn sockoptI32(fd: std.posix.socket_t, optname: u32) ?i32 {
    var v: i32 = 0;
    var len: std.c.socklen_t = @sizeOf(i32);
    const rc = std.c.getsockopt(fd, std.posix.SOL.SOCKET, optname, @ptrCast(&v), &len);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return v;
}

/// Bytes queued for transmission and not yet freed by the peer.
///
/// There is no one way to ask for this, and finding that out was its own
/// afternoon. `TIOCOUTQ` is the obvious answer and it works on Linux — but
/// Darwin does not implement it for sockets at all: both the `'t'` spelling from
/// its own `<sys/ttycom.h>` and the `'f'` spelling return `ENOTSUP`, measured on
/// a socketpair and on loopback TCP alike. The same number is available on
/// Darwin as the `SO_NWRITE` socket option instead, which is what the other
/// branch uses. So: spelled out per target rather than guessed, with an unknown
/// target yielding null — which disables the pre-check and falls back to the
/// `.partial` backstop, a worse but still safe answer.
fn outqBytes(fd: std.posix.socket_t) ?usize {
    var q: ?i32 = switch (builtin.os.tag) {
        .linux => blk: {
            var v: i32 = 0;
            if (std.posix.errno(ioctl(fd, tiocoutq_linux, &v)) != .SUCCESS) break :blk null;
            break :blk v;
        },
        .macos, .ios, .tvos, .watchos => sockoptI32(fd, so_nwrite),
        else => null,
    };
    q = q orelse return null;
    if (q.? < 0) return 0;
    return @intCast(q.?);
}

test "framing constants" {
    try std.testing.expectEqual(@as(u32, 16384), max_payload);
}

// ---- connect tests (#23) -----------------------------------------------------
//
// These drive `Conn.connect` against a real loopback listener, because the
// failure they guard against is not expressible without a socket: the bug this
// issue fixed was an `openStreamSocket` hard-coded to AF.INET — which cannot
// even be constructed against a v6 listener — and a hints struct pinned to
// AF.INET, which returns no v6 results to iterate at all. Both are invisible
// to any test that does not actually cross a socket.

/// Reads exactly `buf.len` bytes off a blocking socket; EOF mid-read fails.
fn readExact(fd: std.posix.socket_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try std.posix.read(fd, buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

/// One framed round-trip over a freshly connected `Conn`: connect to the
/// already-listening `server` by `host` text, then check the exchange.
fn expectRoundTrip(io: std.Io, host: []const u8, server: *std.Io.net.Server) !void {
    const port = server.socket.address.getPort();
    var conn = try Conn.connect(io, host, port);
    defer conn.close();
    try assertRoundTrip(&conn, server);
}

/// The exchange itself: send a message from the client side and check the
/// bytes the server-side socket receives — type byte, little-endian length,
/// payload — the whole framing contract in one exchange. `server` must already
/// have `conn` in its backlog.
fn assertRoundTrip(conn: *Conn, server: *std.Io.net.Server) !void {
    const flags: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(conn.fd, std.c.F.GETFL, @as(c_int, 0)))));
    try std.testing.expect(flags.NONBLOCK);
    try conn.sendMessage(0x41, "hello");

    // Accept *after* the client has connected and sent: the connection waits
    // in the listener's backlog and the bytes in the kernel's buffers, so the
    // whole exchange needs no second thread. Accept goes through raw posix
    // (harness style): the listener here is blocking, and the io vtable's
    // accept asserts its own blocking assumptions we do not need.
    const rc = std.posix.system.accept(server.socket.handle, null, null);
    try std.testing.expectEqual(std.posix.errno(rc), .SUCCESS);
    const cfd: std.posix.socket_t = @intCast(rc);
    defer Conn.closeFd(cfd);

    var buf: [10]u8 = undefined;
    try readExact(cfd, &buf);
    try std.testing.expectEqual(@as(u8, 0x41), buf[0]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[1..5], .little));
    try std.testing.expectEqualStrings("hello", buf[5..10]);
}

fn loopbackServer(family: std.Io.net.IpAddress) !std.Io.net.Server {
    return family.listen(std.testing.io, .{});
}

test "connect: dotted-quad IPv4 literal round-trips a frame" {
    var server = try loopbackServer(.{ .ip4 = .loopback(0) });
    defer server.deinit(std.testing.io);
    try expectRoundTrip(std.testing.io, "127.0.0.1", &server);
}

test "connect: IPv6 literal round-trips a frame" {
    // The skip is for containers with IPv6 switched off at the kernel, where
    // binding ::1 fails and no test in the repo could exercise this path.
    // Everywhere this suite is expected to run — macOS and Linux CI runners
    // both answer on ::1 — this is a real assertion: `::1` must reach the
    // AF.INET6 socket.
    var server = loopbackServer(.{ .ip6 = .loopback(0) }) catch |e| switch (e) {
        error.AddressUnavailable => return error.SkipZigTest,
        else => return e,
    };
    defer server.deinit(std.testing.io);
    try expectRoundTrip(std.testing.io, "::1", &server);
}

test "connect: hostname resolves through AF.UNSPEC and falls through families" {
    // "localhost" resolves to ::1 and 127.0.0.1 in some order on both CI
    // platforms, and the resolver's order decides whether this run exercises
    // the fallthrough — so this test proves the resolution path only, and the
    // fallthrough has its own seam test below that does not depend on the
    // resolver's mood.
    var server = try loopbackServer(.{ .ip4 = .loopback(0) });
    defer server.deinit(std.testing.io);
    try expectRoundTrip(std.testing.io, "localhost", &server);
}

test "connect: a refused candidate falls through to the next family" {
    // The seam version of the resolver test, with the ordering problem
    // removed: the candidate list is v6-first *by construction* — a dead v6
    // port, then the live v4 listener — so the property "one failed candidate
    // is not a failed host" is exercised no matter how this machine's
    // resolver orders localhost. Mutating `connectCandidates` to break on the
    // first refused candidate fails exactly here.
    var server = try loopbackServer(.{ .ip4 = .loopback(0) });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var dead: std.posix.sockaddr.in6 = std.mem.zeroes(std.posix.sockaddr.in6);
    dead.family = std.posix.AF.INET6;
    dead.port = std.mem.nativeToBig(u16, 1); // loopback port 1: nothing listens
    dead.addr[15] = 1;
    var live: std.posix.sockaddr.in = std.mem.zeroes(std.posix.sockaddr.in);
    live.family = std.posix.AF.INET;
    live.port = std.mem.nativeToBig(u16, port);
    live.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    const cands = [_]Conn.Candidate{
        .{ .family = std.posix.AF.INET6, .addr = @ptrCast(&dead), .len = @sizeOf(std.posix.sockaddr.in6) },
        .{ .family = std.posix.AF.INET, .addr = @ptrCast(&live), .len = @sizeOf(std.posix.sockaddr.in) },
    };
    var conn = try Conn.connectCandidates(std.testing.io, &cands);
    defer conn.close();
    try assertRoundTrip(&conn, &server);
}

test "sockaddrIn6: builds the wire struct for a loopback literal" {
    const ip6 = try std.Io.net.Ip6Address.parse("::1", 20531);
    const sa = Conn.sockaddrIn6(ip6);
    try std.testing.expectEqual(@as(std.posix.sa_family_t, std.posix.AF.INET6), sa.family);
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 20531), sa.port);
    try std.testing.expectEqual(@as(u8, 1), sa.addr[15]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 15, sa.addr[0..15]);
    try std.testing.expectEqual(@as(u32, 0), sa.scope_id);
}

fn nonblockingTestPair() ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    if (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.SocketPairFailed;
    errdefer for (fds) |fd| Conn.closeFd(fd);
    for (fds) |fd| try Conn.setNonblocking(fd);
    try std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 4096)));
    try std.posix.setsockopt(fds[1], std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 4096)));
    return fds;
}

test "#14: a partial frame retains its tail ahead of control messages, without waiting" {
    const fds = try nonblockingTestPair();
    defer for (fds) |fd| Conn.closeFd(fd);
    var conn = Conn{ .io = std.testing.io, .fd = fds[0] };
    const payload = [_]u8{0x5a} ** max_payload;
    const t0 = clock.nowNs(std.testing.io);
    // Control queuing uses the same writer as uploads and deliberately bypasses
    // the advisory sendRoom gate. Force a short write to test tail ownership.
    try conn.queueMessage(0x84, &payload);
    try std.testing.expect(conn.woff > 0);
    try std.testing.expect(conn.woff < conn.wlen);
    try conn.queueMessage(0xc0, "ping");
    try std.testing.expectEqual(WriteOutcome.declined, try conn.trySendMessage(0x83, "next bar"));
    try std.testing.expect(clock.nowNs(std.testing.io) - t0 < 500 * std.time.ns_per_ms);

    var expected: [max_payload + 5 + 9]u8 = undefined;
    expected[0] = 0x84;
    std.mem.writeInt(u32, expected[1..5], max_payload, .little);
    @memcpy(expected[5..][0..max_payload], &payload);
    expected[max_payload + 5] = 0xc0;
    std.mem.writeInt(u32, expected[max_payload + 6 ..][0..4], 4, .little);
    @memcpy(expected[max_payload + 10 ..], "ping");

    var received: [expected.len]u8 = undefined;
    var got: usize = 0;
    const deadline = clock.nowMs(std.testing.io) + 2000;
    while (got < received.len and clock.nowMs(std.testing.io) < deadline) {
        _ = try conn.flushWrites();
        const n = std.posix.read(fds[1], received[got..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    try std.testing.expectEqual(expected.len, got);
    try std.testing.expectEqualSlices(u8, &expected, &received);
    try std.testing.expect(try conn.flushWrites());
    try std.testing.expectEqual(WriteOutcome.sent, try conn.trySendMessage(0x83, "next bar"));
}

test "#14: the control queue is bounded even while the peer never drains" {
    const fds = try nonblockingTestPair();
    defer for (fds) |fd| Conn.closeFd(fd);
    var conn = Conn{ .io = std.testing.io, .fd = fds[0] };
    const payload = [_]u8{0x5a} ** max_payload;
    var full = false;
    for (0..8) |_| {
        conn.queueMessage(0xc0, &payload) catch |e| {
            try std.testing.expectEqual(error.WriteQueueFull, e);
            full = true;
            break;
        };
    }
    try std.testing.expect(full);
    try std.testing.expect(conn.wlen <= conn.wbuf.len);
}

test "#14: an incomplete incoming frame yields and resumes from buffered bytes" {
    const fds = try nonblockingTestPair();
    defer for (fds) |fd| Conn.closeFd(fd);
    var conn = Conn{ .io = std.testing.io, .fd = fds[1] };
    var payload = bufmod.Buf.init(std.testing.allocator);
    defer payload.deinit();
    const first = "\xc0\x06\x00\x00\x00abc";
    try std.testing.expectEqual(@as(isize, first.len), std.posix.system.write(fds[0], first.ptr, first.len));
    const t0 = clock.nowNs(std.testing.io);
    try std.testing.expectError(error.WouldBlock, conn.readMessage(&payload));
    try std.testing.expect(clock.nowNs(std.testing.io) - t0 < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(isize, 3), std.posix.system.write(fds[0], "def", 3));
    const msg = try conn.readMessage(&payload);
    try std.testing.expectEqual(@as(u8, 0xc0), msg.mtype);
    try std.testing.expectEqualStrings("abcdef", msg.payload);
}
