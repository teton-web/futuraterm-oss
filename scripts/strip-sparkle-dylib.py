#!/usr/bin/env python3
"""Remove Sparkle LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB from a Mach-O (thin or fat).

xcodegen cannot omit an SPM product per configuration, so AppStore still links
Sparkle. After the framework is deleted from the bundle the remaining required
load command makes the binary unlaunchable. Zeroing those commands (and
shrinking ncmds/sizeofcmds) is the post-link counterpart of the strip.
"""
from __future__ import annotations

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18
LC_REEXPORT_DYLIB = 0x1F
LC_LOAD_UPWARD_DYLIB = 0x23


def _u32(data: bytes, off: int, be: bool) -> int:
    fmt = ">I" if be else "<I"
    return struct.unpack_from(fmt, data, off)[0]


def _p32(data: bytearray, off: int, value: int, be: bool) -> None:
    fmt = ">I" if be else "<I"
    struct.pack_into(fmt, data, off, value)


def _strip_thin(data: bytearray, start: int, size: int) -> None:
    magic = _u32(data, start, False)
    if magic == MH_MAGIC_64:
        be = False
    elif magic == MH_CIGAM_64:
        be = True
    else:
        raise SystemExit(f"unsupported mach-o magic {magic:#x} at {start}")

    ncmds = _u32(data, start + 16, be)
    sizeofcmds = _u32(data, start + 20, be)
    cmd_off = start + 32
    end = cmd_off + sizeofcmds
    if end > start + size:
        raise SystemExit("sizeofcmds overflows slice")

    kept = bytearray()
    kept_n = 0
    off = cmd_off
    for _ in range(ncmds):
        cmd = _u32(data, off, be)
        cmdsize = _u32(data, off + 4, be)
        if cmdsize < 8 or off + cmdsize > end:
            raise SystemExit("invalid load command size")
        blob = bytes(data[off : off + cmdsize])
        drop = False
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB):
            name_off = _u32(data, off + 8, be)
            name = bytes(data[off + name_off : off + cmdsize]).split(b"\x00", 1)[0]
            if b"Sparkle" in name:
                drop = True
        if not drop:
            kept.extend(blob)
            kept_n += 1
        off += cmdsize

    data[cmd_off:end] = b"\x00" * sizeofcmds
    data[cmd_off : cmd_off + len(kept)] = kept
    _p32(data, start + 16, kept_n, be)
    _p32(data, start + 20, len(kept), be)


def _strip_file(path: str) -> None:
    with open(path, "rb") as fh:
        raw = bytearray(fh.read())
    magic = _u32(raw, 0, True)
    if magic in (FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64):
        is64 = magic in (FAT_MAGIC_64, FAT_CIGAM_64)
        nfat = _u32(raw, 4, True)
        off = 8
        for _ in range(nfat):
            if is64:
                offset = struct.unpack_from(">Q", raw, off + 8)[0]
                size = struct.unpack_from(">Q", raw, off + 16)[0]
                off += 32
            else:
                offset = _u32(raw, off + 8, True)
                size = _u32(raw, off + 12, True)
                off += 20
            _strip_thin(raw, offset, size)
    else:
        _strip_thin(raw, 0, len(raw))
    with open(path, "wb") as fh:
        fh.write(raw)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <mach-o>")
    _strip_file(sys.argv[1])


if __name__ == "__main__":
    main()
