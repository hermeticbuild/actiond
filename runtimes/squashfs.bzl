"""Build the guest runtime image without shell subprocesses."""

def _runtime_squashfs_action_impl(ctx):
    args = ctx.actions.args()
    args.add(ctx.executable.mksquashfs)
    args.add(ctx.outputs.out)
    for value in ctx.attr.args:
        args.add(ctx.expand_location(value, targets = ctx.attr.srcs))

    ctx.actions.run(
        arguments = [args],
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
        "runner": attr.label(default = Label("//tools:runtime_squashfs"), cfg = "exec", executable = True),
        "srcs": attr.label_list(allow_files = True),
    },
)

def runtime_squashfs(name, arch, runtimes, out, shell_runtimes = [], visibility = None):
    srcs = []
    args = []
    for repo, libc in runtimes:
        entries = "@%s//:squashfs_entries.txt" % repo
        manifest = "@%s//:runtime_manifest.json" % repo
        srcs.extend([
            manifest,
            entries,
            "@%s//:tree" % repo,
        ])
        args.extend([
            "libc",
            libc,
            arch,
            "$(location %s)" % entries,
            "$(location %s)" % manifest,
        ])

    for repo, shell in shell_runtimes:
        entries = "@%s//:squashfs_entries.txt" % repo
        manifest = "@%s//:runtime_manifest.json" % repo
        srcs.extend([
            manifest,
            entries,
            "@%s//:tree" % repo,
        ])
        args.extend([
            "shell",
            shell,
            arch,
            "$(location %s)" % entries,
            "$(location %s)" % manifest,
        ])

    _runtime_squashfs_action(
        name = name,
        args = args,
        mksquashfs = "@squashfs-tools//:mksquashfs",
        out = out,
        srcs = srcs,
        visibility = visibility,
    )
