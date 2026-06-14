load("@rules_zig//zig:defs.bzl", "zig_library")
load("//tools:zstd.bzl", "zstd_compress", "zstd_tool_attr")

def _asset_file(target, name):
    files = target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail("%s must provide exactly one file, got %d" % (name, len(files)))
    return files[0]

def _zig_embedded_assets_source_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zig")
    embedded = []
    lines = []
    for name, target in [
        ("kernel", ctx.attr.kernel),
        ("initramfs", ctx.attr.initramfs),
        ("runtime_image", ctx.attr.runtime_image),
    ]:
        asset = _asset_file(target, name)
        compressed = ctx.actions.declare_file(ctx.label.name + "." + name + ".zst")
        zstd_compress(ctx, asset, compressed)
        embedded.append(compressed)
        lines.append('pub const %s_zstd = @embedFile("%s");' % (name, compressed.basename))
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
        "runtime_image": attr.label(mandatory = True),
        "_zstd": zstd_tool_attr(),
    },
)

def zig_embedded_assets(name, kernel, initramfs, runtime_image, visibility = None):
    source_name = name + "_source"
    assets_name = name + "_files"
    _zig_embedded_assets_source(
        name = source_name,
        initramfs = initramfs,
        kernel = kernel,
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
