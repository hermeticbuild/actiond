load("@rules_zig//zig:defs.bzl", "zig_library")

_QEMU_TOOLCHAIN_TYPE = "@rules_qemu//qemu:target_toolchain_type"

def _zig_embedded_qemu_source_impl(ctx):
    qemu = ctx.toolchains[_QEMU_TOOLCHAIN_TYPE]
    qemu_system = ctx.actions.declare_file(ctx.label.name + ".qemu-system")
    bios_256k = ctx.actions.declare_file(ctx.label.name + ".bios-256k.bin")
    linuxboot_dma = ctx.actions.declare_file(ctx.label.name + ".linuxboot_dma.bin")
    source = ctx.actions.declare_file(ctx.label.name + ".zig")
    ctx.actions.symlink(output = qemu_system, target_file = qemu.qemu_system)
    ctx.actions.run_shell(
        arguments = [
            qemu.system_data_anchor.path,
            bios_256k.path,
            linuxboot_dma.path,
        ],
        command = """
set -eu
cp "$1/bios-256k.bin" "$2"
cp "$1/linuxboot_dma.bin" "$3"
""",
        inputs = qemu.system_data_files,
        outputs = [bios_256k, linuxboot_dma],
    )
    ctx.actions.write(
        source,
        """\
pub const qemu_system = @embedFile("{qemu_system}");
pub const bios_256k = @embedFile("{bios_256k}");
pub const linuxboot_dma = @embedFile("{linuxboot_dma}");
""".format(
            bios_256k = bios_256k.basename,
            linuxboot_dma = linuxboot_dma.basename,
            qemu_system = qemu_system.basename,
        ),
    )
    return [
        DefaultInfo(files = depset([source])),
        OutputGroupInfo(embedded = depset([qemu_system, bios_256k, linuxboot_dma])),
    ]

_zig_embedded_qemu_source = rule(
    implementation = _zig_embedded_qemu_source_impl,
    toolchains = [_QEMU_TOOLCHAIN_TYPE],
)

def zig_embedded_qemu(name, target_compatible_with = [], visibility = None):
    source_name = name + "_source"
    qemu_name = name + "_file"
    _zig_embedded_qemu_source(
        name = source_name,
        target_compatible_with = target_compatible_with,
    )
    native.filegroup(
        name = qemu_name,
        srcs = [":" + source_name],
        output_group = "embedded",
        target_compatible_with = target_compatible_with,
    )
    zig_library(
        name = name,
        extra_srcs = [":" + qemu_name],
        import_name = "actiond_embedded_qemu",
        main = ":" + source_name,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )
