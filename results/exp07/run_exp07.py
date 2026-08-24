#!/usr/bin/env python3

import csv
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
RESULTS = ROOT / "results" / "exp07"
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

    env = os.environ.copy()
    env.pop("DEBUG", None)
    env["OBJCACHE"] = ""
    rows = []
    for mode, enabled in (("baseline", "0"), ("priority", "1")):
        run([
            "make", "-C", "hw/unittest/cp_arbiter", "clean", "all",
            f"PRIORITY_ARBITRATION={enabled}"
        ], BUILD, env)
        output = run(["./hw/unittest/cp_arbiter/cp_arbiter"], BUILD, env)
        (RESULTS / f"{mode}.log").write_text(output, encoding="utf-8")
        if "status=PASS" not in output:
            raise RuntimeError(f"{mode} test did not report PASS")
        for match in METRIC_RE.finditer(output):
            rows.append(match.groups())

    with (RESULTS / "grant_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "mode", "test", "queue", "request_count", "grant_count",
            "average_wait", "max_wait", "pending_wait"
        ])
        writer.writerows(rows)

    print("实验7 Baseline/Priority 测试全部通过")
    print(f"结果目录：{RESULTS}")


if __name__ == "__main__":
    main()
