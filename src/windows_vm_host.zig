const builtin = @import("builtin");
const std = @import("std");
const fixed_vhd = @import("fixed_vhd.zig");
const grpc_hvsock_bridge = @import("grpc_hvsock_bridge.zig");
const vm_host = @import("vm_host.zig");
const vsock = @import("vsock.zig");
const windows_hcs = @import("windows_hcs.zig");

const scsi_controller_id = "df6d0690-79e5-55b6-a5ec-c1e2f77f580a";

pub fn serve(io: std.Io, allocator: std.mem.Allocator, options: vm_host.ServeVmOptions) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
    if (options.actiondfs_stats_path != null) return error.UnsupportedActiondfsStats;

    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root_dir.close(io);

    const kernel_path = options.kernel orelse return error.MissingVmKernel;
    const boot_kernel_path = try vm_host.absolutePath(io, allocator, kernel_path);
    defer allocator.free(boot_kernel_path);

    const initramfs_path = options.initramfs orelse return error.MissingVmInitramfs;
    const raw_initramfs_path = try vm_host.prepareBootInitramfs(io, allocator, root_dir, initramfs_path);
    defer if (raw_initramfs_path) |path| allocator.free(path);
    const boot_initramfs_path = raw_initramfs_path orelse try vm_host.absolutePath(io, allocator, initramfs_path);
    defer if (raw_initramfs_path == null) allocator.free(boot_initramfs_path);

    const runtime_image_path = options.runtime_image orelse return error.MissingVmRuntimeImage;
    const absolute_runtime_image_path = try vm_host.absolutePath(io, allocator, runtime_image_path);
    defer allocator.free(absolute_runtime_image_path);
    const runtime_vhd_path = try vm_host.absoluteSubPath(io, allocator, root_dir, "runtimes.vhd");
    defer allocator.free(runtime_vhd_path);
    try fixed_vhd.wrapFile(io, absolute_runtime_image_path, runtime_vhd_path);

    const cas_vhd_path = if (options.cas_image) |path|
        try vm_host.absolutePath(io, allocator, path)
    else
        try vm_host.absoluteSubPath(io, allocator, root_dir, "cas.vhd");
    defer allocator.free(cas_vhd_path);
    const format_cas_image = try ensureCasVhd(io, cas_vhd_path, options.cas_image_size_mib);

    const vm_id_utf8 = windows_hcs.formatGuid(try windows_hcs.randomGuid(io));
    const configuration = try buildConfiguration(
        allocator,
        boot_kernel_path,
        boot_initramfs_path,
        cas_vhd_path,
        runtime_vhd_path,
        format_cas_image,
        options.memory_mib,
        options.cpus,
    );
    defer allocator.free(configuration);

    std.log.info("starting HCS VM id={s} kernel={s} initramfs={s} cas={s} runtimes={s}", .{
        &vm_id_utf8,
        boot_kernel_path,
        boot_initramfs_path,
        cas_vhd_path,
        runtime_vhd_path,
    });

    const files = [_][]const u8{
        boot_kernel_path,
        boot_initramfs_path,
        cas_vhd_path,
        runtime_vhd_path,
    };
    var machine = try windows_hcs.Machine.start(
        allocator,
        configuration,
        vm_id_utf8,
        &files,
        options.start_timeout_ms,
        options.connect_timeout_ms,
    );
    defer machine.deinit();

    return grpc_hvsock_bridge.serve(io, options.listen, &machine);
}

fn buildConfiguration(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initramfs_path: []const u8,
    cas_vhd_path: []const u8,
    runtime_vhd_path: []const u8,
    format_cas_image: bool,
    memory_mib: u64,
    cpus: u32,
) ![]u8 {
    const cpu_count = if (cpus == 0) 1 else cpus;
    const memory_size_mib = if (memory_mib == 0) 512 else memory_mib;
    const grpc_service_id = windows_hcs.formatGuid(windows_hcs.serviceGuid(vsock.grpc_port));
    const format_argument = if (format_cas_image) " actiond.format_cas=1" else "";

    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "SchemaVersion": {{"Major": 2, "Minor": 2}},
        \\  "Owner": "actiond",
        \\  "ShouldTerminateOnLastHandleClosed": true,
        \\  "VirtualMachine": {{
        \\    "StopOnReset": true,
        \\    "Chipset": {{"LinuxKernelDirect": {{
        \\      "KernelFilePath": {f},
        \\      "InitRdPath": {f},
        \\      "KernelCmdLine": "init=/init panic=-1 initcall_blacklist=virtio_vsock_init pci=off nr_cpus={d} brd.rd_nr=0 pmtmr=0 actiond.cas_device=/dev/sda{s}"
        \\    }}}},
        \\    "ComputeTopology": {{
        \\      "Memory": {{"SizeInMB": {d}, "AllowOvercommit": true}},
        \\      "Processor": {{"Count": {d}}}
        \\    }},
        \\    "Devices": {{
        \\      "Scsi": {{"{s}": {{"Attachments": {{
        \\        "0": {{"Type": "VirtualDisk", "Path": {f}, "ReadOnly": false}},
        \\        "1": {{"Type": "VirtualDisk", "Path": {f}, "ReadOnly": true}}
        \\      }}}}}},
        \\      "HvSocket": {{"HvSocketConfig": {{
        \\        "DefaultBindSecurityDescriptor": "D:P(A;;FA;;;WD)",
        \\        "DefaultConnectSecurityDescriptor": "D:P(A;;FA;;;SY)(A;;FA;;;BA)",
        \\        "ServiceTable": {{
        \\          "{s}": {{"AllowWildcardBinds": true}}
        \\        }}
        \\      }}}}
        \\    }}
        \\  }}
        \\}}
    , .{
        std.json.fmt(kernel_path, .{}),
        std.json.fmt(initramfs_path, .{}),
        cpu_count,
        format_argument,
        memory_size_mib,
        cpu_count,
        scsi_controller_id,
        std.json.fmt(cas_vhd_path, .{}),
        std.json.fmt(runtime_vhd_path, .{}),
        &grpc_service_id,
    });
}

fn ensureCasVhd(io: std.Io, path: []const u8, size_mib: u64) !bool {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.kind != .file or stat.size < fixed_vhd.footer_size) return error.InvalidCasImage;
        return false;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const size_bytes = try std.math.mul(u64, size_mib, 1024 * 1024);
    try fixed_vhd.createEmpty(io, path, size_bytes);
    return true;
}

test "HCS configuration maps ports and SCSI disks" {
    const configuration = try buildConfiguration(
        std.testing.allocator,
        "C:\\actiond\\Image",
        "C:\\actiond\\initramfs.cpio",
        "C:\\actiond\\cas.vhd",
        "C:\\actiond\\runtimes.vhd",
        true,
        1024,
        4,
    );
    defer std.testing.allocator.free(configuration);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, configuration, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, configuration, "LinuxKernelDirect") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration, "00001389-facb-11e6-bd58-64006a7986d3") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration, "actiond.cas_device=/dev/sda") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration, "actiond.format_cas=1") != null);
}
