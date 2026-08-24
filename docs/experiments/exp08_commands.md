# 实验 8 操作与逐步复现命令

本文按实际操作顺序记录 Aging 防饥饿机制的实现、验证、波形和 PPA 命令。

## 步骤 1：重新配置构建目录

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/tool
```

## 步骤 2：检查实验 7 的优先级路径

```bash
cd /home/houdong/vortex
rg -n "ENABLE_PRIORITY|bid_priority|VX_cp_arbiter" \
  hw/rtl/cp hw/unittest/cp_arbiter
```

确认基础优先级已经从队列传入仲裁器，然后在仲裁器内增加等待计数和有效优先级，不修改命令 ABI。

## 步骤 3：实现 Aging RTL

修改以下文件：

```text
hw/rtl/cp/VX_cp_arbiter.sv
hw/rtl/cp/VX_cp_core.sv
```

实现顺序：持续等待时饱和计数；按 16/32/64 周期计算 boost；将基础优先级与 boost 饱和相加；用有效优先级筛选候选者；同级请求继续轮询。

## 步骤 4：扩展单元测试

修改：

```text
hw/unittest/cp_arbiter/VX_cp_arbiter_top.sv
hw/unittest/cp_arbiter/main.cpp
hw/unittest/cp_arbiter/Makefile
```

分别运行三种模式：

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean run \
  PRIORITY_ARBITRATION=0 ARBITRATION_AGING=0
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean run \
  PRIORITY_ARBITRATION=1 ARBITRATION_AGING=0
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean run \
  PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1
```

## 步骤 5：自动生成日志和 CSV

```bash
cd /home/houdong/vortex
python3 results/exp08/run_exp08.py
```

输出 `baseline.log`、`priority.log`、`aging.log` 和 `aging_metrics.csv`。

## 步骤 6：生成并查看 VCD 波形

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean all \
  DEBUG=1 PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1
VCD_FILE=/home/houdong/vortex/results/exp08/aging_arbiter.vcd \
  ./hw/unittest/cp_arbiter/cp_arbiter
gtkwave /home/houdong/vortex/results/exp08/aging_arbiter.vcd
```

重点观察 `bid_priority`、`wait_counter`、`aging_boost`、`effective_priority`、`bid_grant` 和 `rr_pointer`。

## 步骤 7：运行 CP 集成回归

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
../configure --xlen=32 --tooldir=/home/houdong/tool
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean all \
  PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1
./hw/unittest/cp_core/cp_core \
  --workload=B1 --commands=100 --packing=1 --quiet
```

预期 `final_seqnum=100`、`dropped_count=0`、`duplicate_count=0`。

## 步骤 8：生成 PPA Verilog 输入

```bash
cd /home/houdong/vortex
mkdir -p results/exp08/ppa/{priority,aging}
/home/houdong/tool/sv2v/bin/sv2v-Linux/sv2v \
  --top=VX_cp_arbiter_top -D VX_CFG_XLEN=32 -D VX_CFG_XLEN_32 \
  -I build/hw -I sw -I hw -I hw/rtl -I hw/rtl/libs \
  -I hw/rtl/interfaces -I hw/rtl/mem -I hw/rtl/fpu \
  -I hw/rtl/core -I hw/rtl/cp -I hw/unittest/cp_arbiter \
  hw/rtl/VX_gpu_pkg.sv hw/rtl/VX_trace_pkg.sv \
  hw/rtl/cp/VX_cp_pkg.sv hw/rtl/cp/VX_cp_arbiter.sv \
  hw/unittest/cp_arbiter/VX_cp_arbiter_top.sv \
  --write results/exp08/ppa/arbiter_default.v
```

复制成 `priority/arbiter_input.v` 和 `aging/arbiter_input.v`，将顶层参数分别固定为 `(ENABLE_PRIORITY=1, ENABLE_AGING=0)` 和 `(1,1)`。

## 步骤 9：运行 FPGA 代理综合

```bash
export PATH=/home/houdong/tool/yosys/bin:$PATH
/home/houdong/tool/yosys/bin/yosys \
  -l results/exp08/ppa/priority/fpga_yosys.log \
  -p 'read_verilog -defer results/exp08/ppa/priority/arbiter_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_arbiter_top; stat'
/home/houdong/tool/yosys/bin/yosys \
  -l results/exp08/ppa/aging/fpga_yosys.log \
  -p 'read_verilog -defer results/exp08/ppa/aging/arbiter_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_arbiter_top; stat'
rg 'Estimated number of LCs|FDRE' results/exp08/ppa/{priority,aging}/fpga_yosys.log
```

## 步骤 10：运行 ASIC 面积和时序代理

使用 `hw/syn/yosys/run_synth.sh`，设置 `TOP=VX_cp_arbiter_top`、NanGate typical liberty、`CLOCK_FREQ=400`，分别综合两份输入。若本机 Yosys 0.9 报 `Unsupported technology: cmos`，从生成的 `synth.ys` 中删除 `-tech cmos` 后重跑。随后执行：

```bash
TOP=VX_cp_arbiter_top \
NETLIST=/home/houdong/vortex/results/exp08/ppa/aging/asic400_out/VX_cp_arbiter_top_mapped.v \
LIB_TGT=/home/houdong/vortex/hw/syn/libs/NangateOpenCellLibrary_typical.lib \
SDC_FILE=/home/houdong/vortex/results/exp08/ppa/aging/asic400_out/VX_cp_arbiter_top.resolved.sdc \
RPT_DIR=/home/houdong/vortex/results/exp08/ppa/aging/asic400_reports \
/home/houdong/tool/opensta/usr/bin/sta hw/syn/yosys/run_sta.tcl
```

Priority 模式使用同一命令，把路径中的 `aging` 替换成 `priority`。汇总结果见 `results/exp08/ppa_metrics.csv`。

## 步骤 11：检查代码和工作区

```bash
cd /home/houdong/vortex
git diff --check
git status --short
```

实验分析见 [`exp08_aging.md`](exp08_aging.md)。
