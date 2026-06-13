# actiond

`actiond` is a local Remote Execution API worker and cache for Bazel. On macOS,
Windows, and Linux it starts a small Linux VM and runs Bazel actions inside
that VM, so the host can act like a local Linux remote-execution worker.

The macOS ARM64, Windows ARM64/x86_64, and Linux ARM64/x86_64 releases include
the matching VM kernel, initramfs, and Linux runtime image.

## Why Use It?

- Correctness! Build actions run inside an empty chroot inside the VM.
  No nonhermetic dependencies can creep into the perfect sandbox.
- Security! Rust, Python, and NodeJS package ecosystems are built around giving arbitrary
  package authors RCE in your build environment. Actiond constrains them to a VM to thwart nefarious packages.
- Performance! the LLVM smoke build has measured about 20-30%
  faster through actiond than the comparable mac-host Bazel build.
- Save disk! No duplication of artifacts between CAS and output base(s)
- Better resource management! Multiple Bazel servers can point at one `actiond`
  worker/cache instead of each running too many local actions.

For implementation details, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Install

Download the latest macOS arm64 release:

```bash
curl -L \
  https://github.com/hermeticbuild/actiond/releases/latest/download/darwin-actiond_macos_arm64 \
  -o darwin-actiond_macos_arm64
curl -L \
  https://github.com/hermeticbuild/actiond/releases/latest/download/SHA256.txt \
  -o SHA256.txt
grep ' darwin-actiond_macos_arm64$' SHA256.txt | shasum -a 256 -c -
chmod +x darwin-actiond_macos_arm64
```

You can also download the binary from the
[GitHub releases page](https://github.com/hermeticbuild/actiond/releases).

## Start The Worker

```bash
./darwin-actiond_macos_arm64 serve-vm \
  --listen=127.0.0.1:8980 \
  --root="$HOME/Library/Caches/actiond/vm"
```

`--root` stores the VM state, including the guest-owned CAS and ActionCache.
Reusing the same root keeps the local cache warm across worker restarts.

The Windows ARM64 and x86_64 release binaries use Host Compute System and
Hyper-V sockets. The Windows smoke runs the embedded guest artifacts:

```powershell
e2e\run_llvm_windows_vm_smoke.ps1
```

Windows requires Hyper-V. `windows-actiond` wraps the runtime SquashFS and
guest-owned ext4 CAS in fixed VHD files. The default VHD paths are under
`--root`; `--cas-image` can select another CAS VHD path.

The Linux ARM64 and x86_64 releases embed Firecracker 1.16.0, the matching
kernel, the compressed initramfs, and the runtime SquashFS. `linux-actiond`
passes those read-only files to Firecracker through sealed memfds and executes
Firecracker with `execveat`; none of them is extracted to disk. The writable
CAS remains a persistent ext4 disk image under `--root`. Firecracker requires
KVM:

```bash
test -r /dev/kvm -a -w /dev/kvm
./linux-actiond_linux_x86_64 serve-vm \
  --listen=127.0.0.1:8980 \
  --root="$HOME/.cache/actiond/vm"
```

## Point Bazel At actiond

Add a config like this to your workspace `.bazelrc`:

```bazelrc
build:actiond --remote_executor=grpc://127.0.0.1:8980
build:actiond --remote_cache=grpc://127.0.0.1:8980
build:actiond --spawn_strategy=remote
build:actiond --genrule_strategy=remote
build:actiond --remote_local_fallback=false
build:actiond --remote_upload_local_results=false
build:actiond --noremote_cache_compression
```

Then build with:

```bash
bazel build --config=actiond //...
```

Your Bazel workspace still needs toolchains and platforms that can run in Linux.
`actiond` executes the actions Bazel sends it; it does not turn a macOS toolchain
into a Linux toolchain automatically.

## Runtime Selection

The embedded runtime image currently includes:

- `glibc2.31`
- `glibc2.35`
- `glibc2.39`
- `bash`

Actions that are not fully hermetic and need a glibc can request one be mounted into their chroot via execution property:

```python
exec_properties = {"libc": "glibc2.35"}
```

Unsupported libc names fail explicitly.

Actions that invoke a Bash script can request the embedded Bash runtime with
the `requires-bash` exec property:

```python
exec_properties = {"requires-bash": ""}
```

For a whole build, Bazel can inject the same property globally:

```bash
--remote_default_exec_properties=requires-bash=
```

## Build From Source

Most users should use releases. Source builds are mainly for development:

```bash
bazel build --config=remote -c opt //cmd/darwin-actiond
bazel build --config=remote -c opt //cmd/linux-actiond:linux-actiond_linux_arm64
bazel build --config=remote -c opt //cmd/linux-actiond:linux-actiond_linux_x86_64
```

Normal contributor checks:

```bash
bazel build --config=remote //...
bazel test --config=remote //...
```

The macOS and Linux VM e2e harness is:

```bash
tools/e2e.sh vm
```
