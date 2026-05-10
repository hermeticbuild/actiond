`tools/e2e.sh` copies a Linux `e2e_action_tool` binary here before running
this workspace against actiond.

The tool source intentionally lives in the main workspace at
`tools/e2e_action_tool.zig`, because the main workspace cross-compiles it before
this dummy workspace is run through the remote executor under test. Building the
tool from this workspace would make the e2e test bootstrap through actiond.
