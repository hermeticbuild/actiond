"""Hermetic e2fsprogs source generation actions."""

def _e2fsprogs_generate_impl(ctx):
    args = ctx.actions.args()
    executable = ctx.executable._capture
    if ctx.attr.mode == "crc32c-table":
        args.add_all(["-", ctx.outputs.out, ctx.executable.crc32c_generator])
    elif ctx.attr.mode == "error-table":
        executable = ctx.executable._gawk
        args.add_all(["-f", ctx.file.awk])
        args.add("outfile=" + ctx.outputs.out.path)
        args.add("outfn=" + ctx.attr.output_function)
        args.add(ctx.file.input)
    elif ctx.attr.mode == "default-profile":
        args.add_all([ctx.file.input, ctx.outputs.out, ctx.executable._gawk, "-f", ctx.file.awk])
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
        executable = executable,
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
        "_capture": attr.label(default = Label("//tools:capture"), cfg = "exec", executable = True),
    },
)
