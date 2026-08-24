#!/usr/bin/env python3

import csv
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
RESULTS = ROOT / "results" / "exp09"
METRIC = re.compile(
    r"EVENT_FAIRNESS mode=(\w+) poll_count=(\d+) busy_cycles=(\d+) "
    r"q0_latency=(\d+) q1_latency=(\d+) q2_latency=(\d+) q3_latency=(\d+) "
    r"retry_count=(\d+) lost=(\d+) early_retire=(\d+) duplicate=(\d+) status=(\w+)"
)


def run(command, cwd, env):
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            check=True)
    return result.stdout


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.pop("DEBUG", None)
    env["OBJCACHE"] = ""
    rows = []
    for mode, enabled in (("baseline", "0"), ("fairness", "1")):
        run(["make", "-C", "hw/unittest/cp_event_fairness", "clean", "all",
             f"EVENT_WAIT_FAIRNESS={enabled}"], BUILD, env)
        output = run(["./hw/unittest/cp_event_fairness/cp_event_fairness"], BUILD, env)
        (RESULTS / f"{mode}.log").write_text(output, encoding="utf-8")
        match = METRIC.search(output)
        if not match or match.group(12) != "PASS":
            raise RuntimeError(f"{mode} 未通过")
        rows.append(match.groups())

    # CSV 保留原始周期数据，百分比结论在实验报告中由同一组数据计算。
    with (RESULTS / "event_fairness_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["mode", "poll_count", "busy_cycles", "q0_latency",
                         "q1_latency", "q2_latency", "q3_latency", "retry_count",
                         "lost", "early_retire", "duplicate", "status"])
        writer.writerows(rows)
    print("实验9 Baseline/Fairness 对照测试全部通过")


if __name__ == "__main__":
    main()
