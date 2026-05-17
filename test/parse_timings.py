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
)


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


def parse_timings(log_path: pathlib.Path) -> list[Timing]:
    timings: list[Timing] = []
    for raw_line in log_path.read_text(errors="replace").splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = TIMING_RE.search(line)
        if not match:
            continue
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
            )
        )
    return timings


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
            "",
            "## Per Action",
            "",
            "| Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )
    for item in sorted(timings, key=lambda value: value.file_inputs):
        lines.append(
            f"| `{item.digest[:12]}` | {fmt_ms(ns_to_ms(item.total_ns))} | "
            f"{fmt_ms(ns_to_ms(item.input_fetch_ns))} | "
            f"{fmt_ms(ns_to_ms(item.execution_ns))} | "
            f"{fmt_ms(ns_to_ms(item.output_upload_ns))} | "
            f"{item.file_inputs} | {item.directory_inputs} | {item.bind_mounts} | "
            f"{item.output_files} file, {item.output_directories} dir |"
        )

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
