# actiond

`actiond` is a local Remote Execution API worker/cache for running Bazel
actions in a Linux sandbox.

It has two execution modes:

- `linux-actiond`: runs actions directly on a Linux host using chroot, private
  mount/network namespaces, loopback-only TCP, read-only bind mounts, and
  best-effort cgroups.
- `darwin-actiond serve-vm`: runs on macOS and proxies execution into a tiny
  Linux VM built with Apple's Virtualization.framework.

The macOS VM path is the main reason this project exists: it lets a Mac act
like a local Linux remote-execution worker without giving actions normal macOS
process access.

For deeper implementation details, see [ARCHITECTURE.md](ARCHITECTURE.md).

## What It Builds

The repo is fully Bazelized:

- Zig 0.16.0 binaries for macOS, Linux hosts, and the Linux VM guest.
- A minimal arm64 Linux kernel from `http_archive`.
- A compressed initramfs containing `linux-actiond-guest`.
- Zstd-compressed SquashFS runtime images containing selected glibc versions.
- Standalone binaries that embed their runtime artifacts.

Important targets:

```bash
bazel build //cmd/darwin_actiond:darwin-actiond-standalone
bazel build //cmd/linux_actiond:linux-actiond-standalone-aarch64
bazel build //cmd/linux_actiond:linux-actiond-standalone-x86_64
bazel build //vm:linux_kernel_zst //vm:initramfs //runtimes:runtimes_squashfs
```

The VM kernel is built by `linux.bzl` from the Linux archive declared in
`MODULE.bazel`. The repository currently uses a `local_path_override` for
`linux.bzl` until the needed ruleset changes are published.

```bash
bazel build //vm:linux_kernel_zst
```

For optimized artifacts:

```bash
bazel build -c opt \
  //cmd/darwin_actiond:darwin-actiond-standalone_pkg \
  //cmd/linux_actiond:linux-actiond-standalone-aarch64_pkg \
  //cmd/linux_actiond:linux-actiond-standalone-x86_64_pkg
```

## Running

### macOS VM Worker

Build and run the standalone Darwin worker:

```bash
bazel build //cmd/darwin_actiond:darwin-actiond-standalone
bazel-bin/cmd/darwin_actiond/darwin-actiond-standalone serve-vm \
  --listen=127.0.0.1:8980 \
  --root=/tmp/actiond-vm
```

VM mode stores CAS and ActionCache state inside the guest on an ext4 disk image
attached as virtio-blk. By default the image path is
`/tmp/actiond-vm/cas.ext4`; pass `--cas-image=/path/cas.ext4` to reuse a
specific preformatted image.

The standalone binary embeds:

- compressed Linux kernel `Image.zst`
- compressed initramfs
- runtime SquashFS

At startup, `darwin-actiond` extracts those payloads, inflates the boot files
that Virtualization.framework needs as raw files, starts the VM, and proxies
REAPI calls into the guest over virtio-vsock.

### Linux Host Worker

On Linux:

```bash
bazel build //cmd/linux_actiond:linux-actiond-standalone
bazel-bin/cmd/linux_actiond/linux-actiond-standalone serve \
  --listen=127.0.0.1:8980 \
  --root=/tmp/actiond
```

The Linux standalone binary embeds the runtime SquashFS in the ELF
`.actiond.runtimes` section and extracts it under the worker root at startup
when `--runtime-image` and `--runtime-root` are omitted.

Linux execution requires the privileges needed for chroot, bind mounts, mount
namespaces, and cgroups. The Docker e2e harness runs privileged for this reason.

## Testing

Normal checks:

```bash
bazel build //...
bazel test //...
```

Linux e2e from macOS using Docker:

```bash
tools/docker/run_linux_e2e.sh
```

VM e2e on macOS:

```bash
tools/e2e.sh vm
```

Heavier LLVM smoke against an already-running VM worker:

```bash
e2e/llvm_tblgen_smoke.sh
```

That smoke uses `--platforms=//platforms:linux_arm64_musl` and
`--host_platform=//platforms:linux_arm64_musl` in `/Users/dzbarsky/bootstrapped2`
so the build avoids glibc runtime actions and generated exec tools do not depend
on glibc inside actiond chroots.

Standalone artifact e2e:

```bash
ACTIOND_E2E_STANDALONE=1 tools/docker/run_linux_e2e.sh
ACTIOND_E2E_STANDALONE=1 tools/e2e.sh vm
```

The `test/` directory is a separate Bazel workspace used as a stress harness.
It generates many inputs, source-directory style inputs, tree artifacts, output
files, and output directories.

## Current Runtime Set

The runtime SquashFS currently packages these glibc runtime names:

- `glibc2.31`
- `glibc2.35`
- `glibc2.39`

Bazel actions can request one with an execution/platform property:

```python
execution_requirements = {"libc": "glibc2.35"}
```

Unsupported libc names fail instead of silently falling back.

## Status

This is active systems work, not a polished product. The core path works:

- REAPI CAS/ByteStream/ActionCache/Execution surface
- Linux chroot execution
- macOS VM execution
- guest-native CAS in VM mode
- compressed VM/runtime packaging

The design prioritizes correctness, hermeticity, and measurable copies before
polishing the operator experience.
