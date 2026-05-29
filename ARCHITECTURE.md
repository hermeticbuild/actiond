# Architecture

`actiond` is a local Remote Execution API worker and cache for Bazel. Its main
mode is `darwin-actiond serve-vm`: a macOS process owns the public gRPC
listener, starts a small Linux VM, and forwards REAPI traffic into a Linux guest
over virtio-vsock.

The design centers on three ideas:

- run Linux actions from macOS behind a VM boundary
- make sandbox setup independent of input-tree size
- keep CAS, ActionCache, and output storage local to the machine

There is also a direct Linux mode, `linux-actiond serve`, that uses the same
executor code on a Linux host. The macOS VM path is the primary product path.

## Topology

```text
Bazel
  |
  | gRPC / REAPI
  v
darwin-actiond
  |
  | TCP-to-vsock bridge
  v
linux-actiond-guest
  |
  | REAPI services, executor, CAS, ActionCache
  v
guest ext4 disk mounted at /cas
```

In VM mode, the host does not keep a second CAS mirror. Uploads, downloads,
ActionCache requests, and Execute requests are forwarded to the guest. The
guest stores state on its ext4 CAS disk and runs actions against that same
native Linux filesystem.

## Components

`darwin-actiond` is the released macOS binary. It embeds the Linux kernel,
initramfs, and aarch64 runtime SquashFS in Mach-O `__ACTIOND` sections. At
startup it extracts those payloads under `--root`, inflates the kernel and
initramfs to raw boot files, starts the VM with Virtualization.framework, and
bridges public gRPC traffic to the guest.

`linux-actiond-guest` lives in the initramfs. It runs as guest init, mounts the
minimal guest filesystems, mounts `/cas` and `/runtimes`, then execs itself as
the guest REAPI worker.

`linux-actiond` is the direct Linux host worker. It is useful for Linux hosts
and e2e coverage, but it does not use actiondfs because it must run on ordinary
host kernels.

## VM Shape

The VM is intentionally small:

- arm64 Linux kernel built by `linux.bzl`
- initramfs containing `linux-actiond-guest` and `mkfs.ext4`
- writable virtio block device for `/cas`
- read-only virtio block device for `/runtimes`
- virtio-vsock for control and gRPC
- serial stderr for logs
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

The CAS stores blobs and tree protos under sharded SHA-256 paths. In VM mode,
the same `/cas` filesystem also holds ActionCache entries and the
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

In VM/actiondfs mode, action-created files live under `/cas/actiondfs-stage`.
Output collection hashes declared outputs, writes output Directory protos, and
records digests in the `ActionResult`.

Because the stage tree and CAS live on the same ext4 filesystem, file outputs
can usually be finalized with hash plus rename into `blobs/sha256`, not copy. If
a direct Linux path or unusual filesystem makes rename impossible, the CAS store
has a copy fallback.

## Execution Sandbox

For each action, the executor reads `Action` and `Command` protos from CAS,
checks ActionCache when allowed, creates a per-action work root, prepares
actiondfs or Linux-direct inputs, mounts any selected runtime, runs the command,
captures stdout/stderr/status, stores declared outputs, and updates ActionCache
when allowed.

The child process runs in a chroot with private mount and network namespaces,
`PR_SET_NO_NEW_PRIVS`, dropped uid/gid, closed extra file descriptors, and a
cgroup when available. Each action network namespace has loopback only. In VM
mode there is no external guest network device.

## Runtime Images

Runtime libraries are packaged in SquashFS, separate from the initramfs. The
same format is used by VM execution and direct Linux execution.

Current runtime names:

- `glibc2.31`
- `glibc2.35`
- `glibc2.39`

Actions select a runtime with the REAPI platform property `libc`. In Bazel this
can be set with:

```python
execution_requirements = {"libc": "glibc2.35"}
```

When selected, actiond bind-mounts the matching runtime paths into the action
chroot. Runtime-backed actions run with their execroot at `/workspace` so
runtime root paths such as `/etc` do not hide user input paths.

## Direct Linux Mode

`linux-actiond serve` keeps CAS, ActionCache, and work directories under
`--root` on the host filesystem. Input materialization differs from VM mode:
file inputs become read-only bind mounts from CAS, tree directories can be
bind-mounted at directory granularity, and writable output directories live in
the action work root.

Direct Linux mode is not a VM boundary. It relies on Linux kernel sandboxing
primitives and should be treated as a constrained local executor.

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
- VM mode is arm64 Linux on Apple Silicon.
- Runtime selection is limited to the packaged glibc versions.
