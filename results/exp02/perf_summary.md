# 实验2：CP 性能测量基础设施 Baseline

## 结果文件

- `results/exp02/baseline_metrics.csv`
- `results/exp02/baseline_metrics.json`
- `results/exp02/cpc_chart.svg`
- `results/exp02/unsupported_workloads.md`

## Baseline 汇总

| Workload | Commands | Cycles | CPC | Cmd/Cycle | Fetch CL | Fetch Bytes | Bytes/Command | Arb Wait | Completion Stall |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| B1 | 16 | 123 | 7.688 | 0.130081 | 6 | 384 | 24.000 | 0 | 16 |
| B2 | 16 | 171 | 10.688 | 0.093567 | 6 | 384 | 24.000 | 0 | 16 |
| B7 | 8 | 115 | 14.375 | 0.069565 | 2 | 128 | 16.000 | 0 | 8 |
| B8 | 19 | 150 | 7.895 | 0.126667 | 7 | 448 | 23.579 | 0 | 19 |
| B9 | 18 | 191 | 10.611 | 0.094241 | 6 | 384 | 21.333 | 0 | 18 |

## 初始瓶颈分解

| Workload | Fetch Wait | BID | WAIT_DONE | RETIRE | Completion Stall | 主要等待来源 |
|---|---:|---:|---:|---:|---:|---|
| B1 | 19.5% | 13.0% | 26.0% | 26.0% | 13.0% | DCR=32 cycles |
| B2 | 14.0% | 9.4% | 46.8% | 18.7% | 9.4% | DCR=80 cycles |
| B7 | 7.0% | 7.0% | 55.7% | 13.9% | 7.0% | KMU=64 cycles |
| B8 | 18.7% | 12.7% | 29.3% | 25.3% | 12.7% | DCR=36 cycles |
| B9 | 12.6% | 9.4% | 47.1% | 18.8% | 9.4% | KMU=48 cycles |

观察：单队列 baseline 下仲裁等待 `arb_wait_cycles` 为 0，说明当前瓶颈不是多队列争用；B2 的 DCR read 多了响应等待，CPC 高于 B1；B7/B9 的 KMU launch 等待占比明显，受 testbench 中固定 busy 周期影响。

## 遇到的问题

- 指导书称“9个Workload”，但表格实际列出 B0 到 B9 共 10 个 ID；本次按实际 ID 处理。
- B0 的 NOP 在 full ring 中与 unpack 的全零填充哨兵冲突，因此保留给 `cp_engine` 单元层，不纳入 full-ring baseline。
- B3/B4/B5/B6 需要完整 DMA/Event 外设模型；当前 full CP harness 只闭环了 host ring/completion、DCR 和 launch。
- 原 completion slot 放在 ring 附近容易和更长 microbenchmark ring 重叠；实验2 harness 使用 `MEM_BASE + 0x3000`。

## 如何复现

```bash
cd /home/houdong/vortex
python3 results/exp02/run_exp02.py
```

脚本内部会执行：

```bash
cd build
../configure --xlen=32 --tooldir=$PWD/tools
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core
./hw/unittest/cp_core/cp_core --workload=B1 --commands=16 --quiet
```
