def _darwin_codesign_impl(ctx):
    out = ctx.outputs.executable
    args = ctx.actions.args()
    args.add("sign")
    args.add("--entitlements-xml-file")
    args.add(ctx.file.entitlements)
    args.add("--binary-identifier")
    args.add(ctx.attr.binary_identifier)
    args.add(ctx.file.binary)
    args.add(out)

    ctx.actions.run(
        executable = ctx.executable.tool,
        inputs = [
            ctx.file.binary,
            ctx.file.entitlements,
        ],
        outputs = [out],
        arguments = [args],
        mnemonic = "Codesign",
        progress_message = "Signing %{label}",
    )

    return [DefaultInfo(
        executable = out,
        files = depset([out]),
    )]

darwin_codesign = rule(
    implementation = _darwin_codesign_impl,
    attrs = {
        "binary": attr.label(allow_single_file = True, mandatory = True),
        "binary_identifier": attr.string(mandatory = True),
        "entitlements": attr.label(allow_single_file = True, mandatory = True),
        "tool": attr.label(
            allow_files = True,
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
    },
    executable = True,
)
