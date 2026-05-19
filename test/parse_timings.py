#!/usr/bin/env python3
"""Parse actiond executor timing logs and write a markdown summary."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import pathlib
import re
import statistics
import sys


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TIMING_RE = re.compile(
    r"execute timing (?P<digest>[0-9a-f]+)/(?P<size>\d+): "
    r"total_ns=(?P<total_ns>\d+) "
    r"input_fetch_ns=(?P<input_fetch_ns>\d+) "
    r"execution_ns=(?P<execution_ns>\d+) "
    r"output_upload_ns=(?P<output_upload_ns>\d+) "
    r"file_inputs=(?P<file_inputs>\d+) "
    r"directory_inputs=(?P<directory_inputs>\d+) "
    r"bind_mounts=(?P<bind_mounts>\d+) "
    r"(?:actiondfs_mounts=(?P<actiondfs_mounts>\d+) )?"
    r"output_files=(?P<output_files>\d+) "
    r"output_directories=(?P<output_directories>\d+)"
    r"(?: stress_case=(?P<stress_case>\S+))?"
)
RUNNER_RE = re.compile(
    r"runner timing (?P<digest>[0-9a-f]+)/(?P<size>\d+): "
    r"parent_prepare_ns=(?P<parent_prepare_ns>\d+) "
    r"fork_ns=(?P<fork_ns>\d+) "
    r"child_setup_ns=(?P<child_setup_ns>\d+) "
    r"process_io_ns=(?P<process_io_ns>\d+) "
    r"wait_ns=(?P<wait_ns>\d+) "
    r"stdio_digest_ns=(?P<stdio_digest_ns>\d+) "
    r"bind_mounts=(?P<runner_bind_mounts>\d+) "
    r"(?:actiondfs_mounts=(?P<runner_actiondfs_mounts>\d+) )?"
    r"setup_signaled=(?P<setup_signaled>true|false)"
)
BRIDGE_RE = re.compile(
    r"vm bridge timing "
    r"elapsed_ns=(?P<elapsed_ns>\d+) "
    r"client_to_guest_bytes=(?P<client_to_guest_bytes>\d+) "
    r"guest_to_client_bytes=(?P<guest_to_client_bytes>\d+) "
    r"client_to_guest_reads=(?P<client_to_guest_reads>\d+) "
    r"client_to_guest_writes=(?P<client_to_guest_writes>\d+) "
    r"guest_to_client_reads=(?P<guest_to_client_reads>\d+) "
    r"guest_to_client_writes=(?P<guest_to_client_writes>\d+) "
    r"read_errors=(?P<read_errors>\d+) "
    r"write_errors=(?P<write_errors>\d+)"
)


@dataclasses.dataclass(frozen=True)
class RunnerTiming:
    parent_prepare_ns: int
    fork_ns: int
    child_setup_ns: int
    process_io_ns: int
    wait_ns: int
    stdio_digest_ns: int
    bind_mounts: int
    actiondfs_mounts: int
    setup_signaled: bool


@dataclasses.dataclass(frozen=True)
class Timing:
    digest: str
    size: int
    total_ns: int
    input_fetch_ns: int
    execution_ns: int
    output_upload_ns: int
    file_inputs: int
    directory_inputs: int
    bind_mounts: int
    actiondfs_mounts: int
    output_files: int
    output_directories: int
    stress_case: str = "unknown"
    runner: RunnerTiming | None = None


@dataclasses.dataclass(frozen=True)
class BridgeTiming:
    elapsed_ns: int
    client_to_guest_bytes: int
    guest_to_client_bytes: int
    client_to_guest_reads: int
    client_to_guest_writes: int
    guest_to_client_reads: int
    guest_to_client_writes: int
    read_errors: int
    write_errors: int


def parse_timings(log_path: pathlib.Path) -> list[Timing]:
    timings: list[Timing] = []
    runner_timings: dict[str, RunnerTiming] = {}
    for raw_line in log_path.read_text(errors="replace").splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = TIMING_RE.search(line)
        if match:
            groups = match.groupdict()
            timings.append(
                Timing(
                    digest=groups["digest"],
                    size=int(groups["size"]),
                    total_ns=int(groups["total_ns"]),
                    input_fetch_ns=int(groups["input_fetch_ns"]),
                    execution_ns=int(groups["execution_ns"]),
                    output_upload_ns=int(groups["output_upload_ns"]),
                    file_inputs=int(groups["file_inputs"]),
                    directory_inputs=int(groups["directory_inputs"]),
                    bind_mounts=int(groups["bind_mounts"]),
                    actiondfs_mounts=int(groups["actiondfs_mounts"] or 0),
                    output_files=int(groups["output_files"]),
                    output_directories=int(groups["output_directories"]),
                    stress_case=groups["stress_case"] or "unknown",
                )
            )
            continue

        match = RUNNER_RE.search(line)
        if match:
            groups = match.groupdict()
            runner_timings[groups["digest"]] = RunnerTiming(
                parent_prepare_ns=int(groups["parent_prepare_ns"]),
                fork_ns=int(groups["fork_ns"]),
                child_setup_ns=int(groups["child_setup_ns"]),
                process_io_ns=int(groups["process_io_ns"]),
                wait_ns=int(groups["wait_ns"]),
                stdio_digest_ns=int(groups["stdio_digest_ns"]),
                bind_mounts=int(groups["runner_bind_mounts"]),
                actiondfs_mounts=int(groups["runner_actiondfs_mounts"] or 0),
                setup_signaled=groups["setup_signaled"] == "true",
            )

    return [
        dataclasses.replace(item, runner=runner_timings.get(item.digest))
        for item in timings
    ]


def parse_bridge_timings(log_path: pathlib.Path) -> list[BridgeTiming]:
    timings: list[BridgeTiming] = []
    for raw_line in log_path.read_text(errors="replace").splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = BRIDGE_RE.search(line)
        if not match:
            continue
        groups = match.groupdict()
        timings.append(
            BridgeTiming(
                elapsed_ns=int(groups["elapsed_ns"]),
                client_to_guest_bytes=int(groups["client_to_guest_bytes"]),
                guest_to_client_bytes=int(groups["guest_to_client_bytes"]),
                client_to_guest_reads=int(groups["client_to_guest_reads"]),
                client_to_guest_writes=int(groups["client_to_guest_writes"]),
                guest_to_client_reads=int(groups["guest_to_client_reads"]),
                guest_to_client_writes=int(groups["guest_to_client_writes"]),
                read_errors=int(groups["read_errors"]),
                write_errors=int(groups["write_errors"]),
            )
        )
    return timings


def ns_to_ms(value: int) -> float:
    return value / 1_000_000.0


def fmt_ms(value: float) -> str:
    return f"{value:.3f}"


def fmt_kib(value: float) -> str:
    return f"{value / 1024.0:.1f}"


def fmt_mib(value: int) -> str:
    return f"{value / (1024.0 * 1024.0):.2f}"


def markdown_table(headers: list[str], rows: list[list[str]], right_align: set[int]) -> list[str]:
    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))
    widths = [max(width, 3) for width in widths]

    def format_cell(index: int, cell: str) -> str:
        if index in right_align:
            return cell.rjust(widths[index])
        return cell.ljust(widths[index])

    header = "| " + " | ".join(format_cell(index, cell) for index, cell in enumerate(headers)) + " |"
    separator_cells = []
    for index, width in enumerate(widths):
        if index in right_align:
            separator_cells.append("-" * (width - 1) + ":")
        else:
            separator_cells.append("-" * width)
    separator = "| " + " | ".join(separator_cells) + " |"
    body = [
        "| " + " | ".join(format_cell(index, cell) for index, cell in enumerate(row)) + " |"
        for row in rows
    ]
    return [header, separator, *body]


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * pct / 100.0
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = rank - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def stat_cells(label: str, values_ns: list[int], total_ns: int) -> list[str]:
    values_ms = [ns_to_ms(value) for value in values_ns]
    pct = 100.0 * sum(values_ns) / total_ns if total_ns else 0.0
    return [
        label,
        fmt_ms(min(values_ms)),
        fmt_ms(percentile(values_ms, 25)),
        fmt_ms(percentile(values_ms, 50)),
        fmt_ms(percentile(values_ms, 75)),
        fmt_ms(percentile(values_ms, 95)),
        fmt_ms(statistics.mean(values_ms)),
        fmt_ms(max(values_ms)),
        f"{pct:.1f}%",
    ]


def ms_stat_cells(label: str, values_ns: list[int]) -> list[str]:
    values_ms = [ns_to_ms(value) for value in values_ns]
    return [
        label,
        fmt_ms(min(values_ms)),
        fmt_ms(percentile(values_ms, 25)),
        fmt_ms(percentile(values_ms, 50)),
        fmt_ms(percentile(values_ms, 75)),
        fmt_ms(percentile(values_ms, 95)),
        fmt_ms(statistics.mean(values_ms)),
        fmt_ms(max(values_ms)),
    ]


def int_stat_cells(label: str, values: list[int]) -> list[str]:
    values_float = [float(value) for value in values]
    return [
        label,
        str(min(values)),
        f"{percentile(values_float, 25):.0f}",
        f"{percentile(values_float, 50):.0f}",
        f"{percentile(values_float, 75):.0f}",
        f"{percentile(values_float, 95):.0f}",
        f"{statistics.mean(values):.1f}",
        str(max(values)),
    ]


def kib_stat_cells(label: str, values: list[int]) -> list[str]:
    values_float = [float(value) for value in values]
    return [
        label,
        fmt_kib(min(values_float)),
        fmt_kib(percentile(values_float, 25)),
        fmt_kib(percentile(values_float, 50)),
        fmt_kib(percentile(values_float, 75)),
        fmt_kib(percentile(values_float, 95)),
        fmt_kib(statistics.mean(values_float)),
        fmt_kib(max(values_float)),
    ]


def grouped_by_case(timings: list[Timing]) -> dict[str, list[Timing]]:
    groups: dict[str, list[Timing]] = {}
    for item in timings:
        groups.setdefault(item.stress_case, []).append(item)
    return groups


def case_rows(timings: list[Timing]) -> list[str]:
    groups = grouped_by_case(timings)
    if len(groups) <= 1 and "unknown" in groups:
        return []

    table_rows: list[list[str]] = []
    for name in sorted(groups):
        items = groups[name]
        total_ms = [ns_to_ms(item.total_ns) for item in items]
        input_ms = [ns_to_ms(item.input_fetch_ns) for item in items]
        execute_ms = [ns_to_ms(item.execution_ns) for item in items]
        output_ms = [ns_to_ms(item.output_upload_ns) for item in items]
        mounts = [float(item.bind_mounts + item.actiondfs_mounts) for item in items]
        table_rows.append(
            [
                name,
                str(len(items)),
                fmt_ms(percentile(total_ms, 25)),
                fmt_ms(percentile(total_ms, 50)),
                fmt_ms(percentile(total_ms, 75)),
                fmt_ms(percentile(total_ms, 95)),
                fmt_ms(percentile(input_ms, 50)),
                fmt_ms(percentile(execute_ms, 50)),
                fmt_ms(percentile(output_ms, 50)),
                f"{percentile(mounts, 50):.0f}",
            ]
        )

    return [
        "",
        "## Stage Timing By Stress Case",
        "",
        *markdown_table(
            ["Stress Case", "Actions", "Total p25", "Total p50", "Total p75", "Total p95", "Input p50", "Execute p50", "Output p50", "Mounts p50"],
            table_rows,
            {1, 2, 3, 4, 5, 6, 7, 8, 9},
        ),
    ]


def overhead_rows(timings: list[Timing]) -> list[str]:
    with_runner = [item for item in timings if item.runner is not None]
    if not with_runner:
        return []

    fixed_without_wait = [
        item.input_fetch_ns
        + item.output_upload_ns
        + item.runner.parent_prepare_ns
        + item.runner.fork_ns
        + item.runner.child_setup_ns
        + item.runner.stdio_digest_ns
        for item in with_runner
    ]
    fixed_with_wait = [
        value + item.runner.wait_ns
        for value, item in zip(fixed_without_wait, with_runner)
    ]

    return [
        "",
        "## Visible Overhead Estimate",
        "",
        "`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.",
        "",
        *markdown_table(
            ["Metric", "Min", "p25", "p50", "p75", "p95", "Mean", "Max", "Share of summed total"],
            [
                stat_cells("fixed overhead, no wait", fixed_without_wait, sum(item.total_ns for item in with_runner)),
                stat_cells("fixed overhead, with wait", fixed_with_wait, sum(item.total_ns for item in with_runner)),
            ],
            {1, 2, 3, 4, 5, 6, 7, 8},
        ),
    ]


def runner_rows(timings: list[Timing]) -> list[str]:
    with_runner = [item for item in timings if item.runner is not None]
    if not with_runner:
        return []

    runner_table = [
        stat_cells("parent prepare", [item.runner.parent_prepare_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_cells("fork", [item.runner.fork_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_cells("child setup", [item.runner.child_setup_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_cells("process/io", [item.runner.process_io_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_cells("wait", [item.runner.wait_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_cells("stdio digest", [item.runner.stdio_digest_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
    ]
    per_action_runner_table = [
        [
            item.stress_case,
            f"`{item.digest[:12]}`",
            fmt_ms(ns_to_ms(item.runner.parent_prepare_ns)),
            fmt_ms(ns_to_ms(item.runner.fork_ns)),
            fmt_ms(ns_to_ms(item.runner.child_setup_ns)),
            fmt_ms(ns_to_ms(item.runner.process_io_ns)),
            fmt_ms(ns_to_ms(item.runner.wait_ns)),
            fmt_ms(ns_to_ms(item.runner.stdio_digest_ns)),
            str(item.runner.setup_signaled),
        ]
        for item in sorted(with_runner, key=lambda value: (value.stress_case, value.file_inputs, value.directory_inputs, value.digest))
        if item.runner is not None
    ]

    return [
        "",
        "## Runner Timing",
        "",
        "These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.",
        "",
        *markdown_table(
            ["Runner Stage", "Min", "p25", "p50", "p75", "p95", "Mean", "Max", "Share of execute"],
            runner_table,
            {1, 2, 3, 4, 5, 6, 7, 8},
        ),
        "",
        *markdown_table(
            ["Stress Case", "Digest", "Parent Prep", "Fork", "Child Setup", "Process/IO", "Wait", "Stdio Digest", "Setup Signaled"],
            per_action_runner_table,
            {2, 3, 4, 5, 6, 7},
        ),
    ]


def bridge_rows(bridge_timings: list[BridgeTiming]) -> list[str]:
    if not bridge_timings:
        return []

    total_client_to_guest = sum(item.client_to_guest_bytes for item in bridge_timings)
    total_guest_to_client = sum(item.guest_to_client_bytes for item in bridge_timings)
    total_read_errors = sum(item.read_errors for item in bridge_timings)
    total_write_errors = sum(item.write_errors for item in bridge_timings)

    return [
        "",
        "## VM Bridge Timing",
        "",
        "These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.",
        "",
        f"- Bridge connections logged: `{len(bridge_timings)}`",
        f"- Total client to guest bytes: `{fmt_mib(total_client_to_guest)} MiB`",
        f"- Total guest to client bytes: `{fmt_mib(total_guest_to_client)} MiB`",
        f"- Pump errors: read=`{total_read_errors}`, write=`{total_write_errors}`",
        "",
        *markdown_table(
            ["Bridge Metric", "Min", "p25", "p50", "p75", "p95", "Mean", "Max"],
            [
                ms_stat_cells("connection elapsed", [item.elapsed_ns for item in bridge_timings]),
                kib_stat_cells("client to guest KiB", [item.client_to_guest_bytes for item in bridge_timings]),
                kib_stat_cells("guest to client KiB", [item.guest_to_client_bytes for item in bridge_timings]),
                int_stat_cells("client to guest reads", [item.client_to_guest_reads for item in bridge_timings]),
                int_stat_cells("client to guest writes", [item.client_to_guest_writes for item in bridge_timings]),
                int_stat_cells("guest to client reads", [item.guest_to_client_reads for item in bridge_timings]),
                int_stat_cells("guest to client writes", [item.guest_to_client_writes for item in bridge_timings]),
            ],
            {1, 2, 3, 4, 5, 6, 7},
        ),
    ]


def render_markdown(args: argparse.Namespace, timings: list[Timing], bridge_timings: list[BridgeTiming]) -> str:
    total_ns = sum(item.total_ns for item in timings)
    generated_at = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")

    lines: list[str] = [
        "# Executor Timing Summary",
        "",
        f"- Generated: `{generated_at}`",
        f"- Mode: `{args.mode}`",
        f"- Execute records parsed: `{len(timings)}`",
        f"- Unique action digests: `{len({item.digest for item in timings})}`",
        f"- Source log: `{args.log}`",
    ]
    if args.command:
        lines.append(f"- Command: `{args.command}`")
    if args.bazel_elapsed:
        lines.append(f"- Bazel elapsed: `{args.bazel_elapsed}`")
    if args.workload:
        lines.append(f"- Workload: {args.workload}")

    stage_table = [
        stat_cells("total", [item.total_ns for item in timings], total_ns),
        stat_cells("input fetch/materialize", [item.input_fetch_ns for item in timings], total_ns),
        stat_cells("execute", [item.execution_ns for item in timings], total_ns),
        stat_cells("output upload/collect", [item.output_upload_ns for item in timings], total_ns),
    ]
    count_table = [
        int_stat_cells("file inputs", [item.file_inputs for item in timings]),
        int_stat_cells("directory inputs", [item.directory_inputs for item in timings]),
        int_stat_cells("bind mounts", [item.bind_mounts for item in timings]),
        int_stat_cells("actiondfs mounts", [item.actiondfs_mounts for item in timings]),
        int_stat_cells("output files", [item.output_files for item in timings]),
        int_stat_cells("output directories", [item.output_directories for item in timings]),
    ]

    lines.extend(
        [
            "",
            "## Stage Timing",
            "",
            "All timing values are milliseconds unless noted.",
            "",
            *markdown_table(
                ["Stage", "Min", "p25", "p50", "p75", "p95", "Mean", "Max", "Share of summed total"],
                stage_table,
                {1, 2, 3, 4, 5, 6, 7, 8},
            ),
            "",
            "## Input And Mount Counts",
            "",
            *markdown_table(
                ["Metric", "Min", "p25", "p50", "p75", "p95", "Mean", "Max"],
                count_table,
                {1, 2, 3, 4, 5, 6, 7},
            ),
        ]
    )
    lines.extend(case_rows(timings))
    lines.extend(overhead_rows(timings))
    lines.extend(runner_rows(timings))
    lines.extend(bridge_rows(bridge_timings))
    lines.extend(
        [
            "",
            "## Per Action",
            "",
        ]
    )
    per_action_table = []
    for item in sorted(timings, key=lambda value: (value.stress_case, value.file_inputs, value.directory_inputs, value.digest)):
        per_action_table.append(
            [
                item.stress_case,
                f"`{item.digest[:12]}`",
                fmt_ms(ns_to_ms(item.total_ns)),
                fmt_ms(ns_to_ms(item.input_fetch_ns)),
                fmt_ms(ns_to_ms(item.execution_ns)),
                fmt_ms(ns_to_ms(item.output_upload_ns)),
                str(item.file_inputs),
                str(item.directory_inputs),
                str(item.bind_mounts + item.actiondfs_mounts),
                f"{item.output_files} file, {item.output_directories} dir",
            ]
        )
    lines.extend(
        markdown_table(
            ["Stress Case", "Digest", "Total", "Input", "Execute", "Output", "File Inputs", "Dir Inputs", "Bind Mounts", "Outputs"],
            per_action_table,
            {2, 3, 4, 5, 6, 7, 8},
        )
    )

    if all(item.directory_inputs == 0 for item in timings):
        if any(item.actiondfs_mounts > 0 for item in timings):
            lines.extend(
                [
                    "",
                    "## Notes",
                    "",
                    "- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.",
                    "- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.",
                ]
            )
        else:
            lines.extend(
                [
                    "",
                    "## Notes",
                    "",
                    "- This run observed `directory_inputs=0` for every action. The stress graph declares tree artifacts, but this execution path expanded them into file inputs rather than using directory bind mounts.",
                    "- Input fetch/materialization dominates this run, so execroot construction remains the next performance target.",
                ]
            )

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=pathlib.Path, help="actiond log containing execute timing lines")
    parser.add_argument("--output", type=pathlib.Path, help="markdown file to write")
    parser.add_argument("--mode", default="unknown", help="execution mode label, such as vm or linux")
    parser.add_argument("--command", default="", help="command used to produce the run")
    parser.add_argument("--bazel-elapsed", default="", help="Bazel elapsed time reported for the workload")
    parser.add_argument("--workload", default="", help="short workload description")
    args = parser.parse_args()

    timings = parse_timings(args.log)
    if not timings:
        print(f"no execute timing lines found in {args.log}", file=sys.stderr)
        return 1

    bridge_timings = parse_bridge_timings(args.log)
    markdown = render_markdown(args, timings, bridge_timings)
    if args.output:
        args.output.write_text(markdown)
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
