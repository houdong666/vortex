# 实验 9：EVENT_WAIT 公平性优化

## 1. 为什么需要本实验

多个命令队列共享一个 EVENT 执行单元。原始 `EVENT_WAIT` 获权后，如果事件条件不满足，会在 EVENT 单元内部反复读取同一计数器，直到条件成立。此时其他队列的 `EVENT_SIGNAL` 无法被单元接收，不仅增加跨队列尾延迟；如果 WAIT 等待的值需要另一个队列 SIGNAL 才能产生，还可能形成依赖死锁。

实验 7、8 解决的是“仲裁时选择谁”，实验 9 解决的是“获权后不能长期占用”。

## 2. 根因与优化结构

原始路径：

```text
Grant → Poll → 条件不满足 → 在 EVENT 单元内部继续 Poll
```

优化路径：

```text
Grant → Poll → 条件不满足 → retry → Release
      → Engine Backoff 一周期 → Re-BID
```

实现包含三个互相配合的修改：

1. EVENT 单元增加 `ready`，只有 `S_IDLE` 才允许仲裁器产生新授权，避免忙碌期间的伪授权和共享 `done` 错误唤醒。
2. 公平模式下，WAIT 比较失败进入 `S_RETRY`，产生 `retry` 而不是 `done`，随后释放 EVENT 单元。
3. 原队列 Engine 收到 `retry` 后进入 `S_EVENT_BACKOFF`，不退休、不推进 seqnum，退避一周期后重新竞标。

因此 SIGNAL 可以插入两次 WAIT Poll 之间，而 WAIT 仍只有在比较成功并收到 `done` 后才能退休。

## 3. 验证场景

四个真实 Engine 同时提交：

```text
Q0：EVENT_WAIT X >= 1
Q1：EVENT_SIGNAL Y = 1
Q2：EVENT_SIGNAL Z = 1
Q3：EVENT_SIGNAL W = 1
```

测试在第 100 周期将 X 改为 1。第 100 周期以前 Q0 绝不能退休；四条命令最终必须各退休一次。测试链路包含 Engine、4 路 Arbiter、EVENT Unit 和简化 AXI 事件内存。

## 4. 实验结果

| 指标 | 基线内部自旋 | Release/Backoff | 变化 |
|---|---:|---:|---:|
| Q0 WAIT 退休周期 | 104 | 105 | +1 周期 |
| Q1 SIGNAL 退休周期 | 109 | 11 | 降低 89.9% |
| Q2 SIGNAL 退休周期 | 114 | 16 | 降低 86.0% |
| Q3 SIGNAL 退休周期 | 119 | 21 | 降低 82.4% |
| WAIT Poll 次数 | 50 | 18 | 降低 64.0% |
| EVENT 忙碌周期 | 113 | 66 | 降低 41.6% |
| retry 次数 | 0 | 17 | 符合重竞标设计 |

优化后的三个 SIGNAL 都在 X 释放前完成，证明它们成功插入 WAIT 的轮询间隙。Q0 只增加 1 周期尾延迟，但避免了对其他队列约 100 周期的阻塞。

正确性结果：`lost=0`、`early_retire=0`、`duplicate=0`。Q0 在第 100 周期之前没有退休，条件满足后于第 105 周期正确完成。

原始数据见 `results/exp09/event_fairness_metrics.csv`，关键波形见 `results/exp09/event_wait_fairness.vcd`。

## 5. 回归结果

- `cp_event_fairness` Baseline/Fairness 对照均 PASS。
- `cp_engine` Smoke 与 NOP 回归 PASS。
- 启用 `EVENT_WAIT_FAIRNESS=1` 的完整 `cp_core` B1/100 命令回归 PASS。
- `final_seqnum=100`、`dropped_count=0`、`duplicate_count=0`。

## 6. 结论

实验 9 把长时间占用资源的 WAIT 转换为可抢占的单次 Poll。它显著降低无关 SIGNAL 的尾延迟，并消除“WAIT 占用 EVENT、SIGNAL 又负责满足 WAIT”的结构性死锁条件。代价是 WAIT 比较失败时增加一次 retry 和一个 Engine 退避周期；在本场景中最终 WAIT 只慢 1 周期。

逐步复现见 [`exp09_commands.md`](exp09_commands.md)。
