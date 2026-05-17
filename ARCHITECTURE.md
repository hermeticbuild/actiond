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
- Handles public REAPI CAS, ByteStream, ActionCache, Capabilities, and GetTree
  calls on the host.
- Proxies only `Execution/Execute` into the VM.

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

The Darwin standalone binary embeds compressed payloads in Mach-O sections:

- `__ACTIOND,__kernel`: `Image.zst`
- `__ACTIOND,__initramfs`: `initramfs.cpio.zst`
- `__ACTIOND,__runtimes`: `runtimes-aarch64.sqfs`

At runtime, boot artifacts are extracted under the worker root. Zstd payloads
are inflated to content-addressed files in `root/boot/` before
Virtualization.framework is called. The runtime SquashFS remains compressed and
is staged under the worker root, shared read-only with VirtioFS, and loop-mounted
inside the guest.

## VM Shape

The VM is intentionally small:

- arm64 Linux kernel
- initramfs with only `linux-actiond-guest`
- no network devices
- virtio-vsock control channel
- virtiofs host CAS share
- read-only virtiofs runtime image share
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

The macOS VM path is deliberately asymmetric:

```text
Bazel
  |
  | gRPC / REAPI
  v
darwin-actiond
  |-- CAS / ByteStream / AC / Capabilities / GetTree: handled on host
  |
  `-- Execute: proxied over vsock
        |
        v
     linux-actiond-guest
```

Only `Execute` needs the Linux VM. Keeping CAS and ActionCache on the host
avoids needless host-to-guest copies for uploads, downloads, cache probes, and
action cache operations.

`Execute` responses are still inspected by the host after the guest returns so
that output blobs can be imported from the guest CAS overlay back into the host
CAS before the response is sent to Bazel.

## CAS Layout and Data Flow

The host CAS lives under the actiond root and uses content-addressed paths for
blobs and materialized tree directories.

In VM mode:

- the host CAS is exported read-only via virtiofs
- the guest mounts it at `/host-cas`
- the guest exposes `/cas` as an overlay:
  - lowerdir: `/host-cas`
  - upperdir: tmpfs under `/work`

This gives the guest read access to host inputs and a writable CAS view for
newly produced outputs, without letting the guest mutate the host CAS directly.

### Uploads

Client uploads go straight to the host:

```text
Bazel ByteStream/Write -> darwin-actiond -> host CAS
```

They do not pass through the VM.

### Inputs

In VM mode, action input files are exposed through `actiondfs`, a small built-in
read-only Linux filesystem in the repo under `kernel/actiondfs`. For each
action, the guest passes the REAPI input-root digest to actiondfs. The child
mount namespace mounts:

- `actiondfs` as the lower filesystem, resolving REAPI directory and file nodes
  lazily from the read-only host CAS mounted at `/host-cas`
- stock overlayfs at `/workspace`, using per-action upper/work directories

Executable bits are recorded in REAPI file metadata and applied by `actiondfs`
inode metadata. CAS blobs remain immutable data files and are not chmodded.

The Linux host path always keeps the non-actiondfs materialization strategy,
which lets Docker e2e run on ordinary host kernels:

- file inputs become read-only bind mounts from CAS into the chroot
- tree artifacts can be materialized as CAS tree directories and bind-mounted as
  whole directories
- output parent directories are created in the writable execroot

Hardlinks are not used as a fallback. In the VM, host CAS is virtiofs and the
execroot is a different filesystem view, so cross-filesystem hardlink attempts
would be the wrong primitive.

### Outputs

The guest writes action outputs into its writable action root, then stores
declared output files and directory trees into the guest `/cas` overlay.

After `Execute` returns:

1. the host parses the `ExecuteResponse`
2. the host walks output file, stdout, stderr, and output tree digests
3. missing output blobs are read from the guest over internal ByteStream
4. bytes stream directly into a host CAS blob writer
5. the host ActionCache is updated unless the action requested no caching

This means inputs are not copied into the VM, and only produced outputs cross
from guest to host.

## Execution Lifecycle

For each action:

1. Read the `Action` and `Command` protobufs from CAS.
2. Read the input-root digest. The fallback file-input path walks the tree; the
   actiondfs path lets the kernel filesystem resolve it lazily.
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

- read-only virtiofs CAS directory
- read-only virtiofs directory containing `runtimes.sqfs`
- virtio-vsock control channel
- serial stderr for logs

There is no guest network device, and each action still gets its own Linux
network namespace inside the VM with only loopback enabled. Root inside the
guest is not host root. The guest loop-mounts the shared SquashFS image at
`/runtimes`, so runtime payloads stay compressed and separate from the
initramfs.

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
- `http_archive` pulls Linux kernel sources.
- `repository_ctx.download_and_extract(..., type = ".deb")` extracts glibc
  runtime packages.
- a Docker-backed Kbuild genrule builds the arm64 kernel on macOS.

On macOS, kernel builds use Docker because the kernel build is Linux-oriented.
The script searches for a working Docker context and can be pointed at one:

```bash
ACTIOND_KERNEL_DOCKER_CONTEXT=colima bazel build //vm:linux_kernel_zst
```

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
ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm
e2e/llvm_tblgen_smoke.sh
ACTIOND_E2E_STANDALONE=1 tools/docker/run_linux_e2e.sh
ACTIOND_KERNEL_DOCKER_CONTEXT=colima ACTIOND_E2E_STANDALONE=1 tools/e2e.sh vm
```

The LLVM smoke uses the bootstrapped workspace's
`//platforms:linux_arm64_musl` target and host platform. That keeps generated
execution tools musl-linked, avoids glibc runtime actions, and avoids making
actiond guess whether an arbitrary action needs a glibc runtime mounted into the
chroot.

The VM e2e is the test that proves the Virtualization.framework path can boot,
connect over vsock, execute actions, and import outputs back to host CAS.
It is also the actiondfs coverage path, because the built-in filesystem is only
present in the Bazel-built VM kernel.

## Performance Notes

The main copy-minimizing choices are:

- host handles public CAS and ActionCache methods
- VM action inputs are served by an actiondfs input-root lowerdir plus stock
  overlayfs upperdir instead of per-file bind mounts or hardlink forests
- Linux-host action inputs are bind-mounted instead of copied
- tree directories are bind-mounted at directory granularity when available
- guest output import streams bytes into host CAS writers
- runtimes are mounted from SquashFS instead of unpacked into the initramfs
- kernel and initramfs are compressed for distribution, then inflated once per
  worker root as needed

The remaining unavoidable VM-mode data movement is output import from guest CAS
overlay to host CAS. That is the price of keeping the host CAS read-only inside
the VM.

## Current Caveats

- The REAPI surface is intentionally focused on the methods Bazel needs here.
- Cgroup enforcement is best-effort.
- The VM path is arm64 Linux on Apple Silicon; this project does not try to run
  an x86 kernel on Apple Silicon.
- The kernel is booted as a raw arm64 `Image`; the packaged `Image.zst` is
  decompressed by `darwin-actiond` before VM startup.
- Runtime selection is limited to the glibc versions currently packaged.
