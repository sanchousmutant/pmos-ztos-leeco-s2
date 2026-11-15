#!/usr/bin/env python3
"""Build a newc cpio from a manifest (type<TAB>relpath<TAB>linktarget).

Usage: build_initramfs.py [MANIFEST] [OUT] [ROOT]
       defaults: tiny_manifest.txt initramfs-tiny.cpio tiny_initramfs
"""
import stat
import sys

ROOT = "tiny_initramfs"
MANIFEST = "tiny_manifest.txt"
OUT = "initramfs-tiny.cpio"
EXEC = {"init", "init.switch", "bin/busybox", "sbin/adbd"}  # force exec bit

if len(sys.argv) > 1:
    MANIFEST = sys.argv[1]
if len(sys.argv) > 2:
    OUT = sys.argv[2]
if len(sys.argv) > 3:
    ROOT = sys.argv[3]

def h(n): return b"%08X" % (n & 0xFFFFFFFF)
def pad4(d):
    r = len(d) % 4
    return d + (b"\x00" * (4 - r) if r else b"")

def entry(ino, name, mode, data=b"", nlink=1):
    nb = name.encode() + b"\x00"
    hdr = (b"070701" + h(ino) + h(mode) + h(0) + h(0) + h(nlink) +
           h(0) + h(len(data)) + h(0) + h(0) + h(0) + h(0) + h(len(nb)) + h(0))
    out = pad4(hdr + nb)
    if data: out += pad4(data)
    return out

def main():
    blob = b""
    ino = 1
    blob += entry(ino, ".", stat.S_IFDIR | 0o755, nlink=2); ino += 1
    with open(MANIFEST, "r", encoding="utf-8") as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    for ln in lines:
        parts = ln.split("\t")
        kind, rel = parts[0], parts[1]
        target = parts[2] if len(parts) > 2 else ""
        rel = rel.replace("\\", "/")
        if kind == "d":
            blob += entry(ino, rel, stat.S_IFDIR | 0o755, nlink=2)
        elif kind == "l":
            blob += entry(ino, rel, stat.S_IFLNK | 0o777, target.encode())
        else:
            with open(f"{ROOT}/{rel}", "rb") as f:
                data = f.read()
            perm = 0o755 if rel in EXEC else 0o644
            blob += entry(ino, rel, stat.S_IFREG | perm, data)
        ino += 1
    blob += entry(0, "TRAILER!!!", 0, nlink=1)
    with open(OUT, "wb") as f:
        f.write(blob)
    print(f"wrote {OUT}: {len(blob)} bytes, {ino} entries")

if __name__ == "__main__":
    main()
