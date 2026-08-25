# 实验4～11统一回归、PPA与数据整理总结

## 1. 本文定位

本文是实验4～11的统一状态入口，记录最新源码上的功能回归、完整CP面积代理、实验完成边界和数据保留规则。更新时间为2026年8月25日。

统一功能入口：

```text
results/exp04_11_summary/run_regression.sh
```

统一PPA入口：

```text
results/exp04_11_summary/run_ppa.sh
```

机器可读结果：

```text
results/exp04_11_summary/regression_status.csv
results/exp04_11_summary/combined_ppa_metrics.csv
results/exp09/ppa_metrics.csv
results/exp11/ppa_metrics.csv
```

## 2. 实验状态

| 实验 | 主题 | 最新状态 | 默认策略 |
|---|---|---|---|
| 4 | NOP Fast Path | 功能、局部性能和PPA完成 | 默认关闭，局部Fmax代理下降6.43% |
| 5 | Command Packing | 正确性和流量收益完成 | Runtime启用，1000条命令流量下降66.60% |
| 6 | Fetch Prefetch | 延迟扫描、回绕和PPA完成 | Depth=1默认，Depth=2实验启用 |
| 7 | Priority Arbitration | 功能、公平性和局部PPA完成 | 与Aging配套使用 |
| 8 | Aging | 防饥饿、等待上界和局部PPA完成 | 默认关闭，局部面积成本较高 |
| 9 | EVENT_WAIT Fairness | 功能、完整CP PPA完成 | 默认关闭，等待XRT验证 |
| 10 | QMD Launch | `DEFERRED`，本阶段未实施 | 不能计入已完成实验 |
| 11 | Multi-Queue | RTL、Runtime、并行性和完整CP PPA完成 | XRT真板仍为门禁 |

## 3. 最新统一回归结果

执行：

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_regression.sh
```

结果：

- 实验4 Fast Path基线/开启：PASS。
- 实验5 Unpack/Packing边界：PASS。
- 实验6 Prefetch Depth 1/2：PASS。
- 实验7 Priority、实验8 Aging、实验9 EVENT_WAIT公平性：PASS。
- 实验11四队列RTL竞争与跨资源并行：PASS。
- Runtime Stub编译与软件Queue到4个硬件QID映射：PASS。
- Fast Path、Packing、Prefetch、Priority、Aging、EVENT公平性组合1000命令：`final_seqnum=1000`，无丢失、无重复。
- SimX `demo`：PASS。
- RTL `demo`、`sgemm -n16`：PASS。
- XRT：`BLOCKED`，当前环境缺少XRT工具、平台和xclbin。

完整状态及逐项日志位于`results/exp04_11_summary/regression_status.csv`和`logs/`。

## 4. 关键性能结论

| 实验 | 关键结果 | 解释 |
|---|---|---|
| 4 | NOP由3降至2 CPC，吞吐提升50%，CPC改善33.33% | 只针对简单命令执行路径 |
| 5 | 64000降至21376 Fetch Bytes，下降66.60% | DCR执行仍是瓶颈，因此总周期不变 |
| 6 | 100-cycle AXI延迟下吞吐提升99.76% | 两条有序请求在途，接近隐藏一半等待 |
| 7 | 高优先级可持续优先服务 | 单独使用会导致低优先级饥饿 |
| 8 | P0最大等待限制为64周期 | 以计数器和比较逻辑换取有界等待 |
| 9 | SIGNAL尾延迟下降82.4%～89.9% | WAIT失败后释放EVENT资源并重竞标 |
| 11 | 串行110周期，并行43周期，加速2.558倍 | DMA、DCR、EVENT、KMU实现真实重叠 |

## 5. 最新完整CP PPA

PPA使用同一个`VX_cp_core_top`、Yosys 0.40、Berkeley ABC 1.01和NanGate typical库。FPGA数据是`xc7`逻辑映射代理，ASIC数据是未布局标准单元面积；没有Vivado布局布线，不能据此签核Fmax。

### 5.1 实验9：EVENT公平性增量

固定四队列、Priority和Aging开启，只切换`ENABLE_EVENT_WAIT_FAIRNESS`：

| 指标 | Baseline | Fairness | 变化 |
|---|---:|---:|---:|
| FPGA estimated LCs | 11319 | 11406 | +0.77% |
| FPGA FDRE | 11406 | 11407 | +0.01% |
| ASIC cell area | 406978.138 µm² | 406066.556 µm² | -0.22% |

ASIC面积的轻微下降来自全顶层技术映射差异，应按“面积基本持平”解释，不能宣称公平机制节省面积。结合功能收益，实验9的面积风险较低；时序和真板行为仍待Vivado/XRT确认。

### 5.2 实验11：一队列扩展到四队列

固定Priority、Aging和EVENT公平性开启，只切换`NUM_QUEUES=1/4`：

| 指标 | 1 Queue | 4 Queues | 变化 | 每增加1Q平均增量 |
|---|---:|---:|---:|---:|
| FPGA estimated LCs | 6145 | 11406 | +85.61% | 1753.667 |
| FPGA FDRE | 7348 | 11407 | +55.24% | 1353 |
| ASIC cell area | 337524.474 µm² | 406066.556 µm² | +20.31% | 22847.361 µm² |

这组数据测量的是容量扩展成本，不是一个小开关的优化开销。每个额外QID复制Fetch、Engine、Ring状态和Completion上下文，因此面积不会保持不变；共享DMA、DCR、EVENT和KMU执行资源使面积增长明显低于4倍。

### 5.3 四队列Baseline与实验4～9全开启

| 指标 | Baseline | All Enabled | 变化 |
|---|---:|---:|---:|
| FPGA estimated LCs | 11596 | 11463 | -1.15% |
| FPGA FDRE | 11294 | 9379 | -16.96% |
| FPGA RAM32M | 22 | 366 | 映射增加344个 |
| FPGA RAM64M | 512 | 512 | 不变 |
| ASIC cell area | 404105.338 µm² | 423578.932 µm² | +4.82% |

FPGA LC和FDRE下降是部分状态被映射为RAM32M后的资源重分配，不代表所有优化零成本。跨技术比较应以“FPGA资源构成变化、ASIC面积增加4.82%”为结论。

## 6. 数据清理结果

已删除：

- 被本目录替代的`results/exp04_09_summary/`旧总汇。
- sv2v生成的`*_input.v`、`*_flat.v`和`sources.f`。
- Yosys中间JSON、mapped/syn Verilog和临时综合脚本。
- 未形成有效结论的旧Power空报告。
- 实验11重复构建日志、空configure日志和Python `__pycache__`。

保留：

- 每个实验的最终CSV和精简运行日志。
- 能解释关键状态机、回绕和公平性的VCD。
- PPA最终`stat`、STA和Yosys诊断报告。
- 所有可重新生成结果的脚本。

被删除的已跟踪文件在提交前仍可通过Git恢复；新脚本可以重新生成权威结果。

## 7. 尚未关闭的门禁

1. 实验10尚未实施，当前明确记为`DEFERRED`。
2. 缺少Vivado布局布线后的WNS、关键路径和Fmax。
3. 缺少XRT/FPGA真板下的Ring一致性、软件Queue到QID映射和并发吞吐。
4. SimX当前只报告一个硬件Queue，尚未建立多队列周期级模型。

因此当前可以表述为：

> 实验4～9与11已完成最新RTL/Runtime仿真回归和开源工具面积代理；实验10延期，Vivado时序和XRT真板验证待补。
