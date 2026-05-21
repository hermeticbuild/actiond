# Architecture

`actiond` is a small Remote Execution API implementation with two Linux
execution backends:

- direct Linux host execution through `linux-actiond`
- macOS-hosted Linux VM execution through `darwin-actiond serve-vm`

The shared goal is the same in both modes: accept Bazel REAPI traffic, keep CAS
and ActionCache state local, construct a Linux execroot with minimal copies, run
the action in an isolated filesystem view, then publish declared outputs back
into the CAS.

## Components

### Binaries

`darwin-actiond`

- macOS host binary.
- `serve-vm` starts and supervises a Virtualization.framework Linux VM.
- Proxies public REAPI traffic into the guest over virtio-vsock.
- VM mode has one guest-owned CAS on the VM block device.

`linux-actiond`

- Linux host worker.
- Runs actions directly using the same executor code used inside the VM.
- Can embed the runtime SquashFS as a standalone binary payload.

`linux-actiond-guest`

- Linux guest binary placed in the initramfs.
- Acts as PID 1 for the VM image.
- Mounts guest filesystems, starts the REAPI/control worker, and runs actions.

### Build Artifacts

The VM bundle is produced by Bazel:

- `//vm:linux_kernel`: raw arm64 Linux `Image`
- `//vm:linux_kernel_zst`: zstd-compressed kernel image for packaging
- `//vm:initramfs`: zstd-compressed initramfs cpio
- `//runtimes:runtimes_squashfs`: zstd-compressed SquashFS runtime image

Standalone binaries embed compressed payloads in native executable sections.

The Darwin standalone binary uses Mach-O sections:

- `__ACTIOND,__kernel`: `Image.zst`
- `__ACTIOND,__initramfs`: `initramfs.cpio.zst`
- `__ACTIOND,__runtimes`: `runtimes-aarch64.sqfs`

The Linux standalone binary uses an ELF section:

- `.actiond.runtimes`: runtime SquashFS

At runtime, boot artifacts are extracted under the worker root. Zstd payloads
are inflated to content-addressed files in `root/boot/` before
Virtualization.framework is called. The runtime SquashFS remains compressed and
is staged under the worker root. VM mode attaches it to the guest as a
read-only virtio block device; direct Linux execution mounts it locally.

## VM Shape

The VM is intentionally small:

- arm64 Linux kernel
- initramfs with only `linux-actiond-guest`
- no network devices
- virtio-vsock control channel
- writable virtio block device for the guest CAS
- read-only virtio block device for the runtime SquashFS image
- no SSH, package manager, systemd, graphics, audio, or user login

The VM is a long-lived worker. Per-action isolation happens inside Linux with a
fresh chroot, mount namespace, and network namespace rather than by cold-booting
a VM per action.

Each action network namespace brings up only `lo`. Actions can use local TCP
listeners on `127.0.0.1` or `0.0.0.0`, but no host or external network interface
is attached. The runtime image includes a canonical `/etc/hosts` so `localhost`
resolves to loopback inside runtime-backed actions.

## Why the Kernel Is Inflated Before Boot

The packaged kernel is compressed, but the VM is booted with a raw Linux
`Image`.

Virtualization.framework's `VZLinuxBootLoader` accepts a kernel URL, but does
not document a zstd/gzip decompression contract. On arm64 Linux, compressed
kernel payloads are also a bootloader responsibility; the arm64 `Image` format
is not an x86-style self-decompressing `bzImage`.

So the implemented contract is:

1. ship `Image.zst`
2. extract it from the standalone binary
3. inflate it into `root/boot/kernel-<sha256>.Image`
4. pass the raw `Image` path to `VZLinuxBootLoader`

That keeps distribution size low while keeping the VM boot ABI boring.

## REAPI Surface

The server implements the subset needed for Bazel remote execution:

- `Execution/Execute`
- `ContentAddressableStorage/FindMissingBlobs`
- `ContentAddressableStorage/BatchUpdateBlobs`
- `ContentAddressableStorage/BatchReadBlobs`
- `ContentAddressableStorage/GetTree`
- `ByteStream/Read`
- `ByteStream/Write`
- `ActionCache/GetActionResult`
- `ActionCache/UpdateActionResult`
- `Capabilities/GetCapabilities`

The HTTP/2 server dispatches independent streams concurrently. Server-streaming
responses use a body sink so large responses can be written as chunks instead
of forcing the HTTP/2 layer to build one giant response buffer.

## Darwin VM Request Routing

The macOS VM path keeps all REAPI state inside the Linux guest:

```text
Bazel
  |
  | gRPC / REAPI
  v
darwin-actiond
  |
  | framed gRPC payloads over virtio-vsock
  v
linux-actiond-guest
  |
  | CAS / ByteStream / AC / Capabilities / GetTree / Execute
  v
guest ext4 CAS on virtio-blk
```

The host process still owns the public TCP listener and VM lifecycle, but CAS,
ActionCache, and output storage are handled by `linux-actiond-guest` against the
native guest filesystem.

## CAS Layout and Data Flow

The CAS uses content-addressed paths for blobs and materialized tree
directories.

In VM mode:

- `darwin-actiond` attaches a writable raw disk image as a virtio block device
- the guest mounts that disk as ext4 at `/cas`
- `linux-actiond-guest` stores CAS blobs, materialized trees, and ActionCache
  state there
- per-action workspaces remain tmpfs under `/work`

Client uploads and downloads cross the VM boundary as REAPI/ByteStream traffic,
but action input reads and action output writes hit the guest's native Linux
filesystem once the data is in the VM-owned CAS.

### Uploads

Client uploads are forwarded to the guest:

```text
Bazel ByteStream/Write -> darwin-actiond -> vsock -> guest CAS
```

The host does not mirror uploaded blobs into a second CAS.

### Inputs

In VM mode, action input files are exposed through `actiondfs`, a small built-in
read-only Linux filesystem in the repo under `kernel/actiondfs`. For each
action, the guest passes the REAPI input-root digest to actiondfs. The child
mount namespace mounts:

- `actiondfs` as the lower filesystem, resolving REAPI directory and file nodes
  lazily from the guest CAS mounted at `/cas`
- stock overlayfs at `/workspace`, using per-action upper/work directories

`actiondfs` caches parsed non-root Directory protos by digest and materializes
per-mount child nodes only when lookup needs them. It is the only supported VM
input filesystem.

Executable bits are recorded in REAPI file metadata and applied by `actiondfs`
inode metadata. CAS blobs remain immutable data files and are not chmodded.

`actiondfs` keeps a VM-lifetime parsed Directory cache keyed only by the
Directory digest. The cache stores immutable child metadata for non-root
directories so reused source directories and tree artifacts do not re-read and
re-parse the same CAS Directory blob across action mounts. Per-action mounts
attach cached directories by pointer and keep a compact list of child nodes
materialized by lookup; they no longer allocate per-directory child pointer
arrays sized to the whole cached tree. The per-action input root Directory is
intentionally not cached because those roots are expected to be unique; VFS
nodes, inodes, and dentries remain mount-local.

For file contents, actiondfs opens the real CAS blob as a Linux backing file
with the actiondfs path as the user-visible path. `read_iter`, `splice_read`,
and `mmap` are delegated through the kernel backing-file helpers, so compiler
mmap traffic goes directly through the native CAS filesystem page cache instead
of being copied through actiondfs folios.

The kernel exposes VM-lifetime actiondfs counters at `/proc/actiondfs_stats`.
Those counters track cache hits/misses, directory parses, lookup and readdir
activity, CAS blob opens, backing reads, splice reads, mmap calls, and
stale-handle retries.

The Linux host path always keeps the non-actiondfs materialization strategy,
which lets Docker e2e run on ordinary host kernels:

- file inputs become read-only bind mounts from CAS into the chroot
- tree artifacts can be materialized as CAS tree directories and bind-mounted as
  whole directories
- output parent directories are created in the writable execroot

Hardlinks are not used as a fallback. The VM uses actiondfs plus overlayfs for
inputs, while Linux-direct uses bind mounts.

### Outputs

The guest writes action outputs into its writable action root, then stores
declared output files and directory trees directly into the guest `/cas`.
`ExecuteResponse` is returned to the host as normal gRPC payload bytes; there is
no post-Execute host import step in VM mode.

## Execution Lifecycle

For each action:

1. Read the `Action` and `Command` protobufs from CAS.
2. Read the input-root digest. The Linux-direct materialization path walks the
   tree; the VM actiondfs path lets the kernel filesystem resolve it lazily.
3. Create a per-action work root.
4. In VM/actiondfs mode, prepare actiondfs plus overlayfs lower/upper/work mount
   paths. Otherwise materialize input paths using read-only bind mounts.
5. If requested, attach libc runtime directories from SquashFS.
6. Create output parent directories.
7. Fork the action process.
8. In the child:
   - set process group
   - join cgroup if one was created
   - set `PR_SET_NO_NEW_PRIVS`
   - close extra file descriptors
   - unshare the mount and network namespaces
   - bring up loopback inside the private network namespace
   - make mounts private
   - mount `actiondfs` and overlayfs when an actiondfs lowerdir is active
   - apply read-only bind mounts
   - chroot into the work root
   - chdir to the requested working directory
   - drop to the sandbox uid/gid
   - exec the command
9. Collect stdout, stderr, exit status, and declared outputs.
10. Store output blobs and directory tree metadata in CAS.

## Sandbox Model

The isolation boundary differs by host:

### Linux Host

`linux-actiond` relies on Linux kernel primitives:

- chroot
- private mount and network namespaces with only loopback enabled
- read-only bind mounts
- dropped uid/gid
- `PR_SET_NO_NEW_PRIVS`
- best-effort cgroup v2 limits

This is not a VM boundary, but it gives actions a constrained filesystem view
and avoids direct writes to CAS inputs.

### macOS VM

`darwin-actiond serve-vm` adds a VM boundary around the same Linux executor.
macOS only exposes:

- writable virtio block device containing the guest ext4 CAS
- read-only virtio block device containing `runtimes.sqfs`
- virtio-vsock control channel
- serial stderr for logs

There is no guest network device, and each action still gets its own Linux
network namespace inside the VM with only loopback enabled. Root inside the
guest is not host root. The guest mounts the SquashFS block device at
`/runtimes`, so runtime payloads stay compressed and separate from the
initramfs without requiring VirtioFS or loop devices in the guest kernel.

## Cgroups

Cgroup setup is best-effort. If `/sys/fs/cgroup` is writable and cgroup v2
controllers are available, actiond creates an `actiond/action-<id>` cgroup and
applies limits from platform properties:

- `limits.memory.bytes`, `memory`, `memory_bytes`, `resources:memory:bytes`
- `limits.cpu.cores`, `cpu`, `cores`, `resources:cpu:cores`
- `limits.pids.max`, `pids.max`, `pids`

If cgroup setup fails, execution continues without limits rather than failing
the action.

## Runtime Images and libc Selection

Runtime libraries are packaged separately from the initramfs in SquashFS so the
same model works for both Linux-direct and VM execution.

Current runtime names:

- `glibc2.31`
- `glibc2.35`
- `glibc2.39`

Actions select a runtime through the REAPI platform property named `libc`.
Bazel maps `execution_requirements` into platform properties, so a target can
request:

```python
execution_requirements = {"libc": "glibc2.35"}
```

When a runtime is selected, actiond bind-mounts the matching runtime directories
into the chroot:

- `/lib`
- `/lib64`
- `/usr/lib`
- `/etc`

Runtime-backed actions run with their execroot at `/workspace`. That lets
actiond mount runtime-owned root paths such as `/etc` without hiding user input
paths that happen to start with `etc/`. Actions that do not request a libc
runtime still receive the runtime image's common `/etc` package for localhost
resolution.

The glibc packages are extracted from Ubuntu `libc6` `.deb`s. The repo rule
removes documentation, locales, gconv modules, lintian metadata, and package
scratch directories. The current distro-provided ELF files are already stripped;
actiond does not currently run an additional strip pass over glibc.

## Build System

Bazel owns the full build:

- `rules_zig` builds all Zig binaries.
- `@llvm` provides C/C++/Objective-C tooling and the macOS SDK framework setup.
- `linux.bzl` downloads Linux kernel sources and builds the VM kernel from a
  compact Bazel-native object graph.
- `repository_ctx.download_and_extract(..., type = ".deb")` extracts glibc
  runtime packages.

```bash
bazel build //vm:linux_kernel_zst
```

`MODULE.bazel` currently uses a `local_path_override` for `/Users/dzbarsky/linux.bzl`
until the ruleset changes needed by actiond are published.

## Testing Strategy

Unit tests cover protocol encoding/decoding, CAS behavior, HTTP/2 dispatch,
execroot construction, runtime mount mapping, initramfs creation, SquashFS
packing, and zstd packaging.

End-to-end tests use `tools/e2e.sh` and the standalone `test/` workspace. The
stress action graph covers bare files, source directories, tree artifact inputs,
output directories, and action-level probes that fail if the sandbox can open an
outbound TCP path, cannot use loopback TCP, or cannot see the runtime-provided
`/etc/hosts` localhost mapping.

Useful commands:

```bash
bazel build //...
bazel test //...
tools/docker/run_linux_e2e.sh
tools/e2e.sh vm
e2e/llvm_tblgen_smoke.sh
ACTIOND_E2E_STANDALONE=1 tools/docker/run_linux_e2e.sh
ACTIOND_E2E_STANDALONE=1 tools/e2e.sh vm
```

The LLVM smoke uses the bootstrapped workspace's
`//platforms:linux_arm64_musl` target and host platform. That keeps generated
execution tools musl-linked, avoids glibc runtime actions, and avoids making
actiond guess whether an arbitrary action needs a glibc runtime mounted into the
chroot.

The VM e2e is the test that proves the Virtualization.framework path can boot,
connect over vsock, execute actions, and serve CAS from the guest ext4 image. It
is also the actiondfs coverage path, because the built-in filesystem is only
present in the Bazel-built VM kernel.

## Performance Notes

The main copy-minimizing choices are:

- VM mode keeps CAS and ActionCache on a native guest ext4 filesystem
- VM action inputs are served by an actiondfs input-root lowerdir plus stock
  overlayfs upperdir instead of per-file bind mounts or hardlink forests
- Linux-host action inputs are bind-mounted instead of copied
- tree directories are bind-mounted at directory granularity when available
- runtimes are mounted from SquashFS instead of unpacked into the initramfs
- kernel and initramfs are compressed for distribution, then inflated once per
  worker root as needed

## Current Caveats

- The REAPI surface is intentionally focused on the methods Bazel needs here.
- Cgroup enforcement is best-effort.
- The VM path is arm64 Linux on Apple Silicon; this project does not try to run
  an x86 kernel on Apple Silicon.
- The kernel is booted as a raw arm64 `Image`; the packaged `Image.zst` is
  decompressed by `darwin-actiond` before VM startup.
- Runtime selection is limited to the glibc versions currently packaged.
