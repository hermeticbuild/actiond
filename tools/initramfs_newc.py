#!/usr/bin/env python3
import os
import sys


DIR_MODE = 0o040755
FILE_MODE = 0o100755


def align4(out):
    pad = (-out.tell()) % 4
    if pad:
        out.write(b"\0" * pad)


def write_entry(out, ino, name, mode, data=b""):
    name_bytes = name.encode("utf-8") + b"\0"
    fields = [
        ino,
        mode,
        0,
        0,
        2 if mode & 0o040000 else 1,
        0,
        len(data),
        0,
        0,
        0,
        0,
        len(name_bytes),
        0,
    ]
    out.write(b"070701")
    for field in fields:
        out.write(f"{field:08x}".encode("ascii"))
    out.write(name_bytes)
    align4(out)
    out.write(data)
    align4(out)


def main(argv):
    if len(argv) != 3:
        print("usage: initramfs_newc.py OUT ACTIOND", file=sys.stderr)
        return 2

    out_path = argv[1]
    actiond_path = argv[2]
    with open(actiond_path, "rb") as f:
        actiond = f.read()

    entries = []
    for directory in ("dev", "proc", "sys", "tmp", "work", "cas"):
        entries.append((directory, DIR_MODE, b""))
    entries.append(("init", FILE_MODE, actiond))
    entries.append(("actiond", FILE_MODE, actiond))

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as out:
        for ino, (name, mode, data) in enumerate(entries, start=1):
            write_entry(out, ino, name, mode, data)
        write_entry(out, len(entries) + 1, "TRAILER!!!", 0, b"")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
