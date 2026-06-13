# Architecture

`actiond` is a local Remote Execution API worker and cache for Bazel. Its main
mode is `darwin-actiond serve-vm`, `windows-actiond serve-vm`, or
`linux-actiond serve-vm`: the host process owns the public gRPC listener,
starts a small Linux VM, and forwards REAPI traffic into a Linux guest over
virtio-vsock or Hyper-V sockets.

The design centers on three ideas:

- run Linux actions from macOS behind a VM boundary
- make sandbox setup independent of input-tree size
- keep CAS, ActionCache, and output storage local to the machine

## Topology

```text
Bazel
  |
  | gRPC / REAPI
  v
darwin-actiond / windows-actiond / linux-actiond
  |
  | TCP-to-virtio-vsock / TCP-to-AF_HYPERV bridge
  v
linux-actiond-guest
  |
  | REAPI services, executor, CAS, ActionCache
  v
guest ext4 disk mounted at /cas
```

On Windows, `windows-actiond` uses Host Compute System `LinuxKernelDirect`,
Hyper-V synthetic SCSI, and `AF_HYPERV`. Guest AF_VSOCK port 5001 maps to the
standard Hyper-V socket service GUID template. The Windows guest matches the
ARM64 or x86_64 host architecture; the macOS guest is ARM64. On Linux,
`linux-actiond` uses QEMU `virt` on ARM64 and QEMU `microvm` on x86_64. Both
QEMU machines use virtio-mmio block devices and `vhost-vsock-device`.

In VM mode, the host does not keep a second CAS mirror. Uploads, downloads,
ActionCache requests, and Execute requests are forwarded to the guest. The
guest stores state on its ext4 CAS disk and runs actions against that same
native Linux filesystem.

## Components

`darwin-actiond` is the released macOS binary. Zig `@embedFile` includes the
Linux kernel, initramfs, and ARM64 runtime SquashFS. At startup it materializes
those bytes under `--root`, inflates the kernel and initramfs to raw boot files,
starts the VM with Virtualization.framework, and bridges public gRPC traffic to
the guest.

`windows-actiond` is released for ARM64 and x86_64. Zig `@embedFile` includes
the matching Linux kernel, initramfs, and runtime SquashFS. At startup it
materializes those bytes under `--root`, wraps the runtime and CAS as fixed VHD
files, and starts the VM with Host Compute System.

`linux-actiond` is released for ARM64 and x86_64. Zig `@embedFile` includes the
matching Linux kernel, initramfs, runtime SquashFS, and QEMU executable selected
by the `rules_qemu` target toolchain. The x86_64 release also includes
`qboot.rom`; QEMU `virt` direct kernel boot on ARM64 does not require firmware.
`linux-actiond` creates sealed memfds for QEMU and every immutable embedded VM
artifact, then executes QEMU with `execveat`. Only the persistent guest-owned
CAS image is stored under `--root`. The current implementation uses TCG. KVM
and `io_uring` remain follow-up work.

`linux-actiond-guest` lives in the initramfs. It runs as guest init, mounts the
minimal guest filesystems, mounts `/cas` and `/runtimes`, then execs itself as
the guest REAPI worker.

## VM Shape

The VM is intentionally small:

- architecture-matched Linux kernel built by `linux.bzl`
- initramfs containing `linux-actiond-guest` and `mkfs.ext4`
- writable virtio or Hyper-V synthetic SCSI block device for `/cas`
- read-only virtio or Hyper-V synthetic SCSI block device for `/runtimes`
- virtio-vsock or `AF_HYPERV` for gRPC
- serial host logs on macOS and Linux
- no guest network device, SSH, systemd, package manager, graphics, or login

The VM is long-lived. Each action gets its own Linux process sandbox inside the
guest instead of booting a new VM.

When `serve-vm` creates a new CAS image, guest init formats it as ext4 before
mounting it at `/cas`. Existing CAS images are mounted without formatting, so
the local cache survives worker restarts.

## REAPI Services

The public server implements the Bazel-facing subset of REAPI:

- Execution
- ContentAddressableStorage
- ByteStream
- ActionCache
- Capabilities

The server uses SHA-256 digests. Remote cache compression is not supported yet,
so Bazel clients should use `--noremote_cache_compression`.

The HTTP/2 server handles independent streams concurrently. ByteStream reads can
write gRPC framing bytes and then send file contents from the CAS blob fd,
avoiding an extra full-blob userspace buffer for large reads.

## CAS and ActionCache

The CAS stores blobs, including REAPI tree protos, under sharded SHA-256 paths.
The same `/cas` filesystem also holds ActionCache entries and the
`actiondfs-stage` tree used for action-created files.

`linux-actiond-guest` maintains an in-memory presence index while running. It
avoids repeated filesystem probes for blobs already observed or produced during
the worker lifetime. It is an optimization only; `/cas` is the source of truth.

## Input Filesystem

VM execution uses `actiondfs`, a small Linux filesystem built into the VM
kernel. Bazel sends an input root digest; actiondfs receives that digest plus
the guest CAS blob root and exposes the action input tree at `/workspace`.

Important properties:

- input tree setup uses O(1) setup syscalls with respect to input-file count;
  per-file work happens later only for paths the action actually touches.
- directory and file nodes are resolved lazily from REAPI Directory protos
- file data is opened from real CAS blob files on `/cas`
- `read_iter`, `splice_read`, and `mmap` delegate to the backing CAS file
- executable bits come from REAPI file metadata, not chmodded CAS blobs
- output writes are staged outside immutable CAS blobs

This avoids symlink forests, hardlink forests, and per-file bind mounts in the
normal VM path.

By default, declared inputs are immutable. Legacy tools that really mutate their
inputs can opt into a compatibility path:

```python
execution_requirements = {"mutates_inputs": "1"}
```

That path mounts actiondfs read-only as an overlay lowerdir and mounts stock
overlayfs at `/workspace` with a per-action upper/work directory. Normal actions
should not use it.

actiondfs caches parsed non-root REAPI Directory protos by digest for the VM
lifetime. The default filesystem is built with stats compiled out; builds with
`--config=executor_timing_logs` mount the instrumented filesystem and expose
`/proc/actiondfs_stats`.

## Output Collection

Action-created files live under `/cas/actiondfs-stage`.
Output collection hashes declared outputs, writes output Directory protos, and
records digests in the `ActionResult`.

Because the stage tree and CAS live on the same ext4 filesystem, file outputs
can usually be finalized with hash plus rename into `blobs/sha256`, not copy.
The CAS store retains a copy fallback for cross-device or permission failures.

## Execution Sandbox

For each action, the executor reads `Action` and `Command` protos from CAS,
checks ActionCache when allowed, creates a per-action work root, mounts the
actiondfs input root and any selected runtime, runs the command, captures
stdout/stderr/status, stores declared outputs, and updates ActionCache when
allowed.

The child process runs in a chroot with private mount and network namespaces,
`PR_SET_NO_NEW_PRIVS`, dropped uid/gid, closed extra file descriptors, and a
cgroup when available. Each action network namespace has loopback only. In VM
mode there is no external guest network device.

## Runtime Images

Runtime libraries are packaged in SquashFS, separate from the initramfs. The
guest mounts the runtime SquashFS read-only at `/runtimes`.

Current runtime names:

- `glibc2.31`
- `glibc2.35`
- `glibc2.39`

Every action bind-mounts `/runtimes/common/root/etc` at `/etc`. Actions select
additional runtime libraries with the REAPI platform property `libc`. In Bazel
this can be set with:

```python
execution_requirements = {"libc": "glibc2.35"}
```

When selected, actiond bind-mounts the matching runtime paths into the action
chroot. Runtime-backed actions run with their execroot at `/workspace` so
runtime root paths such as `/etc` do not hide user input paths.

## Performance Model

The important performance choices are:

- one local worker/cache can serve multiple Bazel servers
- VM CAS and ActionCache live on native guest ext4, not a host mirror
- actiondfs makes sandbox setup syscall count independent of input-file count
- CAS blob reads use the guest page cache and backing-file kernel helpers
- staged outputs live on the same filesystem as CAS final blobs
- runtime payloads stay compressed in SquashFS
- timing logs and actiondfs counters are compiled out by default

For realistic VM performance comparisons, use the LLVM smoke scripts in `e2e/`.
The small `test/` workspace is useful for correctness and targeted stress, but
it is not the primary actiondfs performance benchmark.

## Caveats

- The REAPI surface is intentionally focused on the methods Bazel uses here.
- Remote cache compression is not supported yet.
- Cgroup limits are best-effort.
- VM mode is ARM64 Linux on Apple Silicon and architecture-matched Linux on Windows.
- Runtime selection is limited to the packaged glibc versions.
