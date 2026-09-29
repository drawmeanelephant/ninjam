#!/usr/bin/env python3
"""Generate the NINJAM fuzzer seed corpus (fuzz/corpus/seeds/).

Each seed is a client->server TCP byte stream in NINJAM framing:
  1 byte  message type
  4 bytes message size (little endian)
  <size> bytes payload

Every seed starts with a valid MESSAGE_CLIENT_AUTH_USER handshake (like an
anonymous client login), followed by realistic post-auth traffic that the
fuzzer then mutates: message type IDs, declared lengths, field contents,
fragmented frames, overlong frames, and hostile audio (OGG) payloads.
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "corpus", "seeds")

# message type ids (see ninjam/mpb.h)
MSG_CLIENT_AUTH_USER = 0x80
MSG_CLIENT_SET_USERMASK = 0x81
MSG_CLIENT_SET_CHANNEL_INFO = 0x82
MSG_CLIENT_UPLOAD_INTERVAL_BEGIN = 0x83
MSG_CLIENT_UPLOAD_INTERVAL_WRITE = 0x84
MSG_CHAT_MESSAGE = 0xC0
MSG_KEEPALIVE = 0xFD


def frame(mtype, payload: bytes) -> bytes:
    return bytes([mtype]) + struct.pack("<I", len(payload)) + payload


def auth_user(username: bytes = b"anon", caps: int = 0x03,
              version: int = 0x00020000, passwd: bytes = b"\x01" * 20) -> bytes:
    return frame(MSG_CLIENT_AUTH_USER, passwd + username + b"\x00" +
                 struct.pack("<II", caps, version))


def chat(*parms: bytes) -> bytes:
    return frame(MSG_CHAT_MESSAGE, b"".join(p + b"\x00" for p in parms))


def write_seeds():
    os.makedirs(OUT, exist_ok=True)
    seeds = {}

    # bare handshake only
    seeds["seed_auth"] = auth_user()

    # handshake + channel info (two active channels, valid records)
    chi = struct.pack("<H", 4)  # mpisize
    for name in (b"guitar", b"drums"):
        chi += name + b"\x00" + struct.pack("<hbBB", 0, 0, 128, 0)
    seeds["seed_channels"] = auth_user() + frame(MSG_CLIENT_SET_CHANNEL_INFO, chi)

    # handshake + usermask subscribe records
    um = b"anon@127.0.0.1\x00" + struct.pack("<I", 0x03)
    um += b"otheruser\x00" + struct.pack("<I", 0x01)
    seeds["seed_usermask"] = auth_user() + frame(MSG_CLIENT_SET_USERMASK, um)

    # handshake + interval upload (OGG-ish payload) + final write
    guid = bytes(range(0x10, 0x20))
    uib = guid + struct.pack("<i", 100000) + b"OGGv" + bytes([0])
    payload = b"OggS" + bytes(0x42 for _ in range(200))  # hostile audio payload
    uiw = guid + bytes([0]) + payload
    uiw_end = guid + bytes([1]) + b"OggS" + b"\xff" * 16
    seeds["seed_interval"] = (auth_user() +
                              frame(MSG_CLIENT_UPLOAD_INTERVAL_BEGIN, uib) +
                              frame(MSG_CLIENT_UPLOAD_INTERVAL_WRITE, uiw) +
                              frame(MSG_CLIENT_UPLOAD_INTERVAL_WRITE, uiw_end))

    # chat traffic
    seeds["seed_chat"] = auth_user() + chat(b"MSG", b"hello world") + \
        chat(b"PRIVMSG", b"anon@127.0.0.1", b"psst") + \
        chat(b"ADMIN", b"/topic fuzzing") + \
        chat(b"SESSION", b"0123456789abcdef", b"1", b"0,4096")

    # lobby commands
    seeds["seed_lobby"] = auth_user() + chat(b"MSG", b"!join room1") + \
        chat(b"MSG", b"!stat") + chat(b"MSG", b"!topic")

    # voting commands
    seeds["seed_vote"] = auth_user() + chat(b"MSG", b"!vote bpm 120") + \
        chat(b"MSG", b"!vote bpi 16") + chat(b"MSG", b"!vote bpm 400")

    # keepalive + zero-length frames + an overlong-declared frame (rejected)
    seeds["seed_keepalive"] = auth_user() + frame(MSG_KEEPALIVE, b"") + \
        frame(MSG_CLIENT_AUTH_USER, b"")[:5].replace(b"\x00\x00\x00\x00",
                                                     b"\xff\x3f\x00\x00")

    # multiple channels + interval + chat mix
    chi2 = struct.pack("<H", 4) + b"ch0\x00" + struct.pack("<hbBB", -30, 64, 0x02, 0)
    uib_silence = bytes(16) + struct.pack("<i", 1) + b"OGGv" + bytes([1])  # zero guid = silence
    seeds["seed_mixed"] = (auth_user(b"anon@127.0.0.1") +
                           frame(MSG_CLIENT_SET_CHANNEL_INFO, chi2) +
                           frame(MSG_CLIENT_UPLOAD_INTERVAL_BEGIN, uib_silence) +
                           chat(b"MSG", b"hi"))

    for name, blob in seeds.items():
        path = os.path.join(OUT, name)
        with open(path, "wb") as f:
            f.write(blob)
        print("wrote %s (%d bytes)" % (path, len(blob)))


if __name__ == "__main__":
    write_seeds()
