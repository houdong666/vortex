# 实验 4～9 稳定性回归与整体 PPA 总结

## 1. 整理目标

本轮不引入实验 10，而是先收敛实验 4～9：确认每个优化的开关边界、单项功能、组合兼容性、RTL/XRT 集成条件和 PPA 代价。统一回归入口位于 `results/exp04_09_summary/run_regression.sh`，机器可读结果位于同目录的两个 CSV。

## 2. 优化边界与默认策略

| 实验 | 优化对象 | 开关/位置 | 当前默认策略 |
|---|---|---|---|
| 4 | NOP 执行快路径 | `VX_cp_engine.ENABLE_NOP_FAST_PATH` | 关闭，时序代理下降超过决策线 |
| 5 | 64 B 命令行打包 | Runtime/命令 ABI | 软件数据布局，不新增 RTL 单元 |
| 6 | AXI Fetch 预取 | `VX_cp_fetch.PREFETCH_DEPTH` | 深度 1；深度 2 保留为实验配置 |
| 7 | 优先级仲裁 | `ENABLE_PRIORITY_ARBITRATION` | 关闭，需与 Aging 配套评估 |
| 8 | 等待老化 | `ENABLE_ARBITRATION_AGING` | 关闭，功能通过但局部面积明显增加 |
| 9 | EVENT_WAIT 释放/重试 | `ENABLE_EVENT_WAIT_FAIRNESS` | 关闭，功能通过，整机 PPA 待补 |

保持默认关闭并不表示实验失败，而是把未经整机 PPA 和 XRT 验证的行为留在显式实验开关后，防止静默改变主线时序。

## 3. 本轮实际回归结果

以下项目已在 32 位配置、Verilator 单元级 RTL 模型上实际执行并通过：

1. 实验 4：Fast Path 开/关，100、1000、10000 条 NOP 以及 smoke 场景均通过。
2. 实验 5：8 个解包场景通过；打包后的 CP 路径保持命令完整。
3. 实验 6：`PREFETCH_DEPTH=1/2` 各 4 个 AXI 延迟/回压场景通过。
4. 实验 7：RR 与 Priority 对照通过。
5. 实验 8：Baseline、Priority、Aging 对照通过。
6. 实验 9：EVENT_WAIT 内部自旋与 Release/Backoff 对照通过。
7. 组合回归：Fast Path、Prefetch Depth 2、Priority、Aging、EVENT_WAIT Fairness 同时开启，再启用 Packing 运行 1000 条命令；结果为 `final_seqnum=1000`、`drop=0`、`duplicate=0`。

详细状态见 `results/exp04_09_summary/regression_status.csv`。

## 4. RTL 与 XRT 回归状态

### 4.1 RTL 整机路径

执行命令：

```bash
cd build
env -u DEBUG CCACHE_DISABLE=1 OBJCACHE= \
  ./ci/blackbox.sh --driver=rtlsim --app=demo
```

本机最初依次被缺失的 `ccache`、Ramulator/SoftFloat 源码、非 PIC SoftFloat 静态库和 RISC-V 软件工具链阻塞。本轮已经完成以下处理：

1. 清空 `OBJCACHE`，避免调用不存在的 `ccache`。
2. 按主仓库锁定提交初始化 Ramulator 和 SoftFloat。
3. 安装本地 CMake，构建 Ramulator 2 及其固定版本依赖。
4. 使用 `-fPIC` 重编 SoftFloat，使其可以链接进 `librtlsim.so`。
5. 展开用户已有的 Vortex LLVM/RISC-V 64 位工具链，并安装官方 `libcrt64/libc64`。

最终使用独立的 `build64` 目录完成两个整机用例：

| 用例 | 结果 | 指令数 | 周期数 | IPC |
|---|---|---:|---:|---:|
| demo | PASS | 3640 | 10346 | 0.352 |
| sgemm 16×16 | PASS | 14688 | 34617 | 0.424 |

`sgemm -n10` 不满足当前 4×4 block 的整除约束，因此使用合法的 `-n16`。实际复现命令为：

```bash
mkdir -p build64
cd build64
../configure --xlen=64 --tooldir=/home/houdong/tool
env -u DEBUG CCACHE_DISABLE=1 OBJCACHE= ./ci/blackbox.sh --driver=rtlsim --app=demo
env -u DEBUG CCACHE_DISABLE=1 OBJCACHE= ./ci/blackbox.sh --driver=rtlsim --app=sgemm --args="-n16"
```

### 4.2 XRT 全集成路径

按照仓库规则，XRT 才覆盖 AFU、Host Runtime、平台镜像和设备交互。本机当前没有 `xrt-smi`、`xbutil`、`v++`、Vivado、平台变量或 `.xclbin`，所以不能宣称完成 XRT 验证。具备平台环境后执行：

```bash
cd build
export FPGA_BIN_DIR=/path/to/generated/xclbin
./ci/blackbox.sh --driver=xrt --app=demo
./ci/blackbox.sh --driver=xrt --app=sgemm --args="-n10"
```

必须记录板卡/平台名、XRT 版本、目标模式、xclbin 哈希和测试日志，才能关闭该门禁。

## 5. 整体 PPA 总结

已有数据都是相同工具与约束下的未布局布线代理，但综合顶层不同，因此只能比较每个实验相对自身基线的变化，不能把面积绝对值直接相加。

| 实验 | 综合范围 | FPGA LCs 变化 | ASIC 面积变化 | 关键路径变化 | 判断 |
|---|---|---:|---:|---:|---|
| 4 Fast Path | CP Engine | +4.27% | -0.18% | +7.52% | 面积可接受，时序不宜默认开启 |
| 5 Packing | Runtime/ABI | 无新增 RTL | 无新增 RTL | 无新增 RTL | PPA 主要收益是 AXI 流量减少 |
| 6 Prefetch | Fetch | +0.49% | +10.87% | +2.36% | FPGA 逻辑增量小，ASIC/时序需整机确认 |
| 7 Priority | 4 路 Arbiter | +2.74% | +87.25% | +28.38% | 百分比大但绝对面积仅增加 45.486 um² |
| 8 Aging | 4 路 Arbiter | +154.67% | +301.23% | +25.09% | 等待计数器代价明显，需缩位或分段老化 |
| 9 EVENT_WAIT | EVENT/Engine | 待整机综合 | 待整机综合 | 待整机综合 | 功能收益明确，不能用缺失数据推断 PPA |

数据来源为 `results/exp04`、`results/exp06/ppa_metrics.csv`、`results/exp07`、`results/exp08/ppa_metrics.csv`，统一表见 `results/exp04_09_summary/ppa_summary.csv`。

本轮还将 `ENABLE_NOP_FAST_PATH` 和 `PREFETCH_DEPTH` 提升为 `VX_cp_core` 顶层参数，使实验 4～9 可以在同一个综合顶层切换。首次使用系统 Yosys 0.9 读取 sv2v 生成的完整 CP Verilog 时，Baseline 和全优化配置都在 AST 简化阶段因深递归崩溃。用 Yosys 0.40 对同一输入重跑后，前端、层次展开、Xilinx xc7 映射和最终 `check` 全部完成，确认原问题来自旧版综合器，而不是 RTL 中存在递归实例。

正式面积对比固定为 4 队列，因为 Priority、Aging 和 EVENT_WAIT 公平性只有多队列竞争时才具有代表性：

| 配置 | Estimated LCs | FDRE | FDSE | RAM32M | RAM64M | `check` |
|---|---:|---:|---:|---:|---:|---|
| Baseline | 11485 | 11300 | 25 | 22 | 512 | 0 个问题 |
| 实验 4～9 全开 | 11610 | 9388 | 25 | 366 | 512 | 0 个问题 |
| 变化 | **+1.09%** | -1912 | 0 | +344 | 0 | PASS |

FDRE 减少不能解释成存储状态减少：全优化配置把更多小型状态阵列映射成了 `RAM32M` 分布式 RAM，因此应以 `Estimated LCs` 的同口径变化作为当前面积结论。该结果是综合后、布局布线前的面积代理；Yosys `synth_xilinx` 不提供可用于签核的 Vivado Fmax，所以整体时序仍需在相同器件、时钟约束和布局布线流程下补测。

相同四队列顶层还使用 Nangate Open Cell Library typical 和 2.5 ns ABC 目标完成了标准单元映射：

| 配置 | ASIC 面积（µm²） | 变化 | `check` |
|---|---:|---:|---|
| Baseline | 404913.978 | — | 0 个问题 |
| 实验 4～9 全开 | 423704.218 | **+4.64%** | 0 个问题 |

该标准单元流会把 CP 内部小存储展开为触发器和多路选择器，因此绝对面积明显偏大；它适合比较两种配置的相对增量，不代表带 SRAM 宏的最终芯片面积。

OpenSTA 2.0.17 也对两份映射网表进行了诊断，但完整 CP 的未布局网表没有高扇出缓冲树，基线与全优化的首条路径分别出现约 13846 ns 和 11695 ns 的非物理延迟；工具随后还在向量无关功耗报告阶段发生段错误。两组都受相同方法学缺陷影响，这些延迟不能计算 Fmax，也不能据此宣称时序提升。日志保留在两组 `asic400_reports/sta.log`，状态明确记为 `BLOCKED`。

复现入口为：

```bash
cd /home/houdong/vortex
results/exp04_09_summary/run_cp_core_ppa.sh
```

脚本要求 Yosys 0.40 或更新版本，本机固定工具位于 `/home/houdong/tool/yosys-0.40`，配套映射器为 Berkeley ABC 1.01。机器可读结果见 `results/exp04_09_summary/whole_cp_ppa_metrics.csv`，新版 FPGA 成功日志为 `ppa/{baseline,all_enabled}/fpga_yosys040_q4.log`，ASIC 面积报告为对应目录下的 `asic400_reports/stat_lib.rpt`；Yosys 0.9 的失败日志继续保留，用于说明问题定位过程。FPGA 四队列单次综合的峰值内存约 3.8 GB，复现机器应至少预留 4 GB 可用内存。

综合判断：实验 4～9 全开后的完整 CP FPGA LCs 增加 1.09%，Nangate 标准单元面积增加 4.64%，两者均低于 5% 的低风险面积门限；这只关闭了统一顶层的面积门禁，不能代替 Fmax、Vivado 布局布线或 XRT 真机验证。实验 5 仍是无新增 RTL 的软件打包；实验 6 用少量逻辑换取高延迟下接近 2 倍吞吐；实验 7 必须和实验 8 一起看公平性；实验 8 仍是后续局部降成本的重点。

## 6. 下一步门禁

1. 在具备 XRT/Vitis 和板卡镜像的机器上完成 XRT 两个用例，并保存平台信息与日志。
2. 使用 Vivado 对同一个 `VX_cp_core` 四队列顶层完成布局布线，补齐 WNS、关键路径和 Fmax；不得用 Yosys 面积代理冒充时序签核。
3. 优先优化 Aging：减小等待计数器位宽，比较饱和计数、分段阈值和共享时间戳三种结构。
4. 为实验 9 增加 EVENT/Engine 局部 PPA，再决定是否默认开启。

当前状态是“单元、组合功能、rtlsim 整机回归和统一 CP 顶层 FPGA/ASIC 面积代理已通过；XRT 真机门禁与 Vivado 布局布线时序待完成”。
