# Agent Notes

## Required Checks

Run the normal repository checks before finalizing code changes:

```bash
bazel build //...
bazel test //...
```

For execution changes, also run the e2e harness:

```bash
tools/e2e.sh linux
```

On macOS, use Docker for the Linux chroot path:

```bash
tools/docker/run_linux_e2e.sh
```

For the Virtualization.framework path, provide an arm64 Linux kernel image and run:

```bash
ACTIOND_VM_KERNEL=/path/to/Image tools/e2e.sh vm
```

Do not claim the VM path was tested unless `tools/e2e.sh vm` completed.

The VM guest mounts the host CAS share read-only at `/cas-ro` and uses a tmpfs
overlay at `/cas`. VM e2e therefore validates API-visible execution behavior
for one running VM; it does not prove that VM-written blobs persisted into the
host CAS directory.

## Stress Workspace

The `test/` directory is a standalone Bazel workspace used by `tools/e2e.sh`.
It generates a remote-execution workload with many bare file inputs, nested
source-directory inputs, declared tree-artifact inputs, output files, and output
directories. The harness copies a Linux `e2e_action_tool` binary into
`test/tool/action-tool` before invoking Bazel against actiond.
