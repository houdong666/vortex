# 实验7：Priority-Aware Arbitration

## 1. 实验目标

原有 CP 队列状态和 Engine Bid 已经能携带 2 位优先级，但原仲裁器忽略该字段，所有请求只按 Round Robin 选择。本实验实现：

```text
Priority First + Round Robin Within Same Priority
```

即先找出当前请求中的最高优先级，再只在该优先级候选者之间轮询。

## 2. RTL 实现

修改文件：

- `hw/rtl/cp/VX_cp_arbiter.sv`
- `hw/rtl/cp/VX_cp_core.sv`

仲裁分为三步：

1. 扫描所有 `bid_valid` 请求，计算 `highest_priority`。
2. 生成 `eligible` 掩码，只保留最高优先级请求。
3. 从 `rr_pointer` 开始环形扫描 `eligible`，选出第一个请求者，授权后把指针移到获胜者之后。

`VX_cp_core` 的 KMU、DMA、DCR 和 EVENT 四个仲裁器共用参数 `ENABLE_PRIORITY_ARBITRATION`。考虑到严格优先级会导致低优先级饥饿，该参数默认为 `0`；实验7单元测试显式设为 `1`。

## 3. 验证场景

| 测试 | 优先级和请求 | 期望 | 结果 |
|---|---|---|---|
| Test A | Q0～Q3 均为 P2，持续请求 400 周期 | Q0、Q1、Q2、Q3 循环 | 每队列 100 次，PASS |
| Test B | Q0=P0，Q1=P3，持续请求 128 周期 | Q1 始终优先 | Q1=128，Q0=0，PASS |
| Test C | Q0=P0，Q1=P3，Q2=P3，Q3=P1 | Q1、Q2 交替 | Q1=64，Q2=64，PASS |
| 空载 | 无请求 | 无授权 | PASS |
| 单请求 | 只有 Q2 有效 | Q2 每周期获权 | PASS |

同优先级公平性计算：

```text
Fairness Error = (max(grant_count) - min(grant_count)) / total_grants
               = (100 - 100) / 400
               = 0%
```

低于 2% 的实验验收线。

## 4. Baseline RR 与 Priority RR 对比

| 场景 | 模式 | 高优先级Grant | 高优先级平均等待 | 低优先级Grant | 低优先级平均等待 |
|---|---|---:|---:|---:|---:|
| Test B, 128周期 | Baseline RR | 64 | 1.000 | 64 | 0.984 |
| Test B, 128周期 | Priority RR | 128 | 0.000 | 0 | 未获授权 |

Priority RR 将 P3 队列的服务间隔从隔一周期一次缩短为每周期一次，但 P0 队列在持续 P3 竞争下完全饥饿。这是严格优先级的预期行为，不是测试失败，但说明实验8的 Aging 是默认集成前的必要条件。

## 5. 回归结果

- `cp_arbiter` Baseline/Priority Test A/B/C：PASS。
- `cp_engine` 13 条命令 Smoke：PASS，KMU/DMA/DCR/EVENT 分类和优先级传递正确。
- `cp_core` 完整 RTL 编译：PASS。
- `cp_core` 100 条 Packed DCR_WRITE：PASS，`seqnum=100`，无丢失或重复。

关键波形：`results/exp07/priority_arbiter.vcd`，包含 `bid_valid`、`bid_priority`、`rr_pointer`、`selected_queue` 和 `bid_grant`。

## 6. PPA 代理结果

使用 Yosys 0.9 + Berkeley ABC 和 NanGate 15 nm typical Liberty，两种配置采用相同 400 MHz、2% clock uncertainty 和 5% I/O delay 约束。结果是单个 4 路仲裁器的未布局布线比较代理。

| 指标 | Baseline RR | Priority RR | 变化 |
|---|---:|---:|---:|
| FPGA estimated LCs | 73 | 75 | +2.74% |
| FPGA FDRE | 2 | 2 | 0% |
| ASIC cell area | 52.136 um² | 97.622 um² | +87.25% |
| 最坏 max path arrival | 0.613 ns | 0.787 ns | +28.38% |
| 400 MHz setup WNS | 0.000 ns | 0.000 ns | 两者均 MET |

ASIC 面积增幅看起来较大，但绝对增量只有 45.486 um²，因为仲裁器本身很小。最终是否集成应以完整 `cp_core` 综合和 Aging 组合结果为准。

## 7. 结论

实验7完成了 Priority First + Same-Priority RR，证明高优先级队列能获得更低的服务等待，同优先级公平性误差为 0%。

当前决策为：**功能 Accept，默认集成暂缓**。原因是 Strict Priority 已在 Test B/C 中证明可能使低优先级队列饥饿，且仍需要完整 CP PPA。下一步是实验8 Aging，为等待过久的队列增加优先级补偿。

