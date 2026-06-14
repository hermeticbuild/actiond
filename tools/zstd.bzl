def zstd_compress(ctx, source, output):
    ctx.actions.run(
        arguments = [
            "-q",
            "--ultra",
            "-22",
            "-f",
            source.path,
            "-o",
            output.path,
        ],
        executable = ctx.executable._zstd,
        inputs = [source],
        mnemonic = "ZstdCompress",
        outputs = [output],
    )

def zstd_tool_attr():
    return attr.label(
        cfg = "exec",
        default = Label("@zstd//:zstd_cli"),
        executable = True,
    )
