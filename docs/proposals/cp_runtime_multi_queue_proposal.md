# CP Runtime 多硬件队列接入方案

## 背景

CP RTL 已经提供多个独立 Ring、Head、Tail、Completion、Seqnum 和 Priority
寄存器组，但公共 Runtime 只有一套 Device 级 Ring 状态。多个软件 `Queue`
虽然各自拥有工作线程，最终仍会把命令提交到硬件 Q0，无法端到端使用优先级、
Aging 和多资源并行能力。

## 目标

1. Runtime 从 `CP_DEV_CAPS.NUM_QUEUES` 发现硬件队列数量。
2. 每个软件 `Queue` 在生命周期内独占一个硬件 QID。
3. 每个 QID 拥有独立 Ring、Head、Completion、Tail、Seqnum、Packing 和 Batch 状态。
4. 软件优先级写入对应 `Q_CONTROL.priority`。
5. 保持旧接口和内部 Device 操作默认使用 Q0。

## 关键约束

- 每队列锁只保护该 Ring 的构建、门铃和完成轮询；MMIO 回调仍需设备级短锁，
  避免多个 Host 线程并发推进非线程安全的仿真后端。
- DCR 是 GPU 全局状态。RTL 尚未声明 QMD 支持时，一组 DCR 配置和随后的
  LAUNCH 必须由设备级配置锁保护，不能被其他队列的 DCR 命令插入。
- 队列销毁前先排空工作线程。QID 复用时延续单调递增的 Tail/Seqnum，避免依赖
  当前尚未接入 CPE 的 `Q_CONTROL.reset` 脉冲。
- SimX 当前能力字只声明一个队列。本改动不虚构多队列 SimX 时序；多队列功能
  验证先使用完整 CP Verilator 测试，最终集成以 XRT/FPGA 为准。

## 非目标

- 不改变公开 Queue API，不允许应用直接指定 QID。
- 不实现软件 Queue 超量时在硬件 QID 间的时分复用。
- 不在本阶段重新启用设备侧 `EVENT_WAIT/SIGNAL`；事件内存的生命周期和跨队列
  死锁恢复需要单独设计。

## 验证

1. 编译公共 Runtime 及各可用后端。
2. 回归实验 7～9 的仲裁、Aging、EVENT_WAIT 测试。
3. 回归实验 11 的四队列同资源竞争和跨资源并行测试。
4. 在具备四队列配置的 XRT 平台上验证软件 Queue 到 QID 的端到端映射；若当前
   环境没有 FPGA/XRT，则明确记录为硬件环境门禁，而不把 Verilator 结果冒充 XRT。
