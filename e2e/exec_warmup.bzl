def _exec_warmup_impl(ctx):
    files = []
    for dep in ctx.attr.deps:
        files.append(dep[DefaultInfo].files)
    return [DefaultInfo(files = depset(transitive = files))]

exec_warmup = rule(
    implementation = _exec_warmup_impl,
    attrs = {
        "deps": attr.label_list(cfg = "exec"),
    },
)
