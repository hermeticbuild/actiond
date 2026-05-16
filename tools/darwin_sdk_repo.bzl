def _quote(value):
    return repr(value)

def _darwin_sdk_repository_impl(rctx):
    sdk_path = ""
    if rctx.os.name == "mac os x":
        result = rctx.execute(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
        if result.return_code != 0:
            fail("xcrun --sdk macosx --show-sdk-path failed: %s" % result.stderr)
        sdk_path = result.stdout.strip()
        if not sdk_path:
            fail("xcrun returned an empty macOS SDK path")

    rctx.file("BUILD.bazel", "")
    if sdk_path:
        rctx.file("defs.bzl", """\
DARWIN_SDK_PATH = {sdk}
DARWIN_SDK_LINKOPTS = [
    "-F" + DARWIN_SDK_PATH + "/System/Library/Frameworks",
    "-L" + DARWIN_SDK_PATH + "/usr/lib",
]
""".format(sdk = _quote(sdk_path)))
    else:
        rctx.file("defs.bzl", """\
DARWIN_SDK_PATH = ""
DARWIN_SDK_LINKOPTS = []
""")

darwin_sdk_repository = repository_rule(
    implementation = _darwin_sdk_repository_impl,
    environ = [
        "DEVELOPER_DIR",
        "SDKROOT",
    ],
)
