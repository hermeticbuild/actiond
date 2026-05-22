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
bazel build //cmd/linux_actiond:linux-actiond-standalone \
  --platforms=//platforms:linux_aarch64
bazel build //cmd/linux_actiond:linux-actiond-standalone \
  --platforms=//platforms:linux_x86_64
bazel build //vm:linux_kernel_zst //vm:initramfs //runtimes:runtimes_squashfs
```

The Linux standalone target follows Bazel's target platform. Its embedded
runtime image comes from `//runtimes:runtimes_squashfs`, which selects the
matching runtime SquashFS for the target CPU.

The VM kernel is built by `linux.bzl` from the Linux archive declared in
`MODULE.bazel`. The repository currently uses a `local_path_override` for
`linux.bzl` until the needed ruleset changes are published.

```bash
bazel build //vm:linux_kernel_zst
```

For optimized artifacts:

```bash
bazel build -c opt //cmd/darwin_actiond:darwin-actiond-standalone_pkg
bazel build -c opt //cmd/linux_actiond:linux-actiond-standalone_pkg \
  --platforms=//platforms:linux_aarch64
bazel build -c opt //cmd/linux_actiond:linux-actiond-standalone_pkg \
  --platforms=//platforms:linux_x86_64
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

Full LLVM smoke comparison, including VM startup and a mac-host baseline:

```bash
e2e/run_llvm_vm_smoke.sh
```

The VM smoke uses `--platforms=@llvm//platforms:linux_arm64_musl` and
`--host_platform=@llvm//platforms:linux_arm64_musl` so generated exec tools run
inside the Linux VM and do not depend on glibc inside actiond chroots.

Current `@llvm-project//llvm:llvm-tblgen` timings from May 20, 2026, using
`-c opt --strip=always --stripopt=--strip-all`:

| Path | Jobs | Bazel elapsed |
| --- | ---: | ---: |
| actiond VM | 8 | 69.182s |
| mac-host local | 8 | 93.153s |
| actiond VM | 16 | 97.783s |
| mac-host local | 16 | 133.437s |

The wrapper defaults to `--jobs=8`; override with `ACTIOND_LLVM_SMOKE_JOBS`.

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

## Input Mutation Semantics

VM execution uses actiondfs for lazy CAS-backed inputs. By default, actiondfs
treats declared inputs as immutable: reading input files is allowed, but opening
an input for write or truncation fails. Actions may create new output files under
input directories, and those writes are staged outside the CAS until output
collection.

Actions that intentionally rewrite, delete, or replace input files must opt into
the overlayfs compatibility path:

```python
execution_requirements = {"mutates_inputs": "1"}
```

Use this only for tools that really mutate their input tree or declare outputs
that overlap input files. Normal actions should use the default strict actiondfs
path.

## Status

This is active systems work, not a polished product. The core path works:

- REAPI CAS/ByteStream/ActionCache/Execution surface
- Linux chroot execution
- macOS VM execution
- guest-native CAS in VM mode
- compressed VM/runtime packaging

The design prioritizes correctness, hermeticity, and measurable copies before
polishing the operator experience.
