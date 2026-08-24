load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

_RUNTIME_SQUASHFS_SCRIPT = """#!/bin/sh
set -eu
output="${OUTPUT:?}"
mksquashfs="${MKSQUASHFS:?}"
pseudo="${output}.pseudo"
printf '%s\n' \
  "/common/root/etc/hosts F 0 0644 0 0 printf '127.0.0.1 localhost\\n::1 localhost ip6-localhost ip6-loopback\\n'" \
  "/common/root/etc/nsswitch.conf F 0 0644 0 0 printf 'passwd: files\\ngroup: files\\nhosts: files dns\\n'" \
  "/common/root/etc/passwd F 0 0644 0 0 printf 'root:x:0:0:root:/root:/bin/sh\\nnobody:x:65534:65534:nobody:/:/bin/sh\\n'" \
  "/common/root/etc/group F 0 0644 0 0 printf 'root:x:0:\\nnogroup:x:65534:\\n'" \
  > "${pseudo}"

append_runtime() {
  entries="$1"
  libc="$2"
  arch="$3"
  manifest="$4"
  repo_root="${manifest%/*}"

  printf '/libc/%s/%s/runtime_manifest.json l %s\\n' "${libc}" "${arch}" "${manifest}" >> "${pseudo}"
  while IFS="$(printf '\\t')" read -r kind rel target; do
    case "${kind}" in
      d)
        printf '/libc/%s/%s/root/%s D 0 0755 0 0\\n' "${libc}" "${arch}" "${rel}" >> "${pseudo}"
        ;;
      f)
        printf '/libc/%s/%s/root/%s l %s/root/%s\\n' "${libc}" "${arch}" "${rel}" "${repo_root}" "${rel}" >> "${pseudo}"
        ;;
      s)
        printf '/libc/%s/%s/root/%s S 0 0777 0 0 %s\\n' "${libc}" "${arch}" "${rel}" "${target}" >> "${pseudo}"
        ;;
    esac
  done < "${entries}"
}

append_shell_runtime() {
  entries="$1"
  shell="$2"
  arch="$3"
  manifest="$4"
  repo_root="${manifest%/*}"

  printf '/shell/%s/%s/runtime_manifest.json l %s\\n' "${shell}" "${arch}" "${manifest}" >> "${pseudo}"
  while IFS="$(printf '\\t')" read -r kind rel target; do
    case "${kind}" in
      d)
        printf '/shell/%s/%s/root/%s D 0 0755 0 0\\n' "${shell}" "${arch}" "${rel}" >> "${pseudo}"
        ;;
      f)
        printf '/shell/%s/%s/root/%s l %s/root/%s\\n' "${shell}" "${arch}" "${rel}" "${repo_root}" "${rel}" >> "${pseudo}"
        ;;
      s)
        printf '/shell/%s/%s/root/%s S 0 0777 0 0 %s\\n' "${shell}" "${arch}" "${rel}" "${target}" >> "${pseudo}"
        ;;
    esac
  done < "${entries}"
}

@APPEND_RUNTIME_CALLS@
@APPEND_SHELL_RUNTIME_CALLS@

"${mksquashfs}" - "${output}" \
  -pf "${pseudo}" \
  -pd 'D 0 0755 0 0' \
  -noappend \
  -no-recovery \
  -no-progress \
  -quiet \
  -comp zstd \
  -Xcompression-level 22 \
  -repro-time 0 \
  -all-root \
  -no-xattrs \
  -no-exports
"""

def _runtime_squashfs_action_impl(ctx):
    args = ctx.actions.args()
    for value in ctx.attr.args:
        args.add(ctx.expand_location(value, targets = ctx.attr.srcs))

    ctx.actions.run(
        arguments = [args],
        env = {
            "MKSQUASHFS": ctx.executable.mksquashfs.path,
            "OUTPUT": ctx.outputs.out.path,
        },
        executable = ctx.executable.runner,
        inputs = ctx.files.srcs,
        outputs = [ctx.outputs.out],
        tools = [ctx.attr.mksquashfs[DefaultInfo].files_to_run],
    )

_runtime_squashfs_action = rule(
    implementation = _runtime_squashfs_action_impl,
    attrs = {
        "args": attr.string_list(),
        "mksquashfs": attr.label(cfg = "exec", executable = True, mandatory = True),
        "out": attr.output(mandatory = True),
        "runner": attr.label(cfg = "exec", executable = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
    },
)

def runtime_squashfs(name, arch, runtimes, out, shell_runtimes = [], visibility = None):
    srcs = []
    args = []
    append_calls = []
    for repo, libc in runtimes:
        entries = "@%s//:squashfs_entries.txt" % repo
        manifest = "@%s//:runtime_manifest.json" % repo
        srcs.extend([
            manifest,
            entries,
            "@%s//:tree" % repo,
        ])
        args.extend([
            "$(location %s)" % entries,
            "$(location %s)" % manifest,
        ])
        append_calls.extend([
            'append_runtime "$1" "%s" "%s" "$2"' % (libc, arch),
            "shift 2",
        ])

    append_shell_calls = []
    for repo, shell in shell_runtimes:
        entries = "@%s//:squashfs_entries.txt" % repo
        manifest = "@%s//:runtime_manifest.json" % repo
        srcs.extend([
            manifest,
            entries,
            "@%s//:tree" % repo,
        ])
        args.extend([
            "$(location %s)" % entries,
            "$(location %s)" % manifest,
        ])
        append_shell_calls.extend([
            'append_shell_runtime "$1" "%s" "%s" "$2"' % (shell, arch),
            "shift 2",
        ])

    write_file(
        name = name + "_script",
        out = name + ".sh",
        content = _RUNTIME_SQUASHFS_SCRIPT.replace(
            "@APPEND_RUNTIME_CALLS@",
            "\n".join(append_calls),
        ).replace(
            "@APPEND_SHELL_RUNTIME_CALLS@",
            "\n".join(append_shell_calls),
        ).splitlines(),
        is_executable = True,
    )

    sh_binary(
        name = name + "_runner",
        srcs = [":" + name + "_script"],
        use_bash_launcher = False,
    )

    _runtime_squashfs_action(
        name = name,
        args = args,
        mksquashfs = "@squashfs-tools//:mksquashfs",
        out = out,
        runner = ":" + name + "_runner",
        srcs = srcs,
        visibility = visibility,
    )
