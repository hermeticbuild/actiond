def _json_string(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _glibc_deb_runtime_impl(rctx):
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

    rctx.execute([
        "/bin/sh",
        "-c",
        """
set -euo pipefail
rm -rf \
  deb_* \
  root/DEBIAN \
  root/usr/share/doc \
  root/usr/share/info \
  root/usr/share/lintian \
  root/usr/share/locale \
  root/usr/share/man \
  root/var
mkdir -p root/etc
cat > root/etc/nsswitch.conf <<'EOF'
passwd: files
group: files
hosts: files dns
EOF
""",
    ])

    manifest = """{
  "name": %s,
  "arch": %s,
  "debs": [%s],
  "mounts": [
    ["root/lib", "/lib"],
    ["root/lib64", "/lib64"],
    ["root/usr/lib", "/usr/lib"],
    ["root/etc", "/etc"]
  ],
  "interpreters": [%s]
}
""" % (
        _json_string(rctx.attr.libc),
        _json_string(rctx.attr.arch),
        ", ".join([_json_string(url) for url in rctx.attr.urls]),
        ", ".join([_json_string(path) for path in rctx.attr.interpreters]),
    )
    rctx.file("runtime_manifest.json", manifest)

    rctx.file("BUILD.bazel", """
filegroup(
    name = "tree",
    srcs = glob(["root/**"]),
    visibility = ["//visibility:public"],
)

exports_files(["runtime_manifest.json"])
""")

glibc_deb_runtime = repository_rule(
    implementation = _glibc_deb_runtime_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "interpreters": attr.string_list(mandatory = True),
        "libc": attr.string(mandatory = True),
        "sha256s": attr.string_list(mandatory = True),
        "urls": attr.string_list(mandatory = True),
    },
)
