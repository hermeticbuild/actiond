def _stress_case(ctx):
    if ctx.attr.stress_case:
        return ctx.attr.stress_case
    return ctx.label.name

def _stress_env(ctx):
    env = {"ACTIOND_STRESS_CASE": _stress_case(ctx)}
    if ctx.attr.input_mode:
        env["ACTIOND_INPUT_MODE"] = ctx.attr.input_mode
    return env

def _pad2(value):
    if value < 10:
        return "0%d" % value
    return "%d" % value

def _pad3(value):
    if value < 10:
        return "00%d" % value
    if value < 100:
        return "0%d" % value
    return "%d" % value

def _add_common_args(args, out_file, out_dir, files, srcs, trees, expect_network_blocked, expect_loopback, expect_localhost_hosts):
    args.add("--out-file", out_file)
    args.add("--out-dir", out_dir)
    args.add("--out-count", str(files))
    if expect_network_blocked:
        args.add("--expect-network-blocked")
    if expect_loopback:
        args.add("--expect-loopback")
    if expect_localhost_hosts:
        args.add("--expect-localhost-hosts")
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
    _add_common_args(args, out_file.path, out_dir.path, ctx.attr.files, ctx.files.srcs, ctx.files.trees, ctx.attr.expect_network_blocked, ctx.attr.expect_loopback, ctx.attr.expect_localhost_hosts)
    ctx.actions.run(
        executable = ctx.executable.tool,
        inputs = inputs,
        outputs = [out_file, out_dir],
        arguments = [args],
        env = _stress_env(ctx),
        execution_requirements = ctx.attr.execution_requirements,
        mnemonic = "ActiondStressTree",
        progress_message = "Generating stress tree %{label}",
    )
    return DefaultInfo(files = depset([out_dir]))

stress_tree = rule(
    implementation = _stress_tree_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "trees": attr.label_list(),
        "files": attr.int(default = 16),
        "input_mode": attr.string(),
        "stress_case": attr.string(),
        "execution_requirements": attr.string_dict(),
        "expect_network_blocked": attr.bool(default = False),
        "expect_loopback": attr.bool(default = False),
        "expect_localhost_hosts": attr.bool(default = False),
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
    _add_common_args(args, out_file.path, out_dir.path, ctx.attr.files, ctx.files.srcs, ctx.files.trees, ctx.attr.expect_network_blocked, ctx.attr.expect_loopback, ctx.attr.expect_localhost_hosts)
    ctx.actions.run(
        executable = ctx.executable.tool,
        inputs = inputs,
        outputs = [out_file, out_dir],
        arguments = [args],
        env = _stress_env(ctx),
        execution_requirements = ctx.attr.execution_requirements,
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
        "input_mode": attr.string(),
        "stress_case": attr.string(),
        "execution_requirements": attr.string_dict(),
        "expect_network_blocked": attr.bool(default = False),
        "expect_loopback": attr.bool(default = False),
        "expect_localhost_hosts": attr.bool(default = False),
        "tool": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
)

def stress_workload(name, tool):
    stress_targets = []

    stress_tree(
        name = "shared_generated_tree",
        execution_requirements = {"libc": "glibc2.35"},
        files = 256,
        srcs = [":bare_inputs"],
        stress_case = "generated_tree_producer",
        tool = tool,
    )

    for i in range(1, 9):
        target = "generated_tree_reuse_%s" % _pad2(i)
        stress_consumer(
            name = target,
            execution_requirements = {"libc": "glibc2.35"},
            files = 8,
            stress_case = "generated_tree_reuse",
            tool = tool,
            trees = [":shared_generated_tree"],
        )
        stress_targets.append(":" + target)

    for i in range(1, 5):
        target = "source_dir_reuse_%s" % _pad2(i)
        stress_consumer(
            name = target,
            execution_requirements = {"libc": "glibc2.35"},
            files = 8,
            srcs = [":source_tree_inputs"],
            stress_case = "source_dir_tree",
            tool = tool,
        )
        stress_targets.append(":" + target)

    for i in range(1, 9):
        group = "nested_group_%s" % _pad2(i)
        target = "nested_files_%s" % _pad2(i)
        native.filegroup(
            name = group,
            srcs = native.glob(["nested_files/group_%s/foo/bar/baz/*.txt" % _pad3(i)]),
        )
        stress_consumer(
            name = target,
            execution_requirements = {"libc": "glibc2.35"},
            files = 8,
            input_mode = "files",
            srcs = [":" + group],
            stress_case = "nested_individual_files",
            tool = tool,
        )
        stress_targets.append(":" + target)

    for i in range(1, 5):
        target = "bare_files_%s" % _pad2(i)
        stress_consumer(
            name = target,
            execution_requirements = {"libc": "glibc2.35"},
            files = 8,
            input_mode = "files",
            srcs = [":bare_inputs"],
            stress_case = "bare_individual_files",
            tool = tool,
        )
        stress_targets.append(":" + target)

    stress_consumer(
        name = "mixed_all",
        execution_requirements = {"libc": "glibc2.35"},
        expect_localhost_hosts = True,
        expect_loopback = True,
        expect_network_blocked = True,
        files = 64,
        srcs = [
            ":bare_inputs",
            ":nested_individual_inputs",
            ":source_tree_inputs",
        ],
        stress_case = "mixed_all",
        tool = tool,
        trees = [":shared_generated_tree"],
    )
    stress_targets.append(":mixed_all")
    stress_targets.append(":shared_generated_tree")

    native.filegroup(
        name = name,
        srcs = stress_targets,
    )
