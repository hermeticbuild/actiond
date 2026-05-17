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
    r"setup_signaled=(?P<setup_signaled>true|false)"
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
    output_files: int
    output_directories: int
    stress_case: str = "unknown"
    runner: RunnerTiming | None = None


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
                setup_signaled=groups["setup_signaled"] == "true",
            )

    return [
        dataclasses.replace(item, runner=runner_timings.get(item.digest))
        for item in timings
    ]


def ns_to_ms(value: int) -> float:
    return value / 1_000_000.0


def fmt_ms(value: float) -> str:
    return f"{value:.3f}"


def stat_row(label: str, values_ns: list[int], total_ns: int) -> str:
    values_ms = [ns_to_ms(value) for value in values_ns]
    pct = 100.0 * sum(values_ns) / total_ns if total_ns else 0.0
    return (
        f"| {label} | {fmt_ms(min(values_ms))} | "
        f"{fmt_ms(statistics.median(values_ms))} | "
        f"{fmt_ms(statistics.mean(values_ms))} | "
        f"{fmt_ms(max(values_ms))} | {pct:.1f}% |"
    )


def int_stat_row(label: str, values: list[int]) -> str:
    return (
        f"| {label} | {min(values)} | {statistics.median(values):.0f} | "
        f"{statistics.mean(values):.1f} | {max(values)} |"
    )


def grouped_by_case(timings: list[Timing]) -> dict[str, list[Timing]]:
    groups: dict[str, list[Timing]] = {}
    for item in timings:
        groups.setdefault(item.stress_case, []).append(item)
    return groups


def case_rows(timings: list[Timing]) -> list[str]:
    groups = grouped_by_case(timings)
    if len(groups) <= 1 and "unknown" in groups:
        return []

    rows = [
        "",
        "## Stage Timing By Stress Case",
        "",
        "| Stress Case | Actions | Total Median | Total Mean | Input Mean | Execute Mean | Output Mean | File Inputs Median | Dir Inputs Median | Bind Mounts Median |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name in sorted(groups):
        items = groups[name]
        rows.append(
            f"| {name} | {len(items)} | "
            f"{fmt_ms(statistics.median(ns_to_ms(item.total_ns) for item in items))} | "
            f"{fmt_ms(statistics.mean(ns_to_ms(item.total_ns) for item in items))} | "
            f"{fmt_ms(statistics.mean(ns_to_ms(item.input_fetch_ns) for item in items))} | "
            f"{fmt_ms(statistics.mean(ns_to_ms(item.execution_ns) for item in items))} | "
            f"{fmt_ms(statistics.mean(ns_to_ms(item.output_upload_ns) for item in items))} | "
            f"{statistics.median(item.file_inputs for item in items):.0f} | "
            f"{statistics.median(item.directory_inputs for item in items):.0f} | "
            f"{statistics.median(item.bind_mounts for item in items):.0f} |"
        )
    return rows


def runner_rows(timings: list[Timing]) -> list[str]:
    with_runner = [item for item in timings if item.runner is not None]
    if not with_runner:
        return []

    return [
        "",
        "## Runner Timing",
        "",
        "These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.",
        "",
        "| Runner Stage | Min | Median | Mean | Max | Share of execute |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
        stat_row("parent prepare", [item.runner.parent_prepare_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_row("fork", [item.runner.fork_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_row("child setup", [item.runner.child_setup_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_row("process/io", [item.runner.process_io_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_row("wait", [item.runner.wait_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        stat_row("stdio digest", [item.runner.stdio_digest_ns for item in with_runner if item.runner], sum(item.execution_ns for item in with_runner)),
        "",
        "| Stress Case | Digest | Parent Prep | Fork | Child Setup | Process/IO | Wait | Stdio Digest | Setup Signaled |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        *[
            (
                f"| {item.stress_case} | `{item.digest[:12]}` | {fmt_ms(ns_to_ms(item.runner.parent_prepare_ns))} | "
                f"{fmt_ms(ns_to_ms(item.runner.fork_ns))} | "
                f"{fmt_ms(ns_to_ms(item.runner.child_setup_ns))} | "
                f"{fmt_ms(ns_to_ms(item.runner.process_io_ns))} | "
                f"{fmt_ms(ns_to_ms(item.runner.wait_ns))} | "
                f"{fmt_ms(ns_to_ms(item.runner.stdio_digest_ns))} | "
                f"{item.runner.setup_signaled} |"
            )
            for item in sorted(with_runner, key=lambda value: (value.stress_case, value.file_inputs, value.directory_inputs, value.digest))
            if item.runner is not None
        ],
    ]


def render_markdown(args: argparse.Namespace, timings: list[Timing]) -> str:
    total_ns = sum(item.total_ns for item in timings)
    generated_at = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")

    lines: list[str] = [
        "# Stress Timing Summary",
        "",
        f"- Generated: `{generated_at}`",
        f"- Mode: `{args.mode}`",
        f"- Actions parsed: `{len(timings)}`",
        f"- Source log: `{args.log}`",
    ]
    if args.command:
        lines.append(f"- Command: `{args.command}`")
    if args.bazel_elapsed:
        lines.append(f"- Bazel elapsed: `{args.bazel_elapsed}`")
    if args.workload:
        lines.append(f"- Workload: {args.workload}")
    lines.extend(
        [
            "",
            "## Stage Timing",
            "",
            "All timing values are milliseconds unless noted.",
            "",
            "| Stage | Min | Median | Mean | Max | Share of summed total |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
            stat_row("total", [item.total_ns for item in timings], total_ns),
            stat_row("input fetch/materialize", [item.input_fetch_ns for item in timings], total_ns),
            stat_row("execute", [item.execution_ns for item in timings], total_ns),
            stat_row("output upload/collect", [item.output_upload_ns for item in timings], total_ns),
            "",
            "## Input And Mount Counts",
            "",
            "| Metric | Min | Median | Mean | Max |",
            "| --- | ---: | ---: | ---: | ---: |",
            int_stat_row("file inputs", [item.file_inputs for item in timings]),
            int_stat_row("directory inputs", [item.directory_inputs for item in timings]),
            int_stat_row("bind mounts", [item.bind_mounts for item in timings]),
            int_stat_row("output files", [item.output_files for item in timings]),
            int_stat_row("output directories", [item.output_directories for item in timings]),
        ]
    )
    lines.extend(case_rows(timings))
    lines.extend(
        [
            "",
            "## Per Action",
            "",
            "| Stress Case | Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )
    for item in sorted(timings, key=lambda value: (value.stress_case, value.file_inputs, value.directory_inputs, value.digest)):
        lines.append(
            f"| {item.stress_case} | `{item.digest[:12]}` | {fmt_ms(ns_to_ms(item.total_ns))} | "
            f"{fmt_ms(ns_to_ms(item.input_fetch_ns))} | "
            f"{fmt_ms(ns_to_ms(item.execution_ns))} | "
            f"{fmt_ms(ns_to_ms(item.output_upload_ns))} | "
            f"{item.file_inputs} | {item.directory_inputs} | {item.bind_mounts} | "
            f"{item.output_files} file, {item.output_directories} dir |"
        )

    lines.extend(runner_rows(timings))

    if all(item.directory_inputs == 0 for item in timings):
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
    parser.add_argument("--bazel-elapsed", default="", help="Bazel elapsed time reported for the stress workspace")
    parser.add_argument("--workload", default="", help="short workload description")
    args = parser.parse_args()

    timings = parse_timings(args.log)
    if not timings:
        print(f"no execute timing lines found in {args.log}", file=sys.stderr)
        return 1

    markdown = render_markdown(args, timings)
    if args.output:
        args.output.write_text(markdown)
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
