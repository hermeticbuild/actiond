load("@rules_zig//zig:defs.bzl", "zig_library")

def _asset_file(target, name, suffix = ""):
    files = target[DefaultInfo].files.to_list()
    if len(files) == 1:
        return files[0]
    matches = [file for file in files if suffix and file.basename.endswith(suffix)]
    if len(matches) != 1:
        fail("%s must provide exactly one file matching suffix %r, got %d of %d" % (name, suffix, len(matches), len(files)))
    return matches[0]

def _zig_embedded_assets_source_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zig")
    embedded = []
    lines = []
    for name, target in [
        ("kernel", ctx.attr.kernel),
        ("initramfs", ctx.attr.initramfs),
        ("runtime_image", ctx.attr.runtime_image),
    ]:
        asset = _asset_file(target, name, ctx.attr.kernel_suffix if name == "kernel" else "")
        staged = ctx.actions.declare_file(ctx.label.name + "." + name)
        ctx.actions.symlink(output = staged, target_file = asset)
        embedded.append(staged)
        lines.append('pub const %s = @embedFile("%s");' % (name, staged.basename))
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(embedded = depset(embedded)),
    ]

_zig_embedded_assets_source = rule(
    implementation = _zig_embedded_assets_source_impl,
    attrs = {
        "initramfs": attr.label(mandatory = True),
        "kernel": attr.label(mandatory = True),
        "kernel_suffix": attr.string(),
        "runtime_image": attr.label(mandatory = True),
    },
)

def zig_embedded_assets(name, kernel, initramfs, runtime_image, kernel_suffix = "", visibility = None):
    source_name = name + "_source"
    assets_name = name + "_files"
    _zig_embedded_assets_source(
        name = source_name,
        initramfs = initramfs,
        kernel = kernel,
        kernel_suffix = kernel_suffix,
        runtime_image = runtime_image,
    )
    native.filegroup(
        name = assets_name,
        srcs = [":" + source_name],
        output_group = "embedded",
    )
    zig_library(
        name = name,
        extra_srcs = [":" + assets_name],
        import_name = "actiond_embedded_assets",
        main = ":" + source_name,
        visibility = visibility,
    )
