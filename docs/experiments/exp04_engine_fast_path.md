# 实验4：Engine Simple Command Fast Path

## 实施范围

本实验首版只覆盖 `cp_engine` Unit Test 层：

- `CMD_NOP` 在 `ENABLE_NOP_FAST_PATH=1` 时从 `S_IDLE` 直接进入 `S_RETIRE`。
- `S_DECODE` 保留，关闭参数或其他命令仍走原路径。
- `VX_cp_engine` 参数默认值为 `0`，避免未经 `cp_core/SimX` 联调就改变整机默认时序。
- `hw/unittest/cp_engine/VX_cp_engine_top.sv` 默认显式打开快路径；`NOP_FAST_PATH=0` 用于基线对照。

## 复现命令

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools

# Fast Path
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=1

# Baseline
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
```

波形：

```bash
mkdir -p /home/houdong/vortex/results/exp04

env OBJCACHE= make -C hw/unittest/cp_engine clean all DEBUG=1 NOP_FAST_PATH=1
VCD_FILE=/home/houdong/vortex/results/exp04/nop_fastpath.vcd \
  env OBJCACHE= make -C hw/unittest/cp_engine run DEBUG=1 \
  NOP_FAST_PATH=1 OPTS=--nop-count=100

env OBJCACHE= make -C hw/unittest/cp_engine clean all DEBUG=1 NOP_FAST_PATH=0
VCD_FILE=/home/houdong/vortex/results/exp04/nop_baseline.vcd \
  env OBJCACHE= make -C hw/unittest/cp_engine run DEBUG=1 \
  NOP_FAST_PATH=0 OPTS=--nop-count=100
```

完整运行日志：

- `results/exp04/fastpath.log`
- `results/exp04/baseline.log`

## 验证场景

| 场景 | 输入与配置 | 主要检查点 | 通过标准 |
|---|---|---|---|
| V1：NOP 基线状态机 | `NOP_FAST_PATH=0`，连续提交 NOP | `IDLE -> DECODE -> RETIRE`，每条命令只退役一次 | CPC=3，`retire_count=command_count`，无丢失或重复 |
| V2：NOP 快路径状态机 | `NOP_FAST_PATH=1`，连续提交 NOP | `IDLE -> RETIRE`，不进入 `DECODE` | CPC=2，`decode_cycles=0`，无丢失或重复 |
| V3：短/中/长压力 | N=100、1000、10000 | 规模扩大后计数和性能是否保持稳定 | 最终 `seqnum=N`，duplicate=0，dropped=0 |
| V4：资源分类 | LAUNCH、DCR_WRITE/READ、MEM_WRITE/READ/COPY、EVENT_SIGNAL/WAIT | KMU、DCR、DMA、EVENT bid 只在对应资源上有效 | 资源选择与 opcode 一致，命令均正确完成 |
| V5：无资源命令 | NOP、FENCE | 不应错误申请 KMU/DMA/DCR/EVENT | 四类 bid 均不误触发，命令正常退役 |
| V6：Profile 传播 | 带 `F_PROFILE` 的 NOP 和 LAUNCH | submit/start/end 事件以及 `profile_slot` | 事件脉冲与标志一致，profile 地址保持不变 |
| V7：Priority 传播 | `state_prio=3` 的 LAUNCH | KMU bid 上的优先级 | `bid_kmu_valid=1` 且 `bid_kmu_prio=3` |
| V8：默认关闭 | `VX_cp_engine` 默认参数 | 未显式开启时不改变整机行为 | `ENABLE_NOP_FAST_PATH=0`，旧路径仍可运行 |

V1～V3 分别在 Baseline 和 Fast Path 配置下运行；V4～V7 构成 13 条命令的 smoke 回归。功能通过之外，实验还用共同约束下的 FPGA/ASIC 综合比较面积和 Fmax，作为是否默认集成的决策场景。

## 正确性与性能结果

测试日期：2026年8月21日。两种配置均通过原有资源分类、profile、priority smoke 测试。

| 配置 | N | command_count | retire_count | final_seqnum | duplicate | dropped | Total Cycles | CPC | Cmd/Cycle | DECODE cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 100 | 100 | 100 | 100 | 0 | 0 | 300 | 3.000000 | 0.333333 | 100 |
| Baseline | 1000 | 1000 | 1000 | 1000 | 0 | 0 | 3000 | 3.000000 | 0.333333 | 1000 |
| Baseline | 10000 | 10000 | 10000 | 10000 | 0 | 0 | 30000 | 3.000000 | 0.333333 | 10000 |
| Fast Path | 100 | 100 | 100 | 100 | 0 | 0 | 200 | 2.000000 | 0.500000 | 0 |
| Fast Path | 1000 | 1000 | 1000 | 1000 | 0 | 0 | 2000 | 2.000000 | 0.500000 | 0 |
| Fast Path | 10000 | 10000 | 10000 | 10000 | 0 | 0 | 20000 | 2.000000 | 0.500000 | 0 |

按指导书定义：

```text
Improvement = (3.0 - 2.0) / 3.0 × 100% = 33.33%
```

两组测试的 `retire_count`、最终 `seqnum`、duplicate retire 和 dropped command 均一致，未观察到 command regression。

## FSM 波形

- `results/exp04/nop_baseline.vcd`
  - `engine_fsm` 在每条 NOP 上表现为 `IDLE(0) -> DECODE(1) -> RETIRE(4)`。
- `results/exp04/nop_fastpath.vcd`
  - `engine_fsm` 在每条 NOP 上表现为 `IDLE(0) -> RETIRE(4)`。
- 两份波形均包含 `cmd_in_ready`、`retire_evt`、`retire_seqnum`、`seqnum_out` 和 `nop_fast_path`。

## PPA 初步结果

使用仓库本地安装的 Yosys 0.9、Berkeley ABC、sv2v 和 OpenSTA 2.7.0。FPGA 统计采用 Yosys `synth_xilinx -family xc7` 的逻辑单元估算；ASIC 面积和时序采用仓库自带 NanGate 15 nm typical Liberty、共同的 400 MHz 映射目标、2% clock uncertainty 和 5% I/O delay。它们是未布局布线的比较代理，不等同于 Vivado 的器件结果。

| 项目 | Baseline | Fast Path | 变化 |
|---|---:|---:|---:|
| FPGA estimated LCs | 211 | 220 | +4.27% |
| FPGA FDRE | 359 | 359 | 0.00% |
| ASIC cell area (um^2) | 2703.092 | 2698.304 | -0.18% |
| Reg-to-reg arrival (ns) | 2.459 | 2.644 | +7.52% |
| Fmax proxy (MHz) | 389.35 | 364.30 | -6.43% |

Fmax 按关键寄存器路径倒算：`period_min = (arrival + setup) / (1 - uncertainty)`。Baseline setup 为 0.058 ns，Fast Path setup 为 0.046 ns。完整报告位于 `results/exp04/ppa/{baseline,fastpath}/asic400_reports/`，FPGA 日志为对应目录下的 `fpga_yosys.log`。

## 结论

**功能 Accept，默认集成 Reject**：NOP 固定路径由 3 CPC 降至 2 CPC，改善 33.33%，且 100/1000/10000 条命令均保持 retire/seqnum 语义正确；但当前 Fmax 代理下降 6.43%，超过指导书的 2% 重新评估线。因此保留实验代码和测试，`VX_cp_engine` 参数继续默认关闭，不把快路径作为整机默认配置。

完整的工具安装、测试、波形和综合命令见 [`exp04_commands.md`](exp04_commands.md)，最新组合回归与完整CP PPA边界见 [`exp04_11_unified_summary.md`](exp04_11_unified_summary.md)。
