def _add_common_args(args, out_file, out_dir, files, srcs, trees):
    args.add("--out-file", out_file)
    args.add("--out-dir", out_dir)
    args.add("--out-count", str(files))
    for src in srcs:
        args.add("--scan", src.path)
    for tree in trees:
        args.add("--scan", tree.path)
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)

def _stress_tree_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".tree")
    out_file = ctx.actions.declare_file(ctx.label.name + ".manifest.txt")
    transitive = [dep[DefaultInfo].files for dep in ctx.attr.trees]
    inputs = depset(ctx.files.srcs, transitive = transitive)

    args = ctx.actions.args()
    _add_common_args(args, out_file.path, out_dir.path, ctx.attr.files, ctx.files.srcs, ctx.files.trees)
    ctx.actions.run(
        executable = ctx.executable.tool,
        inputs = inputs,
        outputs = [out_file, out_dir],
        arguments = [args],
        mnemonic = "ActiondStressTree",
        progress_message = "Generating stress tree %{label}",
    )
    return DefaultInfo(files = depset([out_file, out_dir]))

stress_tree = rule(
    implementation = _stress_tree_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "trees": attr.label_list(),
        "files": attr.int(default = 16),
        "tool": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
)

def _stress_consumer_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".tree")
    out_file = ctx.actions.declare_file(ctx.label.name + ".txt")
    transitive = [dep[DefaultInfo].files for dep in ctx.attr.trees]
    inputs = depset(ctx.files.srcs, transitive = transitive)

    args = ctx.actions.args()
    _add_common_args(args, out_file.path, out_dir.path, ctx.attr.files, ctx.files.srcs, ctx.files.trees)
    ctx.actions.run(
        executable = ctx.executable.tool,
        inputs = inputs,
        outputs = [out_file, out_dir],
        arguments = [args],
        mnemonic = "ActiondStressConsume",
        progress_message = "Consuming stress inputs %{label}",
    )
    return DefaultInfo(files = depset([out_file, out_dir]))

stress_consumer = rule(
    implementation = _stress_consumer_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "trees": attr.label_list(),
        "files": attr.int(default = 16),
        "tool": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
)

