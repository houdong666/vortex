#!/usr/bin/env python3

import csv
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
RESULTS = ROOT / "results" / "exp08"
METRIC_RE = re.compile(
    r"METRIC mode=(\w+) test=(\w+) queue=(\d+) requests=(\d+) "
    r"grants=(\d+) average_wait=([-\d.]+) max_wait=(\d+) pending_wait=(\d+)"
)


def run(command, cwd, env=None):
    completed = subprocess.run(
        command, cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True
    )
    return completed.stdout


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    run(["../configure", "--xlen=32", "--tooldir=/home/houdong/tool"], BUILD)

    # 三组配置使用完全相同的测试场景，只改变仲裁策略，避免对照变量混杂。
    env = os.environ.copy()
    env.pop("DEBUG", None)
    env["OBJCACHE"] = ""
    configs = (
        ("baseline", "0", "0"),
        ("priority", "1", "0"),
        ("aging", "1", "1"),
    )
    rows = []
    for mode, priority, aging in configs:
        run([
            "make", "-C", "hw/unittest/cp_arbiter", "clean", "all",
            f"PRIORITY_ARBITRATION={priority}",
            f"ARBITRATION_AGING={aging}"
        ], BUILD, env)
        output = run(["./hw/unittest/cp_arbiter/cp_arbiter"], BUILD, env)
        (RESULTS / f"{mode}.log").write_text(output, encoding="utf-8")
        if "status=PASS" not in output:
            raise RuntimeError(f"{mode} test did not report PASS")
        for match in METRIC_RE.finditer(output):
            rows.append(match.groups())

    with (RESULTS / "aging_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow([
            "mode", "test", "queue", "request_count", "grant_count",
            "average_wait", "max_wait", "pending_wait"
        ])
        writer.writerows(rows)

    print("实验8 Baseline/Priority/Aging 测试全部通过")
    print(f"结果目录：{RESULTS}")


if __name__ == "__main__":
    main()
