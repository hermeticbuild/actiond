def _json_string(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _shell_deb_runtime_impl(rctx):
    if len(rctx.attr.urls) != 1 or len(rctx.attr.sha256s) != 1:
        fail("shell_deb_runtime expects exactly one static shell package")

    rctx.download_and_extract(
        url = rctx.attr.urls[0],
        sha256 = rctx.attr.sha256s[0],
        output = "deb",
        type = ".deb",
    )

    extracted = False
    for suffix in ["xz", "zst", "gz"]:
        data_archive = "deb/data.tar.%s" % suffix
        if rctx.path(data_archive).exists:
            rctx.extract(data_archive, output = "root")
            extracted = True
            break
    if not extracted:
        fail("unsupported .deb payload compression for %s" % rctx.attr.urls[0])

    bash_static = rctx.path("root/bin/bash-static")
    if not bash_static.exists:
        fail("expected static bash payload at root/bin/bash-static")
    rctx.symlink(bash_static, "root/bin/bash")

    rctx.file("squashfs_entries.txt", "\n".join([
        "d\tbin\t",
        "f\tbin/bash-static\t",
        "s\tbin/bash\t/bin/bash-static",
        "",
    ]), executable = False)

    manifest = """{
  "name": %s,
  "arch": %s,
  "debs": [%s],
  "mounts": [
    ["root/bin", "/bin"]
  ]
}
""" % (
        _json_string(rctx.attr.shell),
        _json_string(rctx.attr.arch),
        _json_string(rctx.attr.urls[0]),
    )
    rctx.file("runtime_manifest.json", manifest)

    rctx.file("BUILD.bazel", """
filegroup(
    name = "tree",
    srcs = [
        "root/bin/bash",
        "root/bin/bash-static",
    ],
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
