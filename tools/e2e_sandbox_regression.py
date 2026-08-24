#!/usr/bin/env python3
"""Verify actiond rejects working directories that escape the action chroot."""

import hashlib
import pathlib
import struct
import subprocess
import sys


CAS_METHOD = "/build.bazel.remote.execution.v2.ContentAddressableStorage/BatchUpdateBlobs"
EXECUTE_METHOD = "/build.bazel.remote.execution.v2.Execution/Execute"
EXECUTE_RESPONSE_TYPE = b"type.googleapis.com/build.bazel.remote.execution.v2.ExecuteResponse"


def varint(value):
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def number_field(number, value):
    return varint(number << 3) + varint(value)


def bytes_field(number, value):
    if isinstance(value, str):
        value = value.encode()
    return varint((number << 3) | 2) + varint(len(value)) + value


def read_varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError("truncated protobuf varint")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, offset
    raise ValueError("invalid protobuf varint")


def fields(message):
    decoded = {}
    offset = 0
    while offset < len(message):
        tag, offset = read_varint(message, offset)
        number, wire = tag >> 3, tag & 7
        if number == 0:
            raise ValueError("invalid protobuf field number")
        if wire == 0:
            value, offset = read_varint(message, offset)
        elif wire == 2:
            size, offset = read_varint(message, offset)
            if size > len(message) - offset:
                raise ValueError("truncated protobuf field")
            value = message[offset : offset + size]
            offset += size
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if size > len(message) - offset:
                raise ValueError("truncated fixed-width protobuf field")
            value = message[offset : offset + size]
            offset += size
        else:
            raise ValueError("unsupported protobuf wire type")
        decoded.setdefault(number, []).append(value)
    return decoded


def digest(data):
    return bytes_field(1, hashlib.sha256(data).hexdigest()) + number_field(2, len(data))


def grpc(endpoint, method, payload):
    request = b"\0" + struct.pack(">I", len(payload)) + payload
    command = [
        "curl",
        "--http2-prior-knowledge",
        "--silent",
        "--show-error",
        "--fail",
        "--max-time",
        "60",
        "--header",
        "content-type: application/grpc",
        "--header",
        "te: trailers",
        "--data-binary",
        "@-",
        "http://" + endpoint + method,
    ]
    try:
        response = subprocess.run(
            command,
            input=request,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=70,
        ).stdout
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise RuntimeError("gRPC " + method + " failed: " + detail) from error

    messages = []
    offset = 0
    while offset < len(response):
        if len(response) - offset < 5:
            raise ValueError("truncated gRPC response header")
        compressed = response[offset]
        size = struct.unpack_from(">I", response, offset + 1)[0]
        offset += 5
        if compressed or size > len(response) - offset:
            raise ValueError("invalid gRPC response record")
        messages.append(response[offset : offset + size])
        offset += size
    if not messages:
        raise ValueError("missing gRPC response")
    return messages


def upload(endpoint, blobs):
    request = b"".join(
        bytes_field(2, bytes_field(1, blob_digest) + bytes_field(2, data))
        for blob_digest, data in blobs
    )
    response = fields(grpc(endpoint, CAS_METHOD, request)[-1])
    items = response.get(1, [])
    if len(items) != len(blobs):
        raise RuntimeError("BatchUpdateBlobs returned an unexpected blob count")
    for item in items:
        status = fields(fields(item).get(2, [b""])[-1])
        if status.get(1, [0])[-1] != 0:
            raise RuntimeError("BatchUpdateBlobs rejected a regression blob")


def execute(endpoint, action_digest):
    request = number_field(3, 1) + bytes_field(6, action_digest)
    operation = fields(grpc(endpoint, EXECUTE_METHOD, request)[-1])
    if operation.get(3, [0])[-1] != 1:
        raise RuntimeError("Execute returned an incomplete operation")
    if 4 in operation:
        raise RuntimeError("Execute returned an unexpected operation error")
    if 5 not in operation:
        raise RuntimeError("Execute returned no response")

    packed = fields(operation[5][-1])
    if packed.get(1, [b""])[-1] != EXECUTE_RESPONSE_TYPE:
        raise RuntimeError("Execute returned an unexpected response type")
    if 2 not in packed:
        raise RuntimeError("Execute returned no encoded response")

    response = fields(packed[2][-1])
    status = fields(response.get(3, [b""])[-1])
    return status.get(1, [0])[-1], response.get(1, [None])[-1]


def command(working_directory, arguments, output_paths=()):
    message = b"".join(bytes_field(1, argument) for argument in arguments)
    message += bytes_field(6, working_directory)
    message += b"".join(bytes_field(7, path) for path in output_paths)
    return message


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: e2e_sandbox_regression.py <host:port> <linux-action-tool>")
    endpoint = sys.argv[1]
    executable = pathlib.Path(sys.argv[2]).read_bytes()
    executable_digest = digest(executable)

    attacks = (
        ("proc-init-escape", "/proc/1/root/cas"),
        ("proc-self-escape", "/proc/self/cwd/cas"),
    )
    file_node = bytes_field(1, "tool") + bytes_field(2, executable_digest) + number_field(4, 1)
    directory = bytes_field(1, file_node)
    for name, target in attacks:
        directory += bytes_field(3, bytes_field(1, name) + bytes_field(2, target))
    directory_digest = digest(directory)

    scenarios = [
        (name, command(name, ("/execroot/tool",)), None)
        for name, _ in attacks
    ]
    scenarios.append(
        (
            "staged-output-parent",
            command("sub", ("/execroot/tool", "--out-file", "out"), ("sub/out",)),
            "sub/out",
        )
    )

    blobs = [(executable_digest, executable), (directory_digest, directory)]
    actions = []
    for name, command_bytes, output_path in scenarios:
        command_digest = digest(command_bytes)
        action = bytes_field(1, command_digest) + bytes_field(2, directory_digest) + number_field(7, 1)
        action_digest = digest(action)
        blobs.extend(((command_digest, command_bytes), (action_digest, action)))
        actions.append((name, action_digest, output_path))
    upload(endpoint, blobs)

    for name, action_digest, output_path in actions:
        status, result = execute(endpoint, action_digest)
        if output_path is None:
            if status != 13 or result is not None:
                raise RuntimeError("working directory escaped its chroot: " + name)
            continue

        if status != 0 or result is None:
            raise RuntimeError("benign staged working directory failed")
        action_result = fields(result)
        if action_result.get(4, [0])[-1] != 0:
            raise RuntimeError("benign staged working directory returned a failed action")
        outputs = [fields(output) for output in action_result.get(2, [])]
        if not any(
            output.get(1, [b""])[-1] == output_path.encode()
            and 2 in output
            and fields(output[2][-1]).get(2, [0])[-1] > 0
            for output in outputs
        ):
            raise RuntimeError("benign staged working directory did not produce its declared output")

    print("sandbox working-directory escape regressions passed")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        print("sandbox working-directory regression failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
