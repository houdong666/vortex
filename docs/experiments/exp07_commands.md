# 实验7操作与逐步复现命令

本文按实际实施顺序记录 Priority-Aware Arbitration 的修改、测试、波形和 PPA 命令。

## 步骤1 1：重新配置构建目录

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/tool
```

## 步骤 2：检查优先级传递路径

```bash
cd /home/houdong/vortex
rg -n "bid_priority|priority_|VX_cp_arbiter" \
  hw/rtl/cp hw/unittest/cp_arbiter
```

确认 `q_state.prio -> VX_cp_engine.bid_*.priority_ -> VX_cp_arbiter.bid_priority`已连通，问题在于原仲裁器没有使用该输入。

## 步骤 3：实现优先级仲裁

修改：

```text
hw/rtl/cp/VX_cp_arbiter.sv
hw/rtl/cp/VX_cp_core.sv
```

实现顺序：

```text
扫描有效请求得到 highest_priority
-> 生成最高优先级 eligible 掩码
-> 从 rr_pointer 开始环形选择
-> 授权后指针移到获胜者之后
```

检查修改：

```bash
git diff -- hw/rtl/cp/VX_cp_arbiter.sv hw/rtl/cp/VX_cp_core.sv
```

## 步骤 4：运行 Priority Test A/B/C

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean run \
  PRIORITY_ARBITRATION=1
```

预期结果：

```text
Test A: Q0/Q1/Q2/Q3 = 100/100/100/100, fairness_error=0
Test B: Q0/Q1 = 0/128
Test C: Q0/Q1/Q2/Q3 = 0/64/64/0
status=PASS
```

## 步骤 5：运行 Baseline RR 对照

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean run \
  PRIORITY_ARBITRATION=0
```

预期 Test B 中 Q0/Q1 各 64 次，Test C 中四个队列各 32 次。

## 步骤 6：自动生成日志和 CSV

```bash
cd /home/houdong/vortex
python3 results/exp07/run_exp07.py
```

输出：

```text
results/exp07/baseline.log
results/exp07/priority.log
results/exp07/grant_metrics.csv
```

## 步骤 7：生成关键波形

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean all \
  DEBUG=1 PRIORITY_ARBITRATION=1

VCD_FILE=/home/houdong/vortex/results/exp07/priority_arbiter.vcd \
  ./hw/unittest/cp_arbiter/cp_arbiter
```

用 GTKWave 查看：

```bash
gtkwave /home/houdong/vortex/results/exp07/priority_arbiter.vcd
```

建议添加：`bid_valid`、`bid_priority`、`rr_pointer`、`selected_queue`、`bid_grant`。

## 步骤 8：运行资源路径回归

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run \
  NOP_FAST_PATH=0

env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean all
./hw/unittest/cp_core/cp_core \
  --workload=B1 --commands=100 --packing=1 --quiet
```

`cp_engine` Smoke 覆盖 KMU、DMA、DCR、EVENT 请求分类和Priority传递；`cp_core` 验证完整RTL仍可编译运行。

## 步骤 9：生成 PPA 输入

```bash
cd /home/houdong/vortex
mkdir -p results/exp07/ppa/{baseline,priority}

/home/houdong/tool/sv2v/bin/sv2v-Linux/sv2v \
  --top=VX_cp_arbiter_top \
  -D VX_CFG_XLEN=32 -D VX_CFG_XLEN_32 \
  -I build/hw -I sw -I hw -I hw/rtl -I hw/rtl/libs \
  -I hw/rtl/interfaces -I hw/rtl/mem -I hw/rtl/fpu \
  -I hw/rtl/core -I hw/rtl/cp -I hw/unittest/cp_arbiter \
  hw/rtl/VX_gpu_pkg.sv hw/rtl/VX_trace_pkg.sv \
  hw/rtl/cp/VX_cp_pkg.sv hw/rtl/cp/VX_cp_arbiter.sv \
  hw/unittest/cp_arbiter/VX_cp_arbiter_top.sv \
  --write results/exp07/ppa/arbiter_default.v
```

分别将顶层 `ENABLE_PRIORITY` 参数固定为 0 和 1，生成：

```text
results/exp07/ppa/baseline/arbiter_input.v
results/exp07/ppa/priority/arbiter_input.v
```

## 步骤 10：运行 FPGA 逻辑资源代理综合

```bash
export PATH=/home/houdong/tool/yosys/bin:$PATH

/home/houdong/tool/yosys/bin/yosys \
  -l results/exp07/ppa/baseline/fpga_yosys.log \
  -p 'read_verilog -defer results/exp07/ppa/baseline/arbiter_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_arbiter_top; stat'

/home/houdong/tool/yosys/bin/yosys \
  -l results/exp07/ppa/priority/fpga_yosys.log \
  -p 'read_verilog -defer results/exp07/ppa/priority/arbiter_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_arbiter_top; stat'
```

提取：

```bash
rg 'Estimated number of LCs|FDRE' \
  results/exp07/ppa/{baseline,priority}/fpga_yosys.log
```

## 步骤 11：运行 ASIC 面积与时序代理

使用 `hw/syn/yosys/run_synth.sh`，为 Baseline 和 Priority 分别设置：

```text
TOP=VX_cp_arbiter_top
LIB_TGT=hw/syn/libs/NangateOpenCellLibrary_typical.lib
SDC_FILE=hw/syn/yosys/project.sdc
CLOCK_FREQ=400
```

Yosys 0.9 不支持脚本中的 `stat -tech cmos`，生成 `synth.ys` 后删除 `-tech cmos` 选项并重跑 Yosys。然后运行：

```bash
TOP=VX_cp_arbiter_top \
NETLIST=results/exp07/ppa/priority/asic400_out/VX_cp_arbiter_top_mapped.v \
LIB_TGT=/home/houdong/vortex/hw/syn/libs/NangateOpenCellLibrary_typical.lib \
SDC_FILE=results/exp07/ppa/priority/asic400_out/VX_cp_arbiter_top.resolved.sdc \
RPT_DIR=results/exp07/ppa/priority/asic400_reports \
/home/houdong/tool/opensta/usr/bin/sta hw/syn/yosys/run_sta.tcl
```

Baseline 使用相同命令，把路径中 `priority` 替换为 `baseline`。

## 步骤 12：检查代码和工作区

```bash
cd /home/houdong/vortex
git diff --check
git status --short
```

实验结果详见 `docs/experiments/exp07_priority_arbitration.md`。

