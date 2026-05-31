_MAX_RUNTIME_TREE_ENTRIES = 2000000

def _json_string(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _is_symlink(path):
    return str(path.realpath) != str(path)

def _runtime_symlink_target(root, path):
    root_real = str(root.realpath)
    target_real = str(path.realpath)
    if target_real == root_real:
        return "/"

    root_prefix = root_real + "/"
    if target_real.startswith(root_prefix):
        return "/" + target_real[len(root_prefix):]

    fail("runtime symlink %s points outside runtime root: %s" % (path, target_real))

def _runtime_entries(root):
    entries = []
    paths = [("", root)]
    for _ in range(_MAX_RUNTIME_TREE_ENTRIES):
        if not paths:
            return entries

        rel, path = paths.pop()
        if rel and _is_symlink(path):
            entries.append(("s", rel, _runtime_symlink_target(root, path)))
            continue

        if rel:
            if path.is_dir:
                entries.append(("d", rel, ""))
            else:
                entries.append(("f", rel, ""))

        if path.is_dir:
            children = {}
            for child in path.readdir(watch = "no"):
                children[child.basename] = child
            for child_name in sorted(children.keys(), reverse = True):
                child_rel = child_name if not rel else rel + "/" + child_name
                paths.append((child_rel, children[child_name]))

    fail("runtime tree exceeds max entry limit %d while writing squashfs entries" % _MAX_RUNTIME_TREE_ENTRIES)

def _write_runtime_entries(rctx):
    root = rctx.path("root")
    lines = []
    for kind, rel, target in _runtime_entries(root):
        lines.append("%s\t%s\t%s" % (kind, rel, target))
    rctx.file("squashfs_entries.txt", "\n".join(lines) + "\n", executable = False)

def _shell_deb_runtime_impl(rctx):
    if len(rctx.attr.urls) != len(rctx.attr.sha256s):
        fail("urls and sha256s must have the same length")

    rctx.file("root/.actiond-runtime-root", "")
    for i, url in enumerate(rctx.attr.urls):
        deb_dir = "deb_%d" % i
        rctx.download_and_extract(
            url = url,
            sha256 = rctx.attr.sha256s[i],
            output = deb_dir,
            type = ".deb",
        )
        extracted = False
        for suffix in ["xz", "zst", "gz"]:
            data_archive = "%s/data.tar.%s" % (deb_dir, suffix)
            if rctx.path(data_archive).exists:
                rctx.extract(data_archive, output = "root")
                extracted = True
                break
        if not extracted:
            fail("unsupported .deb payload compression for %s" % url)

    for path in [
        "root/DEBIAN",
        "root/usr/share/doc",
        "root/usr/share/info",
        "root/usr/share/lintian",
        "root/usr/share/locale",
        "root/usr/share/man",
        "root/var",
    ] + ["deb_%d" % i for i in range(len(rctx.attr.urls))]:
        rctx.delete(path)

    rctx.file("root/usr/bin/env", """#!/bin/bash
exec "$@"
""", executable = True)

    _write_runtime_entries(rctx)

    manifest = """{
  "name": %s,
  "arch": %s,
  "debs": [%s],
  "mounts": [
    ["root/bin", "/bin"],
    ["root/usr/bin", "/usr/bin"]
  ]
}
""" % (
        _json_string(rctx.attr.shell),
        _json_string(rctx.attr.arch),
        ", ".join([_json_string(url) for url in rctx.attr.urls]),
    )
    rctx.file("runtime_manifest.json", manifest)

    rctx.file("BUILD.bazel", """
filegroup(
    name = "tree",
    srcs = glob(["root/**"]),
    visibility = ["//visibility:public"],
)

exports_files([
    "runtime_manifest.json",
    "squashfs_entries.txt",
])
""")

shell_deb_runtime = repository_rule(
    implementation = _shell_deb_runtime_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "shell": attr.string(mandatory = True),
        "sha256s": attr.string_list(mandatory = True),
        "urls": attr.string_list(mandatory = True),
    },
)
