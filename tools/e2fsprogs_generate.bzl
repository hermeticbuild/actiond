"""Hermetic e2fsprogs source generation actions."""


def _e2fsprogs_generate_impl(ctx):
    args = ctx.actions.args()
    args.add(ctx.attr.mode)
    args.add(ctx.outputs.out)
    args.add(ctx.executable._gawk)
    if ctx.attr.mode == "crc32c-table":
        args.add(ctx.executable.crc32c_generator)
    elif ctx.attr.mode == "error-table":
        args.add(ctx.file.awk)
        args.add(ctx.attr.output_function)
        args.add(ctx.file.input)
    elif ctx.attr.mode == "default-profile":
        args.add(ctx.file.awk)
        args.add(ctx.file.input)
    else:
        fail("unsupported e2fsprogs generation mode: %s" % ctx.attr.mode)

    inputs = []
    if ctx.file.awk:
        inputs.append(ctx.file.awk)
    if ctx.file.input:
        inputs.append(ctx.file.input)

    tools = [ctx.attr._gawk[DefaultInfo].files_to_run]
    if ctx.attr.crc32c_generator:
        tools.append(ctx.attr.crc32c_generator[DefaultInfo].files_to_run)

    ctx.actions.run(
        arguments = [args],
        executable = ctx.executable.runner,
        inputs = inputs,
        outputs = [ctx.outputs.out],
        tools = tools,
    )


e2fsprogs_generate = rule(
    implementation = _e2fsprogs_generate_impl,
    attrs = {
        "awk": attr.label(allow_single_file = True),
        "crc32c_generator": attr.label(cfg = "exec", executable = True),
        "_gawk": attr.label(
            cfg = "exec",
            default = Label("@gawk//:gawk"),
            executable = True,
        ),
        "input": attr.label(allow_single_file = True),
        "mode": attr.string(mandatory = True),
        "out": attr.output(mandatory = True),
        "output_function": attr.string(),
        "runner": attr.label(cfg = "exec", executable = True, mandatory = True),
    },
)
