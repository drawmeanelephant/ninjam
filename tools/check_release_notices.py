#!/usr/bin/env python3
"""Release-packaging gate for third-party notices.

Run by .github/workflows/release.yml against every packaged binary archive.
Fails (exit != 0) unless each archive contains THIRD-PARTY-NOTICES.txt and
LICENSE, the notices text still carries every component's copyright line, and
the upstream pins recorded in the notices match the GIT_TAG declarations in
the CMake build files. Also verifies the in-tree vendored components still
carry the license lines the notices reproduce.
"""

import re
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
NOTICES_NAME = "THIRD-PARTY-NOTICES.txt"

# component -> (pin in the notices file, required copyright fragments,
#               CMake file + FetchContent name for pin cross-check or None)
COMPONENTS = {
    "WDL": {
        "pin": "in-tree",
        "fragments": ["Copyright (C) 2006 and later Cockos Incorporated"],
        "in_tree_header": "WDL/fft.h",
    },
    "JNetLib": {
        "pin": "in-tree",
        "fragments": [
            "Copyright (C) 2008 Cockos Inc",
            "Copyright (C) 2000-2003 Nullsoft, Inc.",
        ],
        "in_tree_header": "WDL/jnetlib/jnetlib.h",
    },
    "libogg": {
        "pin": "v1.3.6",
        "fragments": ["Copyright (c) 2002, Xiph.org Foundation"],
        "cmake": ("CMakeLists.txt", "ogg"),
    },
    "libvorbis": {
        "pin": "v1.3.7",
        "fragments": ["Copyright (c) 2002-2020 Xiph.org Foundation"],
        "cmake": ("CMakeLists.txt", "vorbis"),
    },
    "Dear ImGui": {
        "pin": "v1.92.9",
        "fragments": ["The MIT License (MIT)", "Omar Cornut"],
        "cmake": ("ninjam/imguiclient/CMakeLists.txt", "imgui"),
    },
    "GLFW": {
        "pin": "3.5.1",
        "fragments": ["Marcus Geelnard", "Camilla Löwy"],
        "cmake": ("ninjam/imguiclient/CMakeLists.txt", "glfw"),
    },
    "miniaudio": {
        "pin": "0.11.25",
        "fragments": ["Public Domain", "MIT No Attribution", "David Reid"],
        "cmake": ("ninjam/imguiclient/CMakeLists.txt", "miniaudio"),
    },
}


def fail(msg: str) -> None:
    print(f"check_release_notices: FAIL: {msg}")
    sys.exit(1)


def parse_pins_from_cmake() -> dict:
    """FetchContent_Declare(<name> ... GIT_TAG <tag>) blocks in both build files."""
    pins = {}
    files = {cmake[0] for c in COMPONENTS.values() if (cmake := c.get("cmake"))}
    for rel in files:
        text = (REPO_ROOT / rel).read_text(encoding="utf-8")
        for m in re.finditer(
            r"FetchContent_Declare\((\w+)([^)]*)\)", text, re.DOTALL
        ):
            tag = re.search(r"GIT_TAG\s+(\S+)", m.group(2))
            if tag:
                pins[m.group(1)] = tag.group(1)
    return pins


def parse_pins_from_notices(text: str) -> dict:
    """Section headers look like:

    2. JNetLib
       Linked into: ninjamsrv, ninjam-client (the WDL/jnetlib socket layer)
       ...
       Pin:         in-tree

    Anchoring on 'Linked into:' keeps numbered lines inside license texts
    ('1. The origin of this software...') from matching as headers.
    """
    pins = {}
    for m in re.finditer(
        r"^\d+\. ([^\n]+)\n   Linked into:[^\n]*\n(?:.*\n)*?   Pin:[ \t]*(\S+)",
        text,
        re.MULTILINE,
    ):
        pins[m.group(1).strip()] = m.group(2).strip()
    return pins


def check_notices_text(where: str, text: str) -> None:
    for name, spec in COMPONENTS.items():
        for frag in spec["fragments"]:
            if frag not in text:
                fail(f"{where}: {name} notice lost its required line: {frag!r}")


def check_pins(notices_text: str) -> None:
    cmake_pins = parse_pins_from_cmake()
    notices_pins = parse_pins_from_notices(notices_text)
    for name, spec in COMPONENTS.items():
        recorded = notices_pins.get(name)
        if recorded is None:
            fail(f"notices have no Pin line for {name}")
        if spec["pin"] == "in-tree":
            if recorded != "in-tree":
                fail(f"{name} is vendored in-tree but notices record Pin: {recorded}")
            header = REPO_ROOT / spec["in_tree_header"]
            if not header.is_file():
                fail(f"vendored header {spec['in_tree_header']} is missing")
            if spec["fragments"][0] not in header.read_text(
                encoding="utf-8", errors="replace"
            ):
                fail(f"vendored {spec['in_tree_header']} no longer carries "
                     f"its license header")
            continue
        if recorded != spec["pin"]:
            fail(f"{name}: THIRD-PARTY-NOTICES.txt pins {recorded} "
                 f"but the checker expects {spec['pin']} — update both together")
        cmake_file, fetch_name = spec["cmake"]
        actual = cmake_pins.get(fetch_name)
        if actual is None:
            fail(f"{cmake_file} no longer pins a FetchContent revision for "
                 f"{fetch_name}, but the notices still record {recorded}")
        if actual != recorded:
            fail(f"{name}: CMake pins {actual} but THIRD-PARTY-NOTICES.txt "
                 f"records {recorded} — regenerate the notices for the new pin")


def check_archive(path: Path) -> None:
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        for required in (NOTICES_NAME, "LICENSE", "README.md"):
            if required not in names:
                fail(f"{path}: archive is missing {required}")
        text = zf.read(NOTICES_NAME).decode("utf-8")
        check_notices_text(str(path), text)


def main() -> None:
    notices_path = REPO_ROOT / NOTICES_NAME
    if not notices_path.is_file():
        fail(f"{NOTICES_NAME} is missing from the repository")
    notices_text = notices_path.read_text(encoding="utf-8")
    check_notices_text(NOTICES_NAME, notices_text)
    check_pins(notices_text)

    archives = [Path(a) for a in sys.argv[1:]]
    if not archives:
        print("check_release_notices: notices + pins OK (no archives given)")
        return
    for archive in archives:
        check_archive(archive)
        print(f"check_release_notices: OK {archive}")


if __name__ == "__main__":
    main()
