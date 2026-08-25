#!/usr/bin/env python3
"""运行实验11三种仲裁模式，并整理竞争、并行和正确性结果。"""

from __future__ import annotations

import csv
import os
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
UNIT = BUILD / "hw/unittest/cp_multi_queue"
OUT = ROOT / "results/exp11"


def run(command: list[str], cwd: pathlib.Path, log_name: str | None = None) -> str:
    env = os.environ.copy()
    # 本机未安装ccache；空值让Verilator直接调用C++编译器。
    env["OBJCACHE"] = ""
    env.pop("DEBUG", None)
    proc = subprocess.run(command, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log_name:
        (OUT / log_name).write_text(proc.stdout, encoding="utf-8")
    if proc.returncode:
        raise SystemExit(f"命令失败: {' '.join(command)}\n{proc.stdout}")
    return proc.stdout


def fields(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in line.split()[1:]:
        if "=" in item:
            key, value = item.split("=", 1)
            result[key] = value
    return result


def records(output: str, prefix: str) -> list[dict[str, str]]:
    return [fields(line) for line in output.splitlines()
            if line.startswith(prefix + " ")]


def build_mode(name: str, priority: int, aging: int) -> None:
    run(["make", "-C", "hw/unittest/cp_multi_queue", "DEBUG=", "clean", "all",
         f"PRIORITY_ARBITRATION={priority}", f"ARBITRATION_AGING={aging}"],
        BUILD, f"build_{name}.log")


def execute(scenario: str, log_name: str, timeline: pathlib.Path | None = None) -> str:
    command = [str(UNIT / "cp_multi_queue"), f"--scenario={scenario}", "--quiet"]
    if scenario == "same-dma":
        command.append("--commands=4")
    if timeline:
        command.append(f"--timeline={timeline}")
    return run(command, BUILD, log_name)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    run(["../configure", "--xlen=32", "--tooldir=/home/houdong/tool"],
        BUILD, "configure.log")

    contention_rows: list[dict[str, str]] = []
    regression_rows: list[dict[str, str]] = []
    modes = [
        ("round_robin", 0, 0),
        ("strict_priority", 1, 0),
        ("priority_aging", 1, 1),
    ]
    for mode, priority, aging in modes:
        build_mode(mode, priority, aging)
        output = execute("same-dma", f"same_dma_{mode}.log")
        result = records(output, "MQ_RESULT")[0]
        for queue in records(output, "MQ_QUEUE"):
            queue["total_cycles"] = result["total_cycles"]
            queue["fairness"] = result["fairness"]
            contention_rows.append(queue)
        regression_rows.append(result)

    # 并行度统一在Priority+Aging配置下测量，单项与并发使用完全相同的命令。
    isolated_cycles: dict[str, int] = {}
    for resource in ("dma", "dcr", "event", "kmu"):
        scenario = f"isolated-{resource}"
        output = execute(scenario, f"{scenario}.log")
        result = records(output, "MQ_RESULT")[0]
        isolated_cycles[resource] = int(result["total_cycles"])
        regression_rows.append(result)

    timeline = OUT / "multi_queue_timeline.csv"
    mixed_output = execute("mixed", "mixed.log", timeline)
    mixed_result = records(mixed_output, "MQ_RESULT")[0]
    regression_rows.append(mixed_result)
    serial = sum(isolated_cycles.values())
    parallel = int(mixed_result["total_cycles"])
    parallel_row = {
        "T_DMA": isolated_cycles["dma"],
        "T_DCR": isolated_cycles["dcr"],
        "T_EVT": isolated_cycles["event"],
        "T_KMU": isolated_cycles["kmu"],
        "T_serial": serial,
        "T_parallel": parallel,
        "max_isolated": max(isolated_cycles.values()),
        "speedup": f"{serial / parallel:.6f}",
        "parallel_over_max": f"{parallel / max(isolated_cycles.values()):.6f}",
        "status": "PASS",
    }

    with (OUT / "contention_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        columns = ["scenario", "mode", "queue", "priority", "commands", "grants",
                   "average_wait", "max_wait", "retire_cycle", "final_seqnum",
                   "total_cycles", "fairness"]
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(contention_rows)

    with (OUT / "parallelism_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(parallel_row))
        writer.writeheader()
        writer.writerow(parallel_row)

    with (OUT / "regression_summary.csv").open("w", newline="", encoding="utf-8") as f:
        columns = ["scenario", "mode", "active_queues", "total_commands",
                   "total_cycles", "fairness", "dropped", "duplicate",
                   "dma_ok", "event_ok", "status"]
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(regression_rows)

    print(f"实验11完成: T_serial={serial}, T_parallel={parallel}, "
          f"speedup={serial / parallel:.3f}x")


if __name__ == "__main__":
    main()
