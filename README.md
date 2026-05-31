# actiond

`actiond` is a local Remote Execution API worker and cache for Bazel. On macOS
it starts a small Linux VM and runs Bazel actions inside that VM, so a Mac can
act like a local Linux remote-execution worker.

The main user-facing binary is `darwin-actiond`. It includes the VM kernel,
initramfs, and Linux runtime image, so you do not need to build this repository
from source to use it.

## Why Use It?

- Perfect sandboxing! actions run inside an empty chroot inside the VM.
  No nonhermetic dependencies can creep in.
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
shasum -a 256 -c SHA256.txt
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
```

Normal contributor checks:

```bash
bazel build --config=remote //...
bazel test --config=remote //...
```

The macOS VM e2e harness is:

```bash
tools/e2e.sh vm
```
