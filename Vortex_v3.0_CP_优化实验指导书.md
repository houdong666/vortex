# Vortex v3.0 Command Processor（CP）优化实验指导书（完整版）
## 目录

- [Vortex v3.0 Command Processor（CP）优化实验指导书（完整版）](#vortex-v30-command-processorcp优化实验指导书完整版)
  - [目录](#目录)
  - [1. 实验概述与研究目标](#1-实验概述与研究目标)
  - [2. 源码基线与环境配置](#2-源码基线与环境配置)
    - [2.1 固定基线](#21-固定基线)
    - [2.2 编译与单元测试环境](#22-编译与单元测试环境)
    - [2.3 现有CP单元测试清单](#23-现有cp单元测试清单)
  - [3. CP 微架构与关键RTL文件](#3-cp-微架构与关键rtl文件)
    - [3.1 整体数据流](#31-整体数据流)
    - [3.2 重点研究的RTL文件清单](#32-重点研究的rtl文件清单)
  - [4. CP 当前关键微架构特征](#4-cp-当前关键微架构特征)
    - [4.1 Fetch（单笔无预取）](#41-fetch单笔无预取)
    - [4.2 Unpack（零填充为结束标记）](#42-unpack零填充为结束标记)
    - [4.3 Engine 当前状态机](#43-engine-当前状态机)
    - [4.4 Arbiter（Round Robin，忽视优先级）](#44-arbiterround-robin忽视优先级)
  - [5. 实验总体路线与难度分层](#5-实验总体路线与难度分层)
  - [6. 详细实验步骤（实验0 ~ 实验12）](#6-详细实验步骤实验0--实验12)
    - [实验0：Baseline 建立](#实验0baseline-建立)
    - [实验1：CP 完整数据流与波形实验（不修改RTL）](#实验1cp-完整数据流与波形实验不修改rtl)
    - [实验2：CP 性能测量基础设施](#实验2cp-性能测量基础设施)
    - [实验3：DMA Byte-Exact Correctness（正确性修复）](#实验3dma-byte-exact-correctness正确性修复)
    - [实验4：Engine Simple Command Fast Path](#实验4engine-simple-command-fast-path)
    - [实验5：Command Packing](#实验5command-packing)
    - [实验6：Fetch Prefetch](#实验6fetch-prefetch)
    - [实验7：Priority-Aware Arbitration](#实验7priority-aware-arbitration)
    - [实验8：Aging 防饥饿机制](#实验8aging-防饥饿机制)
    - [实验9：EVENT\_WAIT Fairness](#实验9event_wait-fairness)
    - [实验10：QMD-Style Kernel Launch（高级）](#实验10qmd-style-kernel-launch高级)
    - [实验11：Multi-Queue（高级）](#实验11multi-queue高级)
    - [实验12：最终综合与PPA评估](#实验12最终综合与ppa评估)
  - [6.1 实验可交付成果总览](#61-实验可交付成果总览)
  - [7. 性能度量核心公式与指标体系](#7-性能度量核心公式与指标体系)
  - [8. 全局验收标准（功能/性能/时序/面积）](#8-全局验收标准功能性能时序面积)
  - [9. GitHub 项目管理与协作规范（完整版）](#9-github-项目管理与协作规范完整版)
    - [9.1 分支与标签策略](#91-分支与标签策略)
    - [9.2 Issue与里程碑（Milestones）](#92-issue与里程碑milestones)
    - [9.3 Pull Request（PR）流程（强制执行）](#93-pull-requestpr流程强制执行)
    - [9.4 CI/CD 自动化集成（GitHub Actions）](#94-cicd-自动化集成github-actions)
    - [9.5 项目看板（Projects）](#95-项目看板projects)
    - [9.6 文档与代码注释规范](#96-文档与代码注释规范)
  - [10. 推荐时间安排与最终报告结构](#10-推荐时间安排与最终报告结构)
    - [10.1 12周时间线（供参考）](#101-12周时间线供参考)
    - [10.2 最终实验报告结构（建议16章）](#102-最终实验报告结构建议16章)
  - [项目核心思想总结](#项目核心思想总结)

---
## 1. 实验概述与研究目标

本实验不是要求直接“大改 Vortex GPU”，而是围绕 Vortex v3.0 中新增的 Command Processor（CP）建立一套完整的：

**源码分析 → Baseline 建立 → 性能测量 → 瓶颈定位 → RTL 优化 → 功能验证 → 性能验证 → 综合评估**

实验流程。

**最终目标不是简单得到“修改后的RTL”，而是回答以下8个工程问题：**

1. Vortex CP 当前的命令执行路径是什么？
2. 一条命令从 Host Ring 到最终退休分别经过哪些模块？
3. CP 当前的性能瓶颈究竟在哪里？
4. 哪些优化真正提升吞吐量？
5. 哪些优化只是增加 RTL 复杂度，却没有实际收益？
6. 优化后是否仍然保证命令不丢失、不重复、不乱序？
7. 性能提升是否是以 Fmax 或面积明显下降为代价？
8. 不同优化之间是否能够叠加？

---
## 2. 源码基线与环境配置
### 2.1 固定基线
```text
Vortex Version:     VORTEX_VERSION=3.0
Source snapshot:    d76b7f24e658867ab57e3942d7c648c3e6af072d
```
本机实际完成实验1/实验2时的源码节点为：
```text
Git HEAD:           21b94dad9ed985abf157d25db571af20b9ff21ea
Dirty changes:      hw/unittest/cp_core/main.cpp 扩展为 DCR/Launch microbenchmark + 性能 monitor
                    hw/unittest/cp_core/VX_cp_core_top.sv 增加 unittest-only debug taps
Experiment output:  results/exp01/, results/exp02/
```
若课程或项目要求严格固定在 `d76b7f24e658867ab57e3942d7c648c3e6af072d`，需要先切回该节点再按本文复现实验；否则本文后续“仓库实测说明”以 `21b94dad9ed985abf157d25db571af20b9ff21ea` 为准。

整个实验过程中必须保留原始版本。建议建立：
```bash
git branch cp-baseline    # 永不修改
git branch cp-opt         # 所有优化在此进行
git tag cp-exp0-source-baseline cp-baseline
git push origin cp-baseline cp-opt cp-exp0-source-baseline
git branch --set-upstream-to=origin/cp-opt cp-opt
git branch --set-upstream-to=origin/cp-baseline cp-baseline
```
每完成一个优化建立一个独立 commit（命名示例）：
```text
cp-opt-00-baseline
cp-opt-01-counter
cp-opt-02-dma-fix
cp-opt-03-fastpath
cp-opt-04-packing
cp-opt-05-prefetch
cp-opt-06-priority
cp-opt-07-aging
...
```
**禁止**同时修改多个优化点后再一起测试。
### 2.2 编译与单元测试环境
```bash
cd vortex
mkdir build && cd build
../configure --xlen=32 --tooldir=$HOME/tools
./ci/toolchain_install.sh
make -s
```
若修改 `VX_config.toml` / `*.toml` / `Makefile`，需重新执行 `../configure`。

**已知环境注意事项**：
- 若环境变量中存在 `DEBUG=release`，Verilator 5.046 可能将 `release` 按 SystemVerilog 关键字解析，导致 `VX_trace_pkg.sv` 语法错误。运行 CP 单测时建议显式使用 `env -u DEBUG`，需要波形时使用 `DEBUG=0`。
- 若 `ccache` 在 `/run/user/<uid>/ccache-tmp` 报只读文件系统错误，使用 `CCACHE_DISABLE=1` 重新运行测试；这也有助于避免仿真构建被陈旧缓存影响。
- 若系统未安装 `ccache`，而 Verilator 生成的 Makefile 仍默认使用 `OBJCACHE ?= ccache`，会出现 `ccache: No such file or directory`。此时可在命令前设置 `OBJCACHE=`，直接使用 `g++` 编译，例如：`env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core run DEBUG=0`。

### 2.3 现有CP单元测试清单
```text
hw/unittest/cp_engine
hw/unittest/cp_unpack
hw/unittest/cp_axi_path
hw/unittest/cp_dma
hw/unittest/cp_dcr_proxy
hw/unittest/cp_arbiter
hw/unittest/cp_launch
hw/unittest/cp_axil_regfile
hw/unittest/cp_core
```
运行方式示例：
```bash
cd hw/unittest/cp_engine && make run
```

---
## 3. CP 微架构与关键RTL文件
### 3.1 整体数据流
```text
                         Host CPU
                            │
                            │ AXI4-Lite
                            ▼
                  ┌─────────────────────┐
                  │ VX_cp_axil_regfile  │
                  │ (Queue Registers)   │
                  └──────────┬──────────┘
                             │ q_state[q]
                             │
              ┌──────────────▼───────────────┐
              │        每个 Queue 一个 CPE    │
              │      VX_cp_fetch             │
Host Memory ──►       ↓                      │
              │      VX_cp_unpack            │
              │       ↓                      │
              │      VX_cp_engine            │
              └──────────────┬───────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
          KMU Arbiter     DMA Arbiter    DCR Arbiter
              ▼              ▼              ▼
         VX_cp_launch   VX_cp_dma    VX_cp_dcr_proxy
                             │
                        Event Arbiter
                             ▼
                     VX_cp_event_unit
                             ▼
                    VX_cp_completion
                             ▼
                    seqnum → Host
```
### 3.2 重点研究的RTL文件清单
| 文件 | 作用 |
|------|------|
| `hw/rtl/cp/VX_cp_pkg.sv` | CP参数、Opcode、命令长度定义 |
| `VX_cp_axil_regfile.sv` | Host寄存器控制接口 |
| `VX_cp_fetch.sv` | 从Ring Buffer读取64B Cache Line |
| `VX_cp_unpack.sv` | 从Cache Line解析单条命令 |
| `VX_cp_engine.sv` | CP单队列核心FSM |
| `VX_cp_arbiter.sv` | 多队列共享资源仲裁 |
| `VX_cp_dma.sv` | Host/Device数据搬运 |
| `VX_cp_dcr_proxy.sv` | DCR访问 |
| `VX_cp_launch.sv` | GPU/KMU Launch |
| `VX_cp_event_unit.sv` | EVENT_SIGNAL / EVENT_WAIT |
| `VX_cp_completion.sv` | 命令退休和seqnum更新 |
| `VX_cp_profiling.sv` | Profiling基础逻辑 |
| `VX_cp_core.sv` | CP顶层集成 |

---
## 4. CP 当前关键微架构特征
### 4.1 Fetch（单笔无预取）
当前状态机：`S_IDLE → S_ISSUE_AR → S_WAIT_R → S_EMIT → S_IDLE`  
特点：**64B Cache Line，Single Outstanding，No Prefetch**，Host Memory latency直接暴露。
### 4.2 Unpack（零填充为结束标记）
`offset`从0开始，每周期解析一条命令，`offset += cmd_size`。  
**关键警告**：`opcode=0, flags=0` 被识别为End-of-Line/Padding。  
因此**普通`CMD_NOP`与padding编码相同**：
- `CMD_NOP` 非常适合测试 `VX_cp_engine` 状态机；
- **但**不适合作为完整Ring→Fetch→Unpack链路的benchmark（因为会被误判为padding提前终止）。
### 4.3 Engine 当前状态机
```text
IDLE → DECODE → (若无需资源) → RETIRE
                → (若需资源) → BID → WAIT_DONE → RETIRE
```
资源类型：`RES_KMU`, `RES_DMA`, `RES_DCR`, `RES_EVT`。  
`CMD_NOP`和`CMD_FENCE`不参与共享资源仲裁，直达RETIRE。
### 4.4 Arbiter（Round Robin，忽视优先级）
现有4套仲裁器（KMU/DMA/DCR/EVENT），均使用`VX_cp_arbiter`。  
RTL虽已存在`bid_priority`输入，但**当前未真正参与仲裁决策**，因此Priority Scheduling是明确优化入口。

---
## 5. 实验总体路线与难度分层

最终希望实现并验证以下优化层次（箭头表示递进关系）：
```text
Baseline
   ↓
性能测量基础设施
   ↓
Correctness修复 (DMA)
   ↓
Engine Fast Path
   ↓
Command Packing
   ↓
Fetch Prefetch
   ↓
Priority Arbitration
   ↓
Priority + Aging
   ↓
EVENT_WAIT Fairness
   ↓
QMD Launch
   ↓
Multi Queue
```

**难度分层**：
- **第一层（必须完成）**：Baseline、波形理解、Performance Counter、DMA correctness、Engine Fast Path
- **第二层（核心优化）**：Command Packing、Fetch Prefetch、Priority Arbitration、Aging
- **第三层（高级架构）**：EVENT_WAIT Fairness、QMD、Multi Queue（适合毕设/研究项目）

---
## 6. 详细实验步骤（实验0 ~ 实验12）

> 以下完整保留了原始文档中所有79个技术细则，按实验编号重组，确保无遗漏。

---
### 实验0：Baseline 建立

**目的**：确保原始版本可编译、可运行、测试稳定，作为所有后续优化的比较基准。

**步骤**：
1. 依次运行所有CP单元测试：
   ```text
   cp_unpack, cp_engine, cp_arbiter, cp_dma,
   cp_dcr_proxy, cp_launch, cp_axil_regfile, cp_axi_path, cp_core
   ```
2. 记录每个测试的 **PASS/FAIL**、**运行周期数**、**仿真时间**。
3. 建立目录 `results/baseline/`，保存日志文件：
   ```text
   results/baseline/cp_engine.log
   results/baseline/cp_dma.log
   ...
   ```

**验收条件**：现有CP Unit Test **全部PASS**。若原版测试FAIL，先解决环境问题，**不允许开始RTL优化**。


**实验输出 / 可交付成果**

完成本实验后，至少应提交以下成果：

1. **Baseline 测试日志**
   ```text
   results/baseline/
   ├── cp_unpack.log
   ├── cp_engine.log
   ├── cp_arbiter.log
   ├── cp_dma.log
   ├── cp_dcr_proxy.log
   ├── cp_launch.log
   ├── cp_axil_regfile.log
   ├── cp_axi_path.log
   └── cp_core.log
   ```

2. **Baseline 汇总表**，至少记录：
   - 测试名称
   - PASS / FAIL
   - 仿真周期数
   - 仿真运行时间
   - 使用的编译器/仿真器版本

3. **实验环境记录**
   ```text
   Vortex version
   Git commit
   configure 参数
   XLEN
   NUM_CORES
   NUM_WARPS
   NUM_THREADS
   Cache 配置
   Verilator/VCS 版本
   ```

4. **固定的 Baseline Git 节点**
   - `cp-baseline` 分支或等价基线分支
   - 一个明确的 baseline commit / tag
   - GitHub 上已存在 `cp-baseline`、`cp-opt` 分支，并设置本地 upstream tracking

5. **Baseline 状态说明**
   - 一份 `baseline_summary.md` 或等价记录
   - 明确说明“哪些测试已通过、哪些测试存在原始问题”
   - 明确记录环境问题与规避方法（如 `DEBUG=release`、`ccache` 临时目录、组合单测无周期数等）

**本实验完成标志**

> 能够从一个固定 Git commit 重新构建工程，并复现完全相同的 CP Baseline 测试结果。

---
### 实验1：CP 完整数据流与波形实验（不修改RTL）

**目的**：确保自己真正看懂从Host到Retirement的完整路径。

**必须跟踪的信号清单**：

- **Fetch**：`head_r`, `state_in.tail`, `axi_m.arvalid/arready/araddr`, `axi_m.rvalid/rready`, `offset_r`, `cmd_out_valid/ready`
- **Engine**：`fsm`, `cmd_in_valid/ready`, `cur_cmd.hdr.opcode`, `cur_res`
- **Arbiter**：`bid_valid`, `bid_priority`, `bid_grant`
- **Completion**：`retire_evt`, `retire_ready`, `retire_seqnum`, `q_seqnum`

**本实验必须能够口述/写出**一条 `CMD_DCR_WRITE` 的完整数据流：
```text
CPU写Ring → TAIL doorbell → Fetch发现head<tail → 发AXI AR → 读取64B → Unpack
→ Engine DECODE → RES_DCR → BID → DCR arbiter grant → VX_cp_dcr_proxy → done
→ RETIRE → Completion → seqnum++
```
若这条链路不能清晰解释，**不进入性能优化阶段**。

**仓库实测说明（2026-08-20）**：

- 原有 `hw/unittest/cp_core/main.cpp` 的端到端用例使用 `CMD_NOP + F_PROFILE`。它能覆盖 `AXIL Regfile → Fetch → Unpack → Engine → Completion`，但不会触发 DCR 仲裁器和 `VX_cp_dcr_proxy`，因此与本实验要求的 `CMD_DCR_WRITE` 全链路不完全一致。
- 已将该 C++ testbench 的 ring payload 改为 `CMD_DCR_WRITE + F_PROFILE`，并增加 DCR 地址/数据断言：`dcr[0x123] = 0xdeadbeef`。该修改仅限 testbench，不修改 CP RTL。
- 本次中文实验报告、VCD、日志和标注时序图保存在：
  ```text
  results/exp01/cp_dataflow.md
  results/exp01/cp_core_dcr_write.vcd
  results/exp01/cp_core_dcr_write.log
  results/exp01/cp_core_dcr_write_timing.svg
  ```
- 复现命令：
  ```bash
  cd /home/houdong/vortex/build
  ../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools
  env -u DEBUG OBJCACHE= \
    VCD_FILE=/home/houdong/vortex/results/exp01/cp_core_dcr_write.vcd \
    make -C hw/unittest/cp_core clean run DEBUG=0 \
    > /home/houdong/vortex/results/exp01/cp_core_dcr_write.log 2>&1
  ```
- 预期日志包含：
  ```text
  PASSED - CP end-to-end: DCR_WRITE retired, dcr[0x123]=0xdeadbeef, seqnum=1 written to cmpl_addr
  ```


**实验输出 / 可交付成果**

1. **至少一份完整 CP 波形文件**
   - 推荐保存 `.fsdb`
   - 也可保存 `.vcd`

2. **一张带标注的 DCR_WRITE 时序波形截图**
   必须标出：
   ```text
   tail 更新
   AXI AR handshake
   AXI R response
   unpack 输出
   engine 接收命令
   BID
   GRANT
   DCR 完成
   RETIRE
   seqnum 更新
   ```

3. **一份 CP 数据流说明文档**
   推荐：
   ```text
   results/exp01/cp_dataflow.md
   ```

4. **一张 CP 模块数据流图**
   至少包含：
   ```text
   AXIL Regfile
   Fetch
   Unpack
   Engine
   Arbiter
   Resource
   Completion
   ```

5. **一份单命令周期事件表**

   | Cycle/Event | 事件 |
   |---|---|
   | T0 | Tail 可见 |
   | T1 | AR 发出 |
   | T2 | R 返回 |
   | T3 | Command 输出 |
   | T4 | Engine Decode |
   | T5 | Grant |
   | T6 | Resource Done |
   | T7 | Retire |
   | T8 | Seqnum 更新 |

**本实验完成标志**

> 能够不看源码，结合波形完整解释一条 `CMD_DCR_WRITE` 从 Ring 到 Completion 的执行过程。

---
### 实验2：CP 性能测量基础设施

**目的**：在testbench中建立性能计数器（第一阶段不修改CPU可见寄存器，仅在仿真层统计）。

**必须统计的指标（全量）**：

| 类别 | 指标 |
|------|------|
| 总周期 | `total_cycles` |
| 命令数 | `submitted_commands`, `retired_commands` |
| Engine状态周期 | `idle_cycles`, `decode_cycles`, `bid_cycles`, `wait_done_cycles`, `retire_cycles` |
| 资源等待 | `kmu_wait_cycles`, `dma_wait_cycles`, `dcr_wait_cycles`, `event_wait_cycles` |
| Fetch | `fetch_cache_lines`, `fetch_wait_cycles` |
| Completion | `completion_stall_cycles` |

**核心性能公式**（贯穿整个实验）：
- **Throughput** = `Retired Commands / Total CP Cycles` (cmd/cycle)
- **CPC** = `Total Cycles / Retired Commands`（越小越好）
- **Fetch Bytes** = `Fetch CL × 64B`
- **Bytes/Command** = `Fetch Bytes / Commands`（Packing关键指标）
- **Arbitration Latency** = `Tgrant - Tbid`
- **Queue Latency** = `Tstart - Tsubmit`
- **Execution Latency** = `Tretire - Tstart`
- **Total Latency** = `Tretire - Tsubmit`

**Baseline性能测试矩阵（B0～B9，共10个Workload ID）**：

| ID | Workload | 测试目的 |
|----|----------|----------|
| B0 | Engine NOP × N | Engine FSM固定开销 |
| B1 | DCR_WRITE × N | CP Frontend + DCR |
| B2 | DCR_READ × N | DCR Read |
| B3 | MEM_WRITE × N | DMA |
| B4 | MEM_READ × N | DMA |
| B5 | MEM_COPY × N | Device DMA |
| B6 | EVENT_SIGNAL × N | Event Unit |
| B7 | LAUNCH × N | KMU Launch |
| B8 | DCR×18 + LAUNCH | 模拟Kernel Launch |
| B9 | 混合命令 | 综合吞吐 |

> **特别注意**：B0（NOP）仅在`cp_engine`单元层测试。完整Ring benchmark请使用DCR_WRITE/LAUNCH/MEM_COPY等合法Ring命令。


**实验输出 / 可交付成果**

1. **性能计数器 Testbench / Monitor 代码**
   必须能够统计：
   ```text
   total_cycles
   submitted_commands
   retired_commands
   idle_cycles
   decode_cycles
   bid_cycles
   wait_done_cycles
   retire_cycles
   kmu_wait_cycles
   dma_wait_cycles
   dcr_wait_cycles
   event_wait_cycles
   fetch_cache_lines
   fetch_wait_cycles
   completion_stall_cycles
   ```

2. **Microbenchmark 测试框架**
   至少能够自动运行 B0～B9 中可实现的测试。

3. **机器可读性能结果**
   推荐保存：
   ```text
   results/exp02/baseline_metrics.csv
   ```
   或：
   ```text
   results/exp02/baseline_metrics.json
   ```

4. **Baseline 性能汇总表**

   至少包含：
   ```text
   Workload
   Commands
   Cycles
   CPC
   Cmd/Cycle
   Fetch CL
   Fetch Bytes
   Bytes/Command
   Arb Wait
   Completion Stall
   ```

5. **初始瓶颈分解报告**
   例如：
   ```text
   Engine state cycle breakdown
   Fetch wait ratio
   Arbitration wait ratio
   Completion stall ratio
   ```

6. **至少一张 Baseline 性能图**
   推荐：
   - `Cycles per Command`
   - 或 `Engine State Cycle Breakdown`

**本实验完成标志**

> 任意 CP 优化完成后，都能够使用同一套脚本自动生成优化前后的可比较性能数据。

**本机实测记录（2026-08-20）**

- 已实现的计数器位置：`hw/unittest/cp_core/main.cpp` 中的 `PerfCounters`，仅在 Verilator testbench 统计，不新增 CPU 可见寄存器。
- 已新增的观测端口：`hw/unittest/cp_core/VX_cp_core_top.sv` 中的 `dbg_*`，只属于 `cp_core` unittest wrapper，不修改通用 CP RTL 行为。
- Microbenchmark 脚本：`results/exp02/run_exp02.py`。
- 机器可读结果：
  ```text
  results/exp02/baseline_metrics.csv
  results/exp02/baseline_metrics.json
  ```
- 汇总报告与图：
  ```text
  results/exp02/perf_summary.md
  results/exp02/cpc_chart.svg
  results/exp02/unsupported_workloads.md
  ```

本次 full-ring baseline 已自动运行并通过以下可执行 workload：

| Workload | Commands | Cycles | CPC | Cmd/Cycle | Fetch CL | Fetch Bytes | Bytes/Command | Arb Wait | Completion Stall |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| B1 | 16 | 123 | 7.688 | 0.130081 | 6 | 384 | 24.000 | 0 | 16 |
| B2 | 16 | 171 | 10.688 | 0.093567 | 6 | 384 | 24.000 | 0 | 16 |
| B7 | 8 | 115 | 14.375 | 0.069565 | 2 | 128 | 16.000 | 0 | 8 |
| B8 | 19 | 150 | 7.895 | 0.126667 | 7 | 448 | 23.579 | 0 | 19 |
| B9 | 18 | 191 | 10.611 | 0.094241 | 6 | 384 | 21.333 | 0 | 18 |

遇到的问题与处理：
- 指导书原文写“9个Workload”，但表格实际为 B0～B9 共 10 个 ID；已在本节标题修正。
- B0 的 NOP 在 full ring 中与 `VX_cp_unpack` 的全零填充哨兵冲突，因此 B0 保留在 `cp_engine` 单元层测试，不纳入 full-ring baseline。
- B3/B4/B5/B6 依赖完整 DMA/Event 外设模型；当前 full CP harness 仅闭环 host ring/completion、DCR read/write 与 launch，未把这几项写成假通过。
- 更长 microbenchmark ring 可能覆盖早期 completion slot，因此实验2 harness 将 completion 地址移到 `MEM_BASE + 0x3000`。

复现命令：
```bash
cd /home/houdong/vortex
python3 results/exp02/run_exp02.py
```

脚本内部会执行：
```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core
./hw/unittest/cp_core/cp_core --workload=B1 --commands=16 --quiet
```

---
### 实验3：DMA Byte-Exact Correctness（正确性修复）

**背景**：原版`VX_cp_dma`把传输字节数向上取整到64B，但最后一个AXI Beat的`WSTRB`始终为全1，非64B倍数传输会把无效字节写入目标区域。**这是Correctness问题，不是Performance问题。**

**测试长度（必须全测）**：
```text
1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 65, 66,
127, 128, 129, 255, 256, 257, 4095, 4096, 4097
```

**Guard Region方法**：
1. 初始化Device memory为 `AA AA AA AA ...`
2. 在一个64B对齐的DMA目标地址中设置前后各100B Guard；实验示例仍为 `size=65`
3. 执行 `MEM_WRITE`
4. 验证：
   - Payload 区域完全等于Source
   - Payload 前100B保持 AA
   - Payload 后100B保持 AA

> 注意：当前`VX_cp_dma`按64B缓存行发起AXI Beat，源地址和目标地址必须按64B对齐。指导书原文把`offset=100`写成了DMA目标地址，这与当前RTL的地址合同不相符；本实验将“100”保留为Guard长度，用64B对齐的DMA基址隔离`WSTRB`尾Beat问题。未对齐地址拆分属于后续独立功能，不在本实验修复范围内。

**PASS标准**：Payload Match = 100%，Before/After Guard unchanged。哪怕1字节被错误覆盖即为FAIL。


**实验输出 / 可交付成果**

1. **DMA 边界测试 Testbench**
   必须覆盖本实验规定的全部传输长度。

2. **测试向量与结果日志**
   推荐：
   ```text
   results/exp03/dma_boundary_test.log
   ```

3. **Guard Region 检查结果**
   对每个 size 至少记录：
   ```text
   payload_match
   before_guard_match
   after_guard_match
   ```

4. **若确认存在 Bug：Bug 复现波形**
   必须能够看到：
   - 最后一个 AXI Beat
   - `wdata`
   - `wstrb`
   - 实际有效 byte 数
   - 越界 byte 的产生位置

5. **DMA Correctness RTL Patch**
   若 Baseline 确认存在问题，则提交修复后的 RTL commit。

6. **修复前 / 修复后对照结果**
   至少包含：
   - 原版失败 case
   - 修复后同一 case PASS
   - 全长度 Regression PASS

**实验3执行记录（2026年8月20日）**

修改文件：
```text
hw/rtl/cp/VX_cp_dma.sv
hw/unittest/cp_dma/main.cpp
```

测试台现在同时建模`axi_host`和`axi_dev`，执行真实的`CMD_MEM_WRITE`，并按每一位`WSTRB`更新Device memory。每个长度输出：
```text
DMA_RESULT size=<N> payload_match=<0|1> before_guard_match=<0|1> after_guard_match=<0|1> last_wstrb=<mask> write_beats=<count>
```

修复前基线：
- `size=1,2,3,4,7,8,15,16,31,32,63,65,66,127,129,255,257,4095,4097`均出现`after_guard_match=0`。
- `size=64,128,256,4096`通过，因为这些长度没有尾部无效字节。
- `size=65`的最后一个Beat仍发送`wstrb=0xffffffffffffffff`，实际写入128B，导致Payload之后的Guard被覆盖。

修复内容：
- 新增实际字节计数`bytes_rem`。
- 对最终Chunk的最终Beat按有效字节数生成低位连续`WSTRB`；例如`65B`的最后一个Beat为`0x1`，`4095B`为`0x7fffffffffffffff`。
- 保留中间Beat全1掩码，并对Chunk完成后的字节计数做饱和减法。

修复后结果：
- 2个原有`MEM_COPY`场景通过。
- 23个规定长度全部通过。
- 所有长度的`payload_match=1`、`before_guard_match=1`、`after_guard_match=1`。
- 目标区域之外意外写入字节数为0。

结果文件：
```text
results/exp03/dma_boundary_before.log
results/exp03/dma_boundary_after.log
results/exp03/dma_boundary_before.vcd
```

**补充说明（DMA 与 RingBuffer 冲突判定）**

- 本次实验3的`cp_dma`现场只建模了`axi_host`/`axi_dev`两个端口，没有实例化`cp_core`的命令ring，因此它只能证明DMA尾拍越界，不能直接证明“冲掉命令”。
- `CMD_MEM_WRITE` 的正常路径是 host→device；ringbuffer 走的是 host 侧取指链路。判断是否真正冲突时，不能只看目标地址数值是否落在`[Ring_Base, Ring_Base + 64KB)`，还要确认同一内存域和实际写入区间是否相交。
- 详细分析与现场总结见：[`docs/experiments/exp03_dma_ring_conflict.md`](docs/experiments/exp03_dma_ring_conflict.md)。

**遇到的问题与处理**

- 原有`cp_dma`测试台只有64B对齐的`MEM_COPY`，无法暴露尾部写越界；已扩展为双端口`MEM_WRITE`边界测试。
- 修复前切换测试版本时，Verilator严格警告模式会把未使用的临时掩码信号视为编译错误；已整理基线版本并成功生成仿真日志和VCD。
- 指导书原文的`offset=100`与当前DMA的64B地址对齐合同不一致；已在本节明确修正为“64B对齐DMA地址 + 前后各100B Guard”，避免把未对齐地址支持混入本实验。
- 先前对“是否一定冲掉命令”的判断需要更严格限定：当前实验3的现场未包含ringbuffer，不能把DMA越界直接等同于命令被覆盖。

**复现方法**

从仓库的`build`目录执行：
```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dma clean run
```

生成修复后VCD：
```bash
cd /home/houdong/vortex/build
VCD_FILE=/home/houdong/vortex/results/exp03/dma_boundary_after.vcd \
  env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dma clean run DEBUG=0
```

修复前对照日志和波形已保存在`results/exp03/`，无需修改RTL即可直接查看。

**本实验完成标志**

> 所有规定长度均实现 byte-exact 写入，目标区域之外 0 Byte 被意外修改。

---
### 实验4：Engine Simple Command Fast Path

**目的**：对不需要资源的命令（首版仅`CMD_NOP`）绕过`S_DECODE`，从`IDLE`直接进入`RETIRE`。

**原路径**：`IDLE → DECODE → RETIRE → IDLE`  
**优化路径**：`IDLE → RETIRE → IDLE`

**第一版范围**：仅在`cp_engine` Unit Test层对NOP实施，**不要**第一版就删除整个`S_DECODE`状态。

**正确性检查**：运行100、1000、10000条NOP，必须满足：
- `retire_count = command_count`
- `seqnum`最终正确
- 无duplicate retire
- 无command drop

**性能验收**：比较Baseline CPC vs FastPath CPC，计算：
```text
Improvement = (Baseline - New) / Baseline × 100%
```
建议NOP CPC明显下降，且无其他Command regression。综合后若Fmax下降 >2%，需重新评估是否保留。


**实验输出 / 可交付成果**

1. **Fast Path RTL Patch**
   主要修改文件应明确记录，例如：
   ```text
   hw/rtl/cp/VX_cp_engine.sv
   ```

2. **NOP 单元测试结果**
   至少覆盖：
   ```text
   N = 100
   N = 1000
   N = 10000
   ```

3. **正确性结果**
   必须记录：
   ```text
   command_count
   retire_count
   final_seqnum
   duplicate_count
   dropped_count
   ```

4. **优化前 / 优化后 FSM 波形对比**
   清楚展示：
   ```text
   Baseline:
   IDLE → DECODE → RETIRE

   Optimized:
   IDLE → RETIRE
   ```

5. **性能对照表**
   至少包含：
   ```text
   Total Cycles
   Cycles/Command
   Cmd/Cycle
   Improvement %
   ```

6. **PPA 初步结果**
   至少记录：
   ```text
   LUT
   FF
   Fmax
   ```

7. **Accept / Reject 结论**
   明确说明该优化是否保留，以及依据。

**本实验完成标志**

> 能够用波形和 CPC 数据共同证明 Fast Path 确实减少了 Engine 固定开销，同时未破坏 retire/seqnum 语义。

**实验4执行记录（2026年8月21日）**

本轮按“仅`cp_engine` Unit Test层”的首版范围实现。`VX_cp_engine`新增参数`ENABLE_NOP_FAST_PATH`，默认关闭；单测wrapper默认打开，基线通过`NOP_FAST_PATH=0`生成。`S_DECODE`保留，只有`CMD_NOP`走快路径。

验证场景：

| 场景 | 验证内容 | PASS 标准 |
|---|---|---|
| NOP Baseline | `IDLE -> DECODE -> RETIRE` | CPC=3，DECODE 次数=N |
| NOP Fast Path | `IDLE -> RETIRE` | CPC=2，DECODE 次数=0 |
| N=100/1000/10000 | 连续命令压力和 seqnum | retire=N、seqnum=N、无丢失/重复 |
| 资源分类 Smoke | KMU、DMA、DCR、EVENT 及无资源命令 | 13 条命令正确分类并退役 |
| Profile | NOP/LAUNCH 的事件与 profile 数据 | submit/start/end 和 profile_slot 正确 |
| Priority | priority=3 的 LAUNCH | KMU bid 携带 priority=3 |
| 默认关闭与 PPA | 原路径兼容、面积和 Fmax | 功能通过，并据 PPA 决定是否默认启用 |

从`build/`目录复现：
```bash
../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
```

正确性与性能结果：

| 配置 | N | retire_count | final_seqnum | duplicate | dropped | Total Cycles | CPC | Cmd/Cycle | DECODE cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 100 | 100 | 100 | 0 | 0 | 300 | 3.000000 | 0.333333 | 100 |
| Baseline | 1000 | 1000 | 1000 | 0 | 0 | 3000 | 3.000000 | 0.333333 | 1000 |
| Baseline | 10000 | 10000 | 10000 | 0 | 0 | 30000 | 3.000000 | 0.333333 | 10000 |
| Fast Path | 100 | 100 | 100 | 0 | 0 | 200 | 2.000000 | 0.500000 | 0 |
| Fast Path | 1000 | 1000 | 1000 | 0 | 0 | 2000 | 2.000000 | 0.500000 | 0 |
| Fast Path | 10000 | 10000 | 10000 | 0 | 0 | 20000 | 2.000000 | 0.500000 | 0 |

因此：
```text
Improvement = (3.0 - 2.0) / 3.0 × 100% = 33.33%
```

波形文件：
- `results/exp04/nop_baseline.vcd`：`IDLE → DECODE → RETIRE`
- `results/exp04/nop_fastpath.vcd`：`IDLE → RETIRE`

后续已用本地 Yosys 0.9 + ABC + OpenSTA 2.7.0 补充综合。FPGA xc7 代理结果为 Baseline 211 estimated LCs / 359 FDRE，Fast Path 220 estimated LCs / 359 FDRE。NanGate 15 nm typical、400 MHz 共同映射目标下，面积分别为 2703.092 / 2698.304 um^2，Fmax 代理分别为 389.35 / 364.30 MHz，下降 6.43%。因此最终结论为：**功能 Accept，默认集成 Reject**。保留参数化实验实现，但`ENABLE_NOP_FAST_PATH`继续默认关闭。完整报告见`docs/experiments/exp04_engine_fast_path.md`，逐步命令见`docs/experiments/exp04_commands.md`。

---
### 实验5：Command Packing

**背景**：当前Runtime每条命令独占64B CL。例如`CMD_DCR_WRITE`仅需20B，Useful Ratio = 20/64 = 31.25%。

**原理**：`VX_cp_unpack`已支持`offset`递增解析多条命令，故可将DCR0、DCR1、DCR2打包进同一CL：
```text
0                     63
┌────────┬────────┬────────┬─────┐
│ DCR 0  │ DCR 1  │ DCR 2  │PAD  │
│ 20B    │ 20B    │ 20B    │4B   │
└────────┴────────┴────────┴─────┘
```

**修改范围**：主要修改 `sw/runtime/common/device.cpp`，建立Command Line Builder逻辑：
```text
当前CL剩余空间 >= 新command size → 追加
否则 → 提交当前CL，创建下一CL
```

**⚠️ 关键正确性点：seqnum语义**
- 原Runtime：每append一个64B CL，`cp_expected_seqnum_ += 1`
- Packing后：**必须改为每command +1**，因为Engine是每条command retire一次。

**测试**：1000 × DCR_WRITE，记录commands、cache_lines、fetch_bytes、cycles。

**理论结果**：原始1000 CL → Packing后约334 CL（3 DCR/CL），Fetch Traffic从64000B降至约21376B，**理论降低≈66%**。

**PASS条件**：
- Correctness：1000 DCR全部正确执行，seqnum=1000，无drop/duplicate
- Performance：Fetch CL数显著下降，Bytes/Command显著下降


**实验输出 / 可交付成果**

1. **Command Packing Runtime Patch**
   包括：
   - Command Line Builder
   - CL 剩余空间判断
   - 自动 flush 当前 CL
   - 新 CL 创建逻辑

2. **Seqnum 语义修复 Patch**
   必须明确证明：
   ```text
   expected_seqnum
   ```
   已由“按 CL 计数”调整为符合“按 Command retire”语义。

3. **Packing 边界测试**
   至少测试：
   - 一个 CL 恰好放满
   - 剩余空间不足以放下一条命令
   - 多 CL 连续 Packing
   - Ring wrap 附近 Packing

4. **1000 × DCR_WRITE 测试结果**
   至少记录：
   ```text
   command_count
   cache_line_count
   fetch_bytes
   bytes_per_command
   total_cycles
   cmd_per_cycle
   final_seqnum
   ```

5. **Packing 前 / 后数据表**
   至少比较：
   ```text
   CL/Command
   Bytes/Command
   Fetch Traffic
   Total Cycles
   Throughput
   ```

6. **一张 Command Packing 效率图**
   推荐：
   ```text
   Baseline vs Packed Fetch Bytes/Command
   ```

7. **完整 Regression 日志**
   确认其他命令类型没有因为新的 CL Packing 逻辑而被破坏。

**本实验完成标志**

> 能够证明一条 64B CL 中可以安全承载多条 Command，并且前端流量下降、seqnum 正确、无命令丢失或重复。

**本次执行结果（2026-08-21）**

已完成 Runtime Command Line Builder、按 Command 计数的 seqnum 修正，以及恰好放满、空间不足、多 CL 和 Ring wrap 边界验证。1000 条 DCR_WRITE 从 1000 CL / 64000 B 降至 334 CL / 21376 B，取指流量下降 66.60%；最终 seqnum 为 1000，drop/duplicate 均为 0。当前 DCR 场景受执行路径限制，Total Cycles 均为 7011，因此流量优化尚未转化为吞吐提升。完整报告见 `docs/experiments/exp05_command_packing.md`，逐步复现命令见 `docs/experiments/exp05_commands.md`。

验证场景：

| 场景 | 验证内容 | PASS 标准 |
|---|---|---|
| 空行与单命令 | 零填充、普通/Profile LAUNCH | 命令数量、长度和字段正确 |
| 混合长度 Packing | DCR_WRITE+MEM_COPY、多条 Profile NOP | 顺序、参数和 profile_slot 正确 |
| 空间不足 | 偏移 56 处放置无法容纳的 MEM_COPY | 拒绝跨缓存行命令 |
| 恰好放满 | 20+20+12+12=64 B | 四条命令全部解析，无伪命令 |
| 1000 条 DCR 对照 | Baseline 与 Packed | 1000 CL 对 334 CL，seqnum 均为 1000 |
| Ring wrap Packing | 256 B Ring、4 CL、每行 3 条 DCR | 4 次读取、12 条命令、head=384 |
| Completion 与回归 | seqnum 写回、DMA/Engine/Runtime | 写回值正确，相关测试和编译全部 PASS |

---
### 实验6：Fetch Prefetch

**当前问题**：Single Outstanding，Host memory latency无法隐藏。

**第一版设计**：增加 **2-entry Cache-Line FIFO**，结构：
```text
Host AXI → CL FIFO[0] → Unpack
         → CL FIFO[1] → Unpack
```
**第一阶段不做**：8-entry、复杂AXI ID、大量Outstanding、乱序Response。固定 `PREFETCH_DEPTH = 2`。

**实验变量**：人为设置Host AXI response latency：
```text
1 cycle, 5 cycles, 10 cycles, 20 cycles, 50 cycles, 100 cycles
```
分别测试Baseline vs 2-entry Prefetch。

**期望曲线**：AXI latency小时收益小，latency大时收益逐渐增大——证明Prefetch真正隐藏了Host Memory Latency。

**验收检查清单**：
- AR数正确
- 没有重复读取CL
- 没有跳过CL
- head更新正确
- ring wrap正确
- command顺序正确
- seqnum正确


**实验输出 / 可交付成果**

1. **2-entry Prefetch RTL Patch**
   至少包含：
   ```text
   CL FIFO
   read pointer
   write pointer
   occupancy/full/empty
   AXI request control
   ```

2. **可调 AXI Read Latency 测试环境**
   能够扫描：
   ```text
   1
   5
   10
   20
   50
   100 cycles
   ```

3. **Prefetch 延迟扫描原始数据**
   推荐：
   ```text
   results/exp06/prefetch_latency_sweep.csv
   ```

4. **吞吐率曲线**
   必须绘制：
   ```text
   X: AXI Read Latency
   Y: Command Throughput
   ```
   同时包含：
   - Baseline
   - 2-entry Prefetch

5. **关键正确性波形**
   至少覆盖：
   - FIFO 入队/出队
   - AXI AR/R handshake
   - 连续 CL
   - Ring wrap

6. **Correctness Regression**
   必须证明：
   ```text
   no duplicate CL
   no skipped CL
   command ordering correct
   head correct
   seqnum correct
   ```

7. **PPA 数据**
   特别记录 FIFO 带来的：
   ```text
   LUT delta
   FF delta
   BRAM delta
   Fmax delta
   ```

**本实验完成标志**

> 能够用“AXI latency 越大，Prefetch 收益越明显”的实验曲线证明 Prefetch 正在隐藏 Host Memory latency，而不是偶然降低周期数。

**本次执行结果（2026年8月21日）**

已完成 2-entry Cache-Line FIFO、独立 `fetch_head`、FIFO 读写指针/占用计数，以及最多两个有序 AXI 在途请求。测试环境覆盖 1、5、10、20、50、100-cycle 响应延迟。

| AXI 延迟 | Baseline Cmd/Cycle | Prefetch Cmd/Cycle | 吞吐提升 |
|---:|---:|---:|---:|
| 1 | 0.500000 | 0.744186 | 48.84% |
| 5 | 0.300000 | 0.592593 | 97.53% |
| 10 | 0.200000 | 0.396694 | 98.35% |
| 20 | 0.120000 | 0.238806 | 99.01% |
| 50 | 0.054545 | 0.108844 | 99.54% |
| 100 | 0.028571 | 0.057075 | 99.76% |

六个点均为 64 次 AR、192 条有序命令、最终 head=4096，且无重复或丢失。Ring wrap 和 `cp_core` 1000 条 DCR 验证通过，最终 seqnum=1000。PPA 代理结果为 7915→7954 LCs、137→141 FF、BRAM 0→0、ASIC 面积 +10.87%、Fmax -2.27%。因此功能与性能 Accept，但默认集成暂缓，`VX_cp_fetch` 默认深度保持 1，实验显式使用深度 2。完整报告见 `docs/experiments/exp06_fetch_prefetch.md`，逐步命令见 `docs/experiments/exp06_commands.md`。

---
### 实验7：Priority-Aware Arbitration

**当前状态**：Queue state已有`prio`，Engine Bid已有`bid_priority`，但Arbiter完全忽略，只做Round Robin。

**V1优化目标**：**Priority First + Round Robin Within Same Priority**

示例：
```text
Q0=P0, Q1=P3, Q2=P3, Q3=P1
全部请求同一资源 → 只选P3候选Q1/Q2 → Q1,Q2,Q1,Q2... RR
```

**Arbiter Unit Test必须包含**：

- **Test A（同优先级）**：Q0~Q3均为P2 → 预期 `Q0,Q1,Q2,Q3,Q0,Q1...` 保持RR
- **Test B（单高优先级）**：Q0=P0, Q1=P3，持续请求 → 预期 `Q1` 优先获得
- **Test C（两高优先级）**：Q0=P0, Q1=P3, Q2=P3, Q3=P1 → 预期 `Q1,Q2,Q1,Q2...`

**Fairness指标**：
```text
Fairness Error = (max(grant_count) - min(grant_count)) / total_grants
```
建议 **< 2%**。


**实验输出 / 可交付成果**

1. **Priority-Aware Arbiter RTL Patch**
   实现：
   ```text
   Priority First
   +
   Round Robin Within Same Priority
   ```

2. **Test A / B / C 自动化测试**
   三类测试都必须有 PASS/FAIL 结果。

3. **Grant Count 原始数据**
   对每个 Queue 记录：
   ```text
   request_count
   grant_count
   average_wait
   max_wait
   ```

4. **Fairness 计算结果**
   同优先级情况下计算：
   ```text
   Fairness Error
   ```

5. **Priority 仲裁关键波形**
   必须显示：
   ```text
   bid_valid
   bid_priority
   rr_pointer
   selected_queue
   bid_grant
   ```

6. **Baseline RR vs Priority RR 对比表**
   至少包含：
   - 高优先级 Queue 平均等待周期
   - 低优先级 Queue 平均等待周期
   - 同优先级 Fairness Error

7. **Regression + PPA 结果**
   确认四类资源仲裁路径均不受破坏。

**本实验完成标志**

> 能够证明高优先级 Queue 获得更低服务延迟，同时同优先级 Queue 仍保持 Round-Robin 公平性。

**实验7执行记录（2026年8月24日）**

- 已在 `VX_cp_arbiter` 中实现 Priority First + Same-Priority Round Robin，并通过 `ENABLE_PRIORITY` 参数保留 Baseline 对照。
- Test A 的 400 次授权在 Q0～Q3 之间各 100 次，Fairness Error=0%。
- Test B 中 P3 队列获得 128/128 次授权；Test C 中两个 P3 队列各获得 64 次，保持轮询。
- 严格优先级下低优先级队列可能饥饿，因此 `VX_cp_core` 的 `ENABLE_PRIORITY_ARBITRATION` 默认保持关闭，等实验8 Aging 完成后再评估默认集成。
- 单个4路仲裁器的 FPGA LCs 为 73→75，FDRE 为 2→2；ASIC 面积为 52.136→97.622 um²，两者均满足 400 MHz 约束。
- 完整结果见 [`docs/experiments/exp07_priority_arbitration.md`](docs/experiments/exp07_priority_arbitration.md)，逐步命令见 [`docs/experiments/exp07_commands.md`](docs/experiments/exp07_commands.md)。

---
### 实验8：Aging 防饥饿机制

**必要性**：Strict Priority会导致低优先级永远得不到Grant（Starvation）。

**Aging设计**：给每个Queue增加`wait_counter`，分段提升有效优先级：
```text
0~15 cycles   → aging +0
16~31 cycles  → aging +1
32~63 cycles  → aging +2
≥64 cycles    → aging +3
effective_priority = min(base_priority + aging, 3)
```
Arbiter使用 `effective_priority` 而非 `base_priority`。

**核心测试**：Q0=priority 0，Q1=priority 3，Q1永远请求，Q0同时请求。  
**必须满足**：Q0最终得到grant，不能无限等待。  
**建议定义最大服务延迟**：`MAX_WAIT = 128 cycles`，任意持续valid的Queue必须在MAX_WAIT内得到一次服务。


**实验输出 / 可交付成果**

1. **Aging RTL Patch**
   包括：
   ```text
   wait_counter
   aging_boost
   effective_priority
   saturation logic
   ```

2. **Starvation Stress Test**
   必须包含：
   ```text
   Low Priority Queue 持续请求
   High Priority Queue 持续请求
   ```

3. **最大等待周期统计**
   每个 Queue 至少记录：
   ```text
   average_wait
   max_wait
   grant_count
   ```

4. **Effective Priority 波形**
   清楚展示：
   ```text
   base_priority
   wait_counter
   aging_boost
   effective_priority
   grant
   ```

5. **Strict Priority vs Priority+Aging 对照表**
   重点比较：
   ```text
   high-priority latency
   low-priority max wait
   starvation occurrence
   ```

6. **MAX_WAIT 验证报告**
   明确说明是否满足实验定义的最大等待约束。

7. **PPA 结果**
   记录每 Queue aging counter 带来的面积和时序影响。

**本实验完成标志**

> 在高优先级请求持续存在时，低优先级持续请求仍能在有限周期内得到服务，并有数据证明不存在无限 starvation。

**实际完成记录**

- 已在 `VX_cp_arbiter` 中加入每队列 7 位饱和等待计数器，并按 16/32/64 周期产生 +1/+2/+3 的 Aging 提升。
- P0 与持续请求的 P3 竞争时，P0 在第 64 周期首次获权；512 周期压力测试中 P0 获权 7 次，最大等待 64 周期，满足 `MAX_WAIT=128`。
- 同优先级 4 队列各获权 100 次，公平误差为 0%；完整 CP 的 100 条命令集成回归无丢失、无重复。
- 单个 4 路仲裁器的 FPGA LCs 为 75→191、FDRE 为 2→30；ASIC 面积为 86.716→347.928 um²，400 MHz 下 setup slack 为 1.602→1.387 ns。
- 完整报告见 [`docs/experiments/exp08_aging.md`](docs/experiments/exp08_aging.md)，逐步命令见 [`docs/experiments/exp08_commands.md`](docs/experiments/exp08_commands.md)。

---
### 实验9：EVENT_WAIT Fairness

**当前问题**：`EVENT_WAIT`获得EVENT Arbiter后不断Poll直到条件成立，期间长期占用EVENT资源。

**改进思路**：原结构 `Grant → Poll → Not Ready → Poll ...`  
优化为：`Grant → Poll → 条件不成立 → Release → Backoff → 重新BID`  
这样其他Queue的`EVENT_SIGNAL`可以插入执行。

**测试场景**：
```text
Q0: EVENT_WAIT X >= 1
Q1: EVENT_SIGNAL Y
Q2: EVENT_SIGNAL Z
Q3: EVENT_SIGNAL W
```
记录Q0 poll次数，Q1/Q2/Q3 latency。

**PASS条件**：优化后Q1/Q2/Q3等待时间显著降低，同时Q0 WAIT最终正确完成，**不丢EVENT，不错误提前退休**。


**实验输出 / 可交付成果**

1. **EVENT_WAIT Release/Backoff RTL Patch**
   明确实现：
   ```text
   Poll
   → Condition False
   → Release Resource
   → Backoff
   → Re-BID
   ```

2. **EVENT contention Testbench**
   至少包含：
   ```text
   1 个 EVENT_WAIT
   3 个 EVENT_SIGNAL
   ```

3. **优化前 / 后延迟结果**
   分别记录：
   ```text
   Q0 poll_count
   Q1 latency
   Q2 latency
   Q3 latency
   event_resource_busy_cycles
   ```

4. **关键波形**
   展示：
   - WAIT 释放资源
   - SIGNAL 插入执行
   - WAIT 重新申请
   - 条件满足后正确 retire

5. **事件正确性检查**
   必须证明：
   ```text
   no lost event
   no early retire
   no duplicate retire
   ```

6. **Fairness 改善结论**
   定量说明其他 Queue 的等待时间下降多少。

**本实验完成标志**

> EVENT_WAIT 不再长期独占 Event 资源，其他 Event Command 的等待时间显著降低，同时 WAIT 语义保持正确。

**实际完成记录**

- 已实现 `EVENT ready` 门控和 `WAIT retry → Release → Backoff → Re-BID` 完整握手。
- 四队列对照中，Q1/Q2/Q3 SIGNAL 退休周期由 109/114/119 降至 11/16/21，分别降低 89.9%/86.0%/82.4%。
- WAIT Poll 次数由 50 降至 18，EVENT 忙碌周期由 113 降至 66；Q0 WAIT 最终延迟仅增加 1 周期。
- 正确性检查结果为 `lost=0`、`early_retire=0`、`duplicate=0`，完整 CP 100 命令回归同样无丢失和重复。
- 完整报告见 [`docs/experiments/exp09_event_wait_fairness.md`](docs/experiments/exp09_event_wait_fairness.md)，逐步命令见 [`docs/experiments/exp09_commands.md`](docs/experiments/exp09_commands.md)。

---
### 实验10：QMD-Style Kernel Launch（高级）

**定位**：软件已准备（`CMD_LAUNCH_QMD` 0x0B），RTL待补齐。

**QMD思想**：将传统 `18×DCR_WRITE + LAUNCH` 合并为单条 `LAUNCH_QMD`，内部读取Descriptor并Replay DCR，最后Launch。  
**减少**：Ring command数、Ring traffic、Doorbell pressure、Decode overhead、Launch latency。

**Benchmark**：编写Empty Kernel `kernel void empty() {}`，分别启动10、100、1000、10000次，统计：
```text
cycles / launch
commands / launch
cache lines / launch
bytes / launch
```


**实验输出 / 可交付成果**

1. **QMD RTL 支持 Patch**
   至少涉及：
   - Opcode 定义
   - Engine decode
   - Descriptor 获取/解析
   - DCR replay
   - 最终 Launch

2. **若需要，配套 Runtime Patch**
   保证软件提交格式与 RTL QMD 格式完全一致。

3. **QMD Descriptor 格式说明**
   推荐形成：
   ```text
   docs/qmd_descriptor.md
   ```

4. **Empty Kernel Benchmark**
   至少覆盖：
   ```text
   10
   100
   1000
   10000 launches
   ```

5. **Legacy vs QMD 对照表**
   至少比较：
   ```text
   commands/launch
   cache_lines/launch
   bytes/launch
   cycles/launch
   launches/second
   ```

6. **QMD Launch 波形**
   展示：
   ```text
   QMD command
   descriptor fetch
   internal DCR replay
   KMU launch
   completion
   ```

7. **Regression + PPA 结果**
   验证 Legacy Launch 仍然可用，QMD 未破坏现有路径。

**本实验完成标志**

> 能够证明 QMD 将多条 launch setup command 压缩为更少的 Ring command，并定量降低 Kernel Launch 前端开销。

---
### 实验11：Multi-Queue（高级）

**当前**：RTL已参数化`NUM_QUEUES`，但并非完整软件多Queue并发。

**第一类实验**：所有Queue竞争同一资源（如Q0~Q3均→DMA），测试Arbiter、Priority、Aging、Fairness。

**第二类实验**：不同Queue使用不同资源：
```text
Q0 → DMA
Q1 → DCR
Q2 → EVENT
Q3 → KMU
```
测量各自执行时间 `T_DMA, T_DCR, T_EVT, T_KMU`。  
串行总时间 `T_serial = T_DMA+T_DCR+T_EVT+T_KMU`，并行总时间 `T_parallel`。  
若资源真正并行，则 `T_parallel` 应接近 `max(T_DMA, T_DCR, T_EVT, T_KMU)` 而非 `T_serial`。


**实验输出 / 可交付成果**

1. **Multi-Queue 配置与软件支持 Patch**
   明确记录：
   ```text
   NUM_QUEUES
   queue allocation
   ring ownership
   tail/seqnum handling
   priority setup
   ```

2. **同资源竞争测试**
   例如：
   ```text
   Q0~Q3 → DMA
   ```
   输出：
   - 每 Queue grant count
   - average wait
   - max wait
   - fairness

3. **不同资源并行测试**
   ```text
   Q0 → DMA
   Q1 → DCR
   Q2 → EVENT
   Q3 → KMU
   ```

4. **并行度数据表**
   至少记录：
   ```text
   T_DMA
   T_DCR
   T_EVT
   T_KMU
   T_serial
   T_parallel
   ```

5. **Concurrency Speedup**
   计算：
   ```text
   Speedup = T_serial / T_parallel
   ```

6. **多 Queue 关键波形**
   必须能够同时看到：
   ```text
   q0/q1/q2/q3 state
   bids
   grants
   resource busy
   retire
   seqnum
   ```

7. **Priority + Aging 联合验证**
   确认 Multi-Queue 模式下前述调度策略仍然成立。

8. **系统级 Regression 结果**

**本实验完成标志**

> 能够用数据证明多 Queue 的资源竞争行为符合调度策略，并证明不同资源之间是否获得了真实硬件并行性。

---
### 实验12：最终综合与PPA评估

**必要性**：RTL仿真Cycle数下降不等于真正性能提升（如Cycle -10%但Fmax -15%，实际变慢）。

**必须记录每个Optimization的**：
```text
LUT, FF, BRAM, Critical Path, Fmax
```

**实际吞吐量计算**（关键公式）：
```text
Commands / Second = (Commands / Cycle) × Fmax
```
示例：Baseline 0.25 cmd/cycle × 400MHz = 100M cmd/s；优化后0.30 × 350MHz = 105M cmd/s，实际收益仅+5%而非+20%。

**全局验收标准**见第8节。


**实验输出 / 可交付成果**

1. **所有关键版本的综合报告**
   至少包括：
   ```text
   Baseline
   FastPath
   Packing
   Prefetch
   Priority
   Aging
   Combined
   ```

2. **PPA 总表**
   至少包含：

   | Version | LUT | FF | BRAM | Critical Path | Fmax |
   |---|---:|---:|---:|---:|---:|
   | Baseline | | | | | |
   | FastPath | | | | | |
   | Packing | | | | | |
   | Prefetch | | | | | |
   | Priority | | | | | |
   | Aging | | | | | |
   | Combined | | | | | |

3. **真实吞吐率结果**
   对每个版本计算：
   ```text
   Commands/Second = Cmd/Cycle × Fmax
   ```

4. **最终性能总表**
   至少包含：
   ```text
   Cmd/Cycle
   Cycles/Cmd
   Fetch B/Cmd
   Arb Wait
   Fmax
   LUT
   FF
   BRAM
   Real Throughput
   ```

5. **最终 6 张性能图**
   - Cycles Per Command
   - Command Throughput
   - Fetch Bytes / Command
   - AXI Latency vs Command Throughput
   - Queue ID vs Average Wait Cycles
   - Performance Improvement vs Area Increase

6. **Optimization Accept / Reject 矩阵**
   对每个优化明确填写：
   ```text
   Functional PASS?
   Performance PASS?
   Timing PASS?
   Area PASS?
   Final Decision
   ```

7. **最终实验报告**
   按本指导书第 10 节结构整理。

8. **可复现实验包**
   推荐至少包含：
   ```text
   scripts/
   results/
   plots/
   reports/
   docs/
   git commit/tag
   ```

**本实验完成标志**

> 任何人按照你的文档、脚本和固定 Git commit，都能够复现主要功能验证结果、性能结果和 PPA 结论。

---

## 6.1 实验可交付成果总览

| 实验 | 核心交付成果 |
|---|---|
| 实验0 Baseline | Unit Test日志、Baseline汇总表、环境记录、固定Git节点 |
| 实验1 数据流与波形 | FSDB/VCD、标注波形、CP数据流图、单命令周期事件表 |
| 实验2 性能基础设施 | Counter/Monitor代码、Microbenchmark框架、Baseline CSV/JSON、初始瓶颈报告 |
| 实验3 DMA Correctness | 边界Testbench、Guard结果、Bug波形、修复Patch、前后对照 |
| 实验4 Fast Path | Engine RTL Patch、NOP测试、FSM波形、CPC对照、PPA与Accept/Reject |
| 实验5 Command Packing | Runtime Patch、Seqnum修复、Packing边界测试、流量/吞吐对照 |
| 实验6 Fetch Prefetch | 2-entry FIFO RTL、Latency Sweep数据、吞吐曲线、波形、PPA |
| 实验7 Priority Arbiter | Priority RTL、A/B/C测试、Grant数据、Fairness结果、PPA |
| 实验8 Aging | Aging RTL、Starvation测试、Max Wait统计、Priority波形、PPA |
| 实验9 EVENT_WAIT | Release/Backoff RTL、竞争测试、延迟对照、Event正确性报告 |
| 实验10 QMD | QMD RTL/Runtime、Descriptor文档、Empty Kernel Benchmark、Launch对照 |
| 实验11 Multi-Queue | 多Queue支持、竞争/并行测试、Concurrency Speedup、多Queue波形 |
| 实验12 PPA/Final | 综合报告、PPA总表、6张性能图、Accept/Reject矩阵、最终报告与复现包 |

---

## 7. 性能度量核心公式与指标体系

（本节汇总了实验2中定义的公式，方便快速查阅）

| 指标 | 公式 | 单位 |
|------|------|------|
| **Throughput** | `Retired Commands / Total Cycles` | cmd/cycle |
| **CPC** | `Total Cycles / Retired Commands` | cycles/cmd |
| **Fetch Bytes** | `Fetch CL × 64` | Byte |
| **Bytes/Command** | `Fetch Bytes / Commands` | Byte/cmd |
| **Arbitration Latency** | `Tgrant - Tbid` | cycles |
| **Queue Latency** | `Tstart - Tsubmit` | cycles |
| **Execution Latency** | `Tretire - Tstart` | cycles |
| **Total Latency** | `Tretire - Tsubmit` | cycles |
| **Fairness Error** | `(max_grant - min_grant) / total_grants` | 无（<2%） |
| **Real Throughput** | `(cmd/cycle) × Fmax` | cmd/s |

---
## 8. 全局验收标准（功能/性能/时序/面积）

任何Optimization必须**同时满足**以下所有条件：

| 维度 | 硬性标准 |
|------|----------|
| **Functional** | 原有Regression 100% PASS |
| **Command Correctness** | No Drop, No Duplicate, No Wrong Order |
| **Completion** | Seqnum严格正确 |
| **Performance** | 目标Microbenchmark提升 **≥ 5%** |
| **Timing** | Fmax degradation **< 2%** |
| **Area** | 低风险优化 LUT/FF增加 **< 5%**；高级优化单独评估 |

**统一实验流程（10步法）**，严禁跳跃：
```text
① Hypothesis → ② Baseline → ③ RTL/Runtime修改 → ④ Unit Test
→ ⑤ Regression → ⑥ Microbenchmark → ⑦ Waveform → ⑧ Synthesis
→ ⑨ Result Analysis → ⑩ Accept / Reject
```

**每个实验使用统一记录表**（OPT-XX）：
```text
Optimization ID:   OPT-XX
Name:              Fetch Prefetch
Hypothesis:        ...
Modified Files:    ...
Baseline:          Commands=, Cycles=, cmd/cycle=, Fmax=
Optimized:         Commands=, Cycles=, cmd/cycle=, Fmax=
Correctness:       Unit Test PASS/FAIL, Regression PASS/FAIL, Seqnum PASS/FAIL, Ordering PASS/FAIL
Performance:       Improvement = XX%
PPA:               LUT delta=, FF delta=, BRAM delta=, Fmax delta=
Decision:          ACCEPT / REJECT
```

**最终需要生成的性能总表**：

| Version | Cmd/Cycle | Cycles/Cmd | Fetch B/Cmd | Arb Wait | Fmax | LUT | Result |
|---------|-----------|------------|-------------|----------|------|-----|--------|
| Baseline | | | | | | | |
| FastPath | | | | | | | |
| Packing | | | | | | | |
| Prefetch | | | | | | | |
| Priority | | | | | | | |
| Aging | | | | | | | |
| Combined | | | | | | | |

**必须画出的6张性能图**：
1. Cycles Per Command（各优化对比）
2. Command Throughput
3. Fetch Bytes / Command
4. AXI Latency vs Command Throughput（证明Prefetch）
5. Queue ID vs Average Wait Cycles（证明Priority/Aging）
6. Performance Improvement vs Area Increase（权衡图）

---
## 9. GitHub 项目管理与协作规范（完整版）

为使实验过程可追溯、可协作、可复现，建议在GitHub上建立专用仓库，严格执行以下规范。
### 9.1 分支与标签策略
- **永久分支**：
  - `main` / `master`：稳定发布版，仅合并经过完整验证（含综合）的优化
  - `develop`：日常开发集成（若仓库未启用 `develop`，则以 `cp-opt` 作为课程项目集成分支）
- **课程基线分支**：
  - `cp-baseline`：固定原始源码基线，建立后不再修改
  - `cp-opt`：课程项目主开发分支，实验0提交 `cp-opt-00-baseline`，后续优化按实验逐个提交
- **实验分支**：多人协作或风险较大的实验使用独立分支，命名格式 `feature/exp-<编号>-<简述>`，如：
  ```text
  feature/exp-00-baseline
  feature/exp-03-dma-correctness
  feature/exp-06-prefetch
  ```
- **标签**：
  - `cp-exp0-source-baseline`：指向实验0源码基线 commit
  - 每个正式优化版本打标签，如 `v3.0-opt-fastpath`, `v3.0-opt-combined`
- **远端同步**：创建分支和标签后推送到 GitHub，并设置 upstream：
  ```bash
  git push origin cp-baseline cp-opt cp-exp0-source-baseline
  git branch --set-upstream-to=origin/cp-opt cp-opt
  git branch --set-upstream-to=origin/cp-baseline cp-baseline
  ```
### 9.2 Issue与里程碑（Milestones）
- 为**每个实验（0～12）**创建一个 **Milestone**，设置截止日期。
- 每个子任务创建 **Issue**，关联对应Milestone，并使用Labels：
  - `type/bug` / `type/enhancement` / `type/documentation`
  - `stage/verification` / `stage/synthesis` / `stage/analysis`
- 示例：实验6的Issues可分解为：
  - `#6.1 修改VX_cp_fetch增加2-entry FIFO`
  - `#6.2 编写AXI延迟测试脚本`
  - `#6.3 收集Prefetch性能数据`
### 9.3 Pull Request（PR）流程（强制执行）
1. 开发分支完成修改并通过本地单元测试后，提交PR至`develop`。
2. **PR模板必须包含以下内容**（逐项填写）：
   ```markdown
   ## 实验编号与名称
   Exp-06: Fetch Prefetch

   ## 假设与修改说明
   ...

   ## 基线数据
   | 指标 | 数值 |
   |------|------|
   | Commands | |
   | Cycles | |
   | cmd/cycle | |
   | Fmax | |

   ## 优化后数据
   | 指标 | 数值 |
   |------|------|
   | Commands | |
   | Cycles | |
   | cmd/cycle | |
   | Fmax | |

   ## 正确性验证
   - [ ] Unit Test PASS
   - [ ] Regression PASS
   - [ ] Seqnum Correct
   - [ ] Ordering Correct

   ## 综合结果
   - LUT delta: +X%
   - FF delta: +X%
   - Fmax delta: -X%

   ## 决策建议
   ACCEPT / REJECT / 需进一步讨论
   ```
3. 至少1位Reviewer审核通过后合并。
4. 合并后自动触发CI（见下）。
### 9.4 CI/CD 自动化集成（GitHub Actions）
在`.github/workflows/cp-regression.yml`中配置：
```yaml
on: [push, pull_request]
jobs:
  verilator-test:
    runs-on: ubuntu-latest
    steps:
      - checkout
      - run: make -C hw/unittest/cp_engine run
      - run: make -C hw/unittest/cp_arbiter run
      # ... 所有CP单元测试
      - run: python scripts/run_microbenchmarks.py --output artifacts/
      - upload-artifact: performance_report.json
  yosys-synthesis:
    runs-on: ubuntu-latest
    steps:
      - run: python scripts/synth_cp.py --top VX_cp_core --report area_timing.rpt
      - upload-artifact: area_timing.rpt
```
每次push自动产出性能报告和面积/时序报告，供PR审查使用。
### 9.5 项目看板（Projects）
创建GitHub Project Board，列以下状态列：
- **Backlog**（待规划的高阶实验）
- **To Do**（已分解的Issue，按Milestone排序）
- **In Progress**（正在开发的Issue）
- **Review**（PR待审）
- **Done**（已验证并合并）
### 9.6 文档与代码注释规范
- 所有RTL修改必须包含**头部注释**，说明修改功能、原因、影响范围（中英文均可）。
- 性能计数器代码需注释统计指标名称和单位。
- 仓库根目录维护 `README.md`，包含：
  - 快速构建指南（一键脚本）
  - 当前实验列表及状态徽章（✅ 通过 / ⚠️ 进行中 / ❌ 阻塞）
  - 如何运行特定测试及生成报告
- 维护 `docs/` 目录，存放最终报告、图表和综合脚本。

---
## 10. 推荐时间安排与最终报告结构
### 10.1 12周时间线（供参考）

| 周次 | 任务 |
|------|------|
| 第1周 | Vortex Build，所有CP Unit Test，Baseline保存 |
| 第2周 | CP源码阅读，Verdi波形跟踪，完整Dataflow理解 |
| 第3周 | 添加Performance Counter，搭建Microbenchmark框架 |
| 第4周 | DMA Correctness + Engine Fast Path |
| 第5周 | Command Packing（含Runtime修改与seqnum修正） |
| 第6周 | Fetch Prefetch（2-entry FIFO，多AXI延迟测试） |
| 第7周 | Priority Arbitration + Aging |
| 第8周 | EVENT_WAIT Fairness + 整体Regression |
| 第9周 | QMD Launch（高级） |
| 第10周 | Multi-Queue并发测试（高级） |
| 第11周 | 综合（Synthesis）与PPA数据收集 |
| 第12周 | 最终报告撰写 + 所有图表生成 |
### 10.2 最终实验报告结构（建议16章）
```text
1. Introduction
2. Vortex v3.0 Architecture Overview
3. Command Processor Architecture (Detailed)
4. Baseline Characterization
5. Performance Bottleneck Analysis
6. Engine Fast-Path Optimization
7. Command Packing Optimization
8. Fetch Prefetch Architecture
9. Priority Arbitration
10. Aging and Fairness
11. Experimental Methodology
12. Functional Verification
13. Performance Results
14. FPGA/ASIC Synthesis Results
15. Discussion (Trade-offs, Limitations, Future Work)
16. Conclusion
```

---
## 项目核心思想总结

本实验最重要的不是“给Vortex加很多功能”，而是建立**硬件优化工程师的思维闭环**：

```text
先理解 → 再测量 → 找到瓶颈 → 提出假设 → 只改一个变量
→ 验证正确性 → 测性能 → 测Fmax/Area → 决定保留还是回滚
```

如果你能完成 **Performance Instrumentation + Command Packing + Fetch Prefetch + Priority Arbitration + Aging**，并能用实验数据回答“为什么快、快了多少、在哪种workload下快、增加了多少硬件、有没有降低Fmax、有没有破坏ordering”，那么这已经是一次**真正意义上的GPU Command Processor微架构研究与RTL优化实验**。

---

**当前第一个实际任务**：从**实验0：CP Baseline 建立**开始，完成①配置Vortex build、②运行全部CP Unit Test、③保存Baseline输出、④建立 `cp-baseline` / `cp-opt` GitHub分支和baseline tag。在此之前，**不修改任何CP RTL**。DCR_WRITE完整数据流与Verdi/波形跟踪属于实验1。

这份完整版指导书可直接作为你的项目顶层文档，同时满足技术实施与GitHub团队协作的全部需求。祝实验顺利！
