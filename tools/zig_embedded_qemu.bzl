load("@rules_zig//zig:defs.bzl", "zig_library")

_QEMU_TOOLCHAIN_TYPE = "@rules_qemu//qemu:target_toolchain_type"

def _zig_embedded_qemu_source_impl(ctx):
    qemu = ctx.toolchains[_QEMU_TOOLCHAIN_TYPE]
    qemu_system = ctx.actions.declare_file(ctx.label.name + ".qemu-system")
    source = ctx.actions.declare_file(ctx.label.name + ".zig")
    ctx.actions.symlink(output = qemu_system, target_file = qemu.qemu_system)
    embedded = [qemu_system]
    lines = [
        'pub const qemu_system = @embedFile("{}");'.format(qemu_system.basename),
        'pub const qemu_system_name = "{}";'.format(qemu.qemu_system.basename),
        'pub const accel = "{}";'.format(qemu.accel),
        'pub const machine = "{}";'.format(qemu.machine),
        'pub const target_arch = "{}";'.format(qemu.target_arch),
    ]

    if qemu.system_target == "x86_64-softmmu":
        firmware = ctx.actions.declare_file(ctx.label.name + ".qboot.rom")
        ctx.actions.run_shell(
            arguments = [
                qemu.system_data_anchor.path,
                firmware.path,
            ],
            command = """
set -eu
cp "$1/qboot.rom" "$2"
""",
            inputs = qemu.system_data_files,
            outputs = [firmware],
        )
        embedded.append(firmware)
        lines.append('pub const firmware: ?[]const u8 = @embedFile("{}");'.format(firmware.basename))
    elif qemu.system_target == "aarch64-softmmu":
        lines.append("pub const firmware: ?[]const u8 = null;")
    else:
        fail("unsupported embedded QEMU system target: {}".format(qemu.system_target))

    ctx.actions.write(source, "\n".join(lines) + "\n")
    return [
        DefaultInfo(files = depset([source])),
        OutputGroupInfo(embedded = depset(embedded)),
    ]

_zig_embedded_qemu_source = rule(
    implementation = _zig_embedded_qemu_source_impl,
    toolchains = [_QEMU_TOOLCHAIN_TYPE],
)

def zig_embedded_qemu(name, target_compatible_with = [], visibility = None):
    source_name = name + "_source"
    files_name = name + "_files"
    _zig_embedded_qemu_source(
        name = source_name,
        target_compatible_with = target_compatible_with,
    )
    native.filegroup(
        name = files_name,
        srcs = [":" + source_name],
        output_group = "embedded",
        target_compatible_with = target_compatible_with,
    )
    zig_library(
        name = name,
        extra_srcs = [":" + files_name],
        import_name = "actiond_embedded_qemu",
        main = ":" + source_name,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )
