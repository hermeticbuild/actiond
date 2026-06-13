load("@rules_zig//zig:defs.bzl", "zig_library")


def _zig_embedded_firecracker_source_impl(ctx):
    executable = ctx.file.executable
    staged = ctx.actions.declare_file(ctx.label.name + ".executable")
    ctx.actions.symlink(output = staged, target_file = executable)
    source = ctx.actions.declare_file(ctx.label.name + ".zig")
    ctx.actions.write(
        output = source,
        content = '\n'.join([
            'pub const executable = @embedFile("{}");'.format(staged.basename),
            '',
        ]),
    )
    return [
        DefaultInfo(files = depset([source])),
        OutputGroupInfo(embedded = depset([staged])),
    ]


_zig_embedded_firecracker_source = rule(
    implementation = _zig_embedded_firecracker_source_impl,
    attrs = {
        "executable": attr.label(allow_single_file = True, mandatory = True),
    },
)


def zig_embedded_firecracker(name, executable, visibility = None):
    source_name = name + "_source"
    executable_name = name + "_file"
    _zig_embedded_firecracker_source(
        name = source_name,
        executable = executable,
    )
    native.filegroup(
        name = executable_name,
        srcs = [":" + source_name],
        output_group = "embedded",
    )
    zig_library(
        name = name,
        extra_srcs = [":" + executable_name],
        main = ":" + source_name,
        import_name = "actiond_embedded_firecracker",
        visibility = visibility,
    )
