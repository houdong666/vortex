# CP优化实验文档索引

本目录按“实验原理报告 + 逐步复现命令 + 统一状态”组织。第一次阅读建议先看统一总结，再进入单项实验。

## 统一入口

- [实验4～11统一回归、PPA与数据整理总结](exp04_11_unified_summary.md)
- [CP优化实验指导书](../../Vortex_v3.0_CP_优化实验指导书.md)

统一执行命令：

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_regression.sh
results/exp04_11_summary/run_ppa.sh
```

## 单项实验

| 实验 | 原理与结果 | 复现命令 | 状态 |
|---|---|---|---|
| 3 DMA正确性 | [报告](exp03_dma_ring_conflict.md) | 报告内命令 | 完成 |
| 4 Fast Path | [报告](exp04_engine_fast_path.md) | [命令](exp04_commands.md) | 完成，默认关闭 |
| 5 Packing | [报告](exp05_command_packing.md) | [命令](exp05_commands.md) | 完成 |
| 6 Prefetch | [报告](exp06_fetch_prefetch.md) | [命令](exp06_commands.md) | 完成，Depth=1默认 |
| 7 Priority | [报告](exp07_priority_arbitration.md) | [命令](exp07_commands.md) | 完成，与Aging配套 |
| 8 Aging | [报告](exp08_aging.md) | [命令](exp08_commands.md) | 完成，默认关闭 |
| 9 EVENT_WAIT | [报告](exp09_event_wait_fairness.md) | [命令](exp09_commands.md) | 完成，XRT待补 |
| 10 QMD | 指导书实验10章节 | 尚无 | 延期，未完成 |
| 11 Multi-Queue | [报告](exp11_multi_queue.md) | [RTL命令](exp11_commands.md) / [Runtime命令](exp11_runtime_commands.md) | RTL/Runtime完成，XRT待补 |

## 结果目录约定

```text
results/expNN/*.csv       最终机器可读指标
results/expNN/*.log       精简功能输出
results/expNN/*.vcd       能解释关键机制的波形
results/expNN/ppa_metrics.csv  单项PPA摘要
results/exp04_11_summary/ 最新统一状态、日志与完整CP PPA
```

不再保存sv2v临时网表、Yosys中间JSON、mapped/syn Verilog、空Power报告或Python缓存。需要时由对应脚本重新生成。

## 当前完成边界

- 实验4～9和11的最新功能回归均通过。
- 实验9与11已有完整CP开源工具面积代理。
- 实验10明确延期。
- Vivado布局布线时序和XRT真板验证尚未完成。
