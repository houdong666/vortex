#!/usr/bin/env python3
"""Run CP experiment 2 baseline microbenchmarks and write result artifacts."""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
from pathlib import Path


FIELDS = [
    "workload",
    "requested_units",
    "commands",
    "submitted_commands",
    "retired_commands",
    "total_cycles",
    "idle_cycles",
    "decode_cycles",
    "bid_cycles",
    "wait_done_cycles",
    "retire_cycles",
    "kmu_wait_cycles",
    "dma_wait_cycles",
    "dcr_wait_cycles",
    "event_wait_cycles",
    "fetch_cache_lines",
    "fetch_wait_cycles",
    "completion_stall_cycles",
    "arb_wait_cycles",
    "queue_latency_cycles",
    "execution_latency_cycles",
    "total_latency_cycles",
    "latency_samples",
    "cmd_per_cycle",
    "cpc",
    "fetch_bytes",
    "bytes_per_command",
    "dcr_writes",
    "dcr_reads",
    "launches",
]

FLOAT_FIELDS = {"cmd_per_cycle", "cpc", "bytes_per_command"}

WORKLOADS = [
    ("B1", 16, "DCR_WRITE x16"),
    ("B2", 16, "DCR_READ x16"),
    ("B7", 8, "LAUNCH x8"),
    ("B8", 1, "DCR_WRITE x18 + LAUNCH"),
    ("B9", 6, "(DCR_WRITE + DCR_READ + LAUNCH) x6"),
]

UNSUPPORTED = [
    ("B0", "NOP 在 full ring 中 opcode=0/flags=0 会被 unpack 当作填充哨兵；本项保留在 cp_engine 单元层。"),
    ("B3", "MEM_WRITE 需要补齐 full CP harness 的 host/device AXI 数据面模型和搬运校验。"),
    ("B4", "MEM_READ 需要补齐 full CP harness 的 host/device AXI 数据面模型和搬运校验。"),
    ("B5", "MEM_COPY 需要补齐 device AXI 双端模型和设备内存校验。"),
    ("B6", "EVENT_SIGNAL 需要补齐 event unit 的 device AXI 事件计数器模型。"),
]


def run(cmd: list[str], cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        joined = " ".join(cmd)
        raise SystemExit(f"command failed ({proc.returncode}): {joined}\n{proc.stdout}\n{proc.stderr}")
    return proc


def parse_perf(stdout: str) -> dict[str, object]:
    for line in stdout.splitlines():
        if not line.startswith("CP_PERF,"):
            continue
        values = line.split(",")[1:]
        if len(values) != len(FIELDS):
            raise SystemExit(f"unexpected CP_PERF field count: {line}")
        row: dict[str, object] = {}
        for key, value in zip(FIELDS, values):
            if key in FLOAT_FIELDS:
                row[key] = float(value)
            elif key == "workload":
                row[key] = value
            else:
                row[key] = int(value)
        return row
    raise SystemExit(f"missing CP_PERF line:\n{stdout}")


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def pct(num: object, den: object) -> float:
    den_f = float(den)
    return (float(num) * 100.0 / den_f) if den_f else 0.0


def write_svg(path: Path, rows: list[dict[str, object]]) -> None:
    width = 760
    height = 360
    left = 70
    bottom = 295
    chart_h = 220
    bar_w = 70
    gap = 45
    max_cpc = max(float(r["cpc"]) for r in rows)
    scale = chart_h / max_cpc if max_cpc else 1.0
    colors = ["#2f6f9f", "#8f5b2e", "#3d7f55", "#9b3f55", "#5b5f97"]

    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">'.format(width, height),
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<text x="32" y="38" font-family="Arial, sans-serif" font-size="22" fill="#1f2933">实验2 Baseline CPC</text>',
        '<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#27313f" stroke-width="1.5"/>'.format(left, bottom, width - 38),
        '<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#27313f" stroke-width="1.5"/>'.format(left, bottom - chart_h, bottom),
    ]
    for i, row in enumerate(rows):
        cpc = float(row["cpc"])
        bar_h = cpc * scale
        x = left + 35 + i * (bar_w + gap)
        y = bottom - bar_h
        parts.append('<rect x="{0:.1f}" y="{1:.1f}" width="{2}" height="{3:.1f}" fill="{4}"/>'.format(x, y, bar_w, bar_h, colors[i % len(colors)]))
        parts.append('<text x="{0:.1f}" y="{1}" font-family="Arial, sans-serif" font-size="14" text-anchor="middle" fill="#111827">{2}</text>'.format(x + bar_w / 2, bottom + 24, row["workload"]))
        parts.append('<text x="{0:.1f}" y="{1:.1f}" font-family="Arial, sans-serif" font-size="13" text-anchor="middle" fill="#111827">{2:.2f}</text>'.format(x + bar_w / 2, y - 8, cpc))
    parts.append('<text x="28" y="170" font-family="Arial, sans-serif" font-size="13" fill="#4b5563" transform="rotate(-90 28 170)">Cycles / Command</text>')
    parts.append("</svg>")
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def write_unsupported(path: Path) -> None:
    lines = [
        "# 实验2当前未纳入 full-ring baseline 的 Workload",
        "",
        "| Workload | 原因 |",
        "|---|---|",
    ]
    for wid, reason in UNSUPPORTED:
        lines.append(f"| {wid} | {reason} |")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_summary(path: Path, rows: list[dict[str, object]], repo: Path) -> None:
    lines = [
        "# 实验2：CP 性能测量基础设施 Baseline",
        "",
        "## 结果文件",
        "",
        "- `results/exp02/baseline_metrics.csv`",
        "- `results/exp02/baseline_metrics.json`",
        "- `results/exp02/cpc_chart.svg`",
        "- `results/exp02/unsupported_workloads.md`",
        "",
        "## Baseline 汇总",
        "",
        "| Workload | Commands | Cycles | CPC | Cmd/Cycle | Fetch CL | Fetch Bytes | Bytes/Command | Arb Wait | Completion Stall |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            "| {workload} | {commands} | {total_cycles} | {cpc:.3f} | {cmd_per_cycle:.6f} | "
            "{fetch_cache_lines} | {fetch_bytes} | {bytes_per_command:.3f} | "
            "{arb_wait_cycles} | {completion_stall_cycles} |".format(**row)
        )

    lines += [
        "",
        "## 初始瓶颈分解",
        "",
        "| Workload | Fetch Wait | BID | WAIT_DONE | RETIRE | Completion Stall | 主要等待来源 |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for row in rows:
        wait_sources = [
            ("KMU", int(row["kmu_wait_cycles"])),
            ("DMA", int(row["dma_wait_cycles"])),
            ("DCR", int(row["dcr_wait_cycles"])),
            ("EVENT", int(row["event_wait_cycles"])),
        ]
        dominant = max(wait_sources, key=lambda item: item[1])
        lines.append(
            "| {workload} | {fw:.1f}% | {bid:.1f}% | {wd:.1f}% | {ret:.1f}% | {cs:.1f}% | {dom} |".format(
                workload=row["workload"],
                fw=pct(row["fetch_wait_cycles"], row["total_cycles"]),
                bid=pct(row["bid_cycles"], row["total_cycles"]),
                wd=pct(row["wait_done_cycles"], row["total_cycles"]),
                ret=pct(row["retire_cycles"], row["total_cycles"]),
                cs=pct(row["completion_stall_cycles"], row["total_cycles"]),
                dom=f"{dominant[0]}={dominant[1]} cycles",
            )
        )

    lines += [
        "",
        "观察：单队列 baseline 下仲裁等待 `arb_wait_cycles` 为 0，说明当前瓶颈不是多队列争用；B2 的 DCR read 多了响应等待，CPC 高于 B1；B7/B9 的 KMU launch 等待占比明显，受 testbench 中固定 busy 周期影响。",
        "",
        "## 遇到的问题",
        "",
        "- 指导书称“9个Workload”，但表格实际列出 B0 到 B9 共 10 个 ID；本次按实际 ID 处理。",
        "- B0 的 NOP 在 full ring 中与 unpack 的全零填充哨兵冲突，因此保留给 `cp_engine` 单元层，不纳入 full-ring baseline。",
        "- B3/B4/B5/B6 需要完整 DMA/Event 外设模型；当前 full CP harness 只闭环了 host ring/completion、DCR 和 launch。",
        "- 原 completion slot 放在 ring 附近容易和更长 microbenchmark ring 重叠；实验2 harness 使用 `MEM_BASE + 0x3000`。",
        "",
        "## 如何复现",
        "",
        "```bash",
        f"cd {repo}",
        "python3 results/exp02/run_exp02.py",
        "```",
        "",
        "脚本内部会执行：",
        "",
        "```bash",
        "cd build",
        "../configure --xlen=32 --tooldir=$PWD/tools",
        "env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core",
        "./hw/unittest/cp_core/cp_core --workload=B1 --commands=16 --quiet",
        "```",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true", help="skip configure/make and only run the existing binary")
    args = parser.parse_args()

    out_dir = Path(__file__).resolve().parent
    repo = out_dir.parents[1]
    build = repo / "build"
    build.mkdir(exist_ok=True)

    env = os.environ.copy()
    env.pop("DEBUG", None)
    env["OBJCACHE"] = ""

    if not args.skip_build:
        run(["../configure", "--xlen=32", f"--tooldir={build / 'tools'}"], cwd=build, env=env)
        run(["make", "-C", "hw/unittest/cp_core"], cwd=build, env=env)

    binary = build / "hw/unittest/cp_core/cp_core"
    rows: list[dict[str, object]] = []
    for workload, commands, _desc in WORKLOADS:
        cmd = [str(binary), f"--workload={workload}", f"--commands={commands}", "--quiet"]
        proc = run(cmd, cwd=build, env=env)
        log = out_dir / f"{workload}.log"
        log.write_text(proc.stdout + proc.stderr, encoding="utf-8")
        rows.append(parse_perf(proc.stdout))

    write_csv(out_dir / "baseline_metrics.csv", rows)
    (out_dir / "baseline_metrics.json").write_text(
        json.dumps(rows, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    write_svg(out_dir / "cpc_chart.svg", rows)
    write_unsupported(out_dir / "unsupported_workloads.md")
    write_summary(out_dir / "perf_summary.md", rows, repo)

    print(f"wrote {out_dir / 'baseline_metrics.csv'}")
    print(f"wrote {out_dir / 'perf_summary.md'}")


if __name__ == "__main__":
    main()
