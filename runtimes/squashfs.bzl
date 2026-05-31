_RUNTIME_SQUASHFS_CMD = """
set -euo pipefail
pseudo="$(@D)/@PSEUDO_NAME@.pseudo"
rm -f "$${pseudo}"
cat > "$${pseudo}" <<'EOF'
/common/root/etc/hosts F 0 0644 0 0 printf '127.0.0.1 localhost\\n::1 localhost ip6-localhost ip6-loopback\\n'
/common/root/etc/nsswitch.conf F 0 0644 0 0 printf 'passwd: files\\ngroup: files\\nhosts: files dns\\n'
EOF

append_runtime() {
  local entries="$$1"
  local libc="$$2"
  local arch="$$3"
  local manifest="$$4"
  local repo_root
  repo_root="$$(dirname "$${manifest}")"

  printf '/libc/%s/%s/runtime_manifest.json l %s\\n' "$${libc}" "$${arch}" "$${manifest}" >> "$${pseudo}"
  while IFS="$$(printf '\\t')" read -r kind rel target; do
    case "$${kind}" in
      d)
        printf '/libc/%s/%s/root/%s D 0 0755 0 0\\n' "$${libc}" "$${arch}" "$${rel}" >> "$${pseudo}"
        ;;
      f)
        printf '/libc/%s/%s/root/%s l %s/root/%s\\n' "$${libc}" "$${arch}" "$${rel}" "$${repo_root}" "$${rel}" >> "$${pseudo}"
        ;;
      s)
        printf '/libc/%s/%s/root/%s S 0 0777 0 0 %s\\n' "$${libc}" "$${arch}" "$${rel}" "$${target}" >> "$${pseudo}"
        ;;
    esac
  done < "$${entries}"
}

append_shell_runtime() {
  local entries="$$1"
  local shell="$$2"
  local arch="$$3"
  local manifest="$$4"
  local repo_root
  repo_root="$$(dirname "$${manifest}")"

  printf '/shell/%s/%s/runtime_manifest.json l %s\\n' "$${shell}" "$${arch}" "$${manifest}" >> "$${pseudo}"
  while IFS="$$(printf '\\t')" read -r kind rel target; do
    case "$${kind}" in
      d)
        printf '/shell/%s/%s/root/%s D 0 0755 0 0\\n' "$${shell}" "$${arch}" "$${rel}" >> "$${pseudo}"
        ;;
      f)
        printf '/shell/%s/%s/root/%s l %s/root/%s\\n' "$${shell}" "$${arch}" "$${rel}" "$${repo_root}" "$${rel}" >> "$${pseudo}"
        ;;
      s)
        printf '/shell/%s/%s/root/%s S 0 0777 0 0 %s\\n' "$${shell}" "$${arch}" "$${rel}" "$${target}" >> "$${pseudo}"
        ;;
    esac
  done < "$${entries}"
}

@APPEND_RUNTIME_CALLS@
@APPEND_SHELL_RUNTIME_CALLS@

"$(execpath @squashfs-tools//:mksquashfs)" - "$@" \\
  -pf "$${pseudo}" \\
  -pd 'D 0 0755 0 0' \\
  -noappend \\
  -no-recovery \\
  -no-progress \\
  -quiet \\
  -comp zstd \\
  -Xcompression-level 22 \\
  -repro-time 0 \\
  -all-root \\
  -no-xattrs \\
  -no-exports
"""

def runtime_squashfs(name, arch, runtimes, out, shell_runtimes = [], visibility = None):
    srcs = []
    append_calls = []
    for repo, libc in runtimes:
        entries = "@%s//:squashfs_entries.txt" % repo
        manifest = "@%s//:runtime_manifest.json" % repo
        srcs.extend([
            manifest,
            entries,
            "@%s//:tree" % repo,
        ])
        append_calls.append(
            'append_runtime "$(location %s)" "%s" "%s" "$(location %s)"' %
            (entries, libc, arch, manifest),
        )

    append_shell_calls = []
    for repo, shell in shell_runtimes:
        entries = "@%s//:squashfs_entries.txt" % repo
        manifest = "@%s//:runtime_manifest.json" % repo
        srcs.extend([
            manifest,
            entries,
            "@%s//:tree" % repo,
        ])
        append_shell_calls.append(
            'append_shell_runtime "$(location %s)" "%s" "%s" "$(location %s)"' %
            (entries, shell, arch, manifest),
        )

    native.genrule(
        name = name,
        srcs = srcs,
        outs = [out],
        cmd = _RUNTIME_SQUASHFS_CMD.replace("@PSEUDO_NAME@", name).replace(
            "@APPEND_RUNTIME_CALLS@",
            "\n".join(append_calls),
        ).replace(
            "@APPEND_SHELL_RUNTIME_CALLS@",
            "\n".join(append_shell_calls),
        ),
        tools = ["@squashfs-tools//:mksquashfs"],
        visibility = visibility,
    )
