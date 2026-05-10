#!/usr/bin/env python3
import os
import sys


DIR_MODE = 0o040755
FILE_MODE = 0o100755
MODULE_MODE = 0o100644


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
    if len(argv) < 3:
        print("usage: initramfs_newc.py OUT ACTIOND [MODULE...]", file=sys.stderr)
        return 2

    out_path = argv[1]
    actiond_path = argv[2]
    module_paths = []
    file_specs = []
    for arg in argv[3:]:
        if arg.startswith("--file="):
            spec = arg[len("--file="):]
            src, sep, dest = spec.partition("=")
            if not sep or not src or not dest:
                print(f"invalid file spec: {arg}", file=sys.stderr)
                return 2
            file_specs.append((src, dest.lstrip("/")))
        else:
            module_paths.append(arg)
    with open(actiond_path, "rb") as f:
        actiond = f.read()

    entries = []
    seen_dirs = set()
    seen_files = set()

    def add_dir(path):
        path = path.strip("/")
        if not path or path in seen_dirs:
            return
        parent = os.path.dirname(path)
        if parent:
            add_dir(parent)
        seen_dirs.add(path)
        entries.append((path, DIR_MODE, b""))

    def add_file(path, mode, data):
        path = path.strip("/")
        parent = os.path.dirname(path)
        if parent:
            add_dir(parent)
        if path in seen_files:
            return
        seen_files.add(path)
        entries.append((path, mode, data))

    for directory in ("dev", "proc", "sys", "tmp", "work", "cas", "modules"):
        add_dir(directory)
    add_file("init", FILE_MODE, actiond)
    add_file("actiond", FILE_MODE, actiond)
    for module_path in module_paths:
        with open(module_path, "rb") as f:
            add_file(f"modules/{os.path.basename(module_path)}", MODULE_MODE, f.read())
    for src, dest in file_specs:
        with open(src, "rb") as f:
            add_file(dest, FILE_MODE, f.read())

    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "wb") as out:
        for ino, (name, mode, data) in enumerate(entries, start=1):
            write_entry(out, ino, name, mode, data)
        write_entry(out, len(entries) + 1, "TRAILER!!!", 0, b"")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
