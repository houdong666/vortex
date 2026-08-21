# 实验四操作与复现命令

以下命令均从仓库根目录 `/home/houdong/vortex` 开始执行。实验日期为 2026-08-21。

## 1. 准备构建目录

```bash
cd /home/houdong/vortex
mkdir -p build
cd build
../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools
cd /home/houdong/vortex
```

## 2. 安装并检查本地综合工具

本实验没有写入 `/usr/bin`。Yosys 与 ABC 的 deb 包、sv2v 与 OpenSTA 的归档均保存在 `build/tools/`。已有归档时可按以下方式恢复本地工具树：

```bash
mkdir -p build/tools/yosys-local/root
dpkg-deb -x build/tools/yosys-local/pkgs/yosys_0.9-2_amd64.deb build/tools/yosys-local/root
dpkg-deb -x build/tools/yosys-local/pkgs/berkeley-abc_1.01+20211229git48498af+dfsg-2_amd64.deb build/tools/yosys-local/root

mkdir -p build/tools/yosys/bin
ln -sf ../../yosys-local/root/usr/bin/yosys build/tools/yosys/bin/yosys
ln -sf ../../yosys-local/root/usr/bin/berkeley-abc build/tools/yosys/bin/yosys-abc
```

检查版本：

```bash
build/tools/yosys/bin/yosys -V
build/tools/yosys-local/root/usr/bin/berkeley-abc -h
build/tools/sv2v/bin/sv2v --version
build/tools/sta/sta/bin/sta -version
```

本次实际版本为 Yosys 0.9、sv2v v0.0.13-3-g80a2f0c 和 OpenSTA 2.7.0。

## 3. 运行功能与性能测试

仓库规则要求测试从生成后的 `build/` 目录运行：

```bash
cd /home/houdong/vortex/build

env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=1

env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean run
```

保存完整日志时使用：

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0 \
  > /home/houdong/vortex/results/exp04/baseline.log 2>&1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=1 \
  > /home/houdong/vortex/results/exp04/fastpath.log 2>&1
```

## 4. 生成 100 条 NOP 波形

```bash
cd /home/houdong/vortex/build

env OBJCACHE= make -C hw/unittest/cp_engine clean all DEBUG=1 NOP_FAST_PATH=0
VCD_FILE=/home/houdong/vortex/results/exp04/nop_baseline.vcd \
  env OBJCACHE= make -C hw/unittest/cp_engine run DEBUG=1 \
  NOP_FAST_PATH=0 OPTS=--nop-count=100

env OBJCACHE= make -C hw/unittest/cp_engine clean all DEBUG=1 NOP_FAST_PATH=1
VCD_FILE=/home/houdong/vortex/results/exp04/nop_fastpath.vcd \
  env OBJCACHE= make -C hw/unittest/cp_engine run DEBUG=1 \
  NOP_FAST_PATH=1 OPTS=--nop-count=100
```

## 5. 将真实 SystemVerilog RTL 转换为综合输入

Yosys 0.9 不能直接完整解析本设计的 package/interface，因此先用 sv2v 转换。`-v` 保留来源追踪信息：

```bash
cd /home/houdong/vortex

build/tools/sv2v/bin/sv2v -v --top=VX_cp_engine_top \
  -D VX_CFG_XLEN=32 -D VX_CFG_XLEN_32 \
  -I build/hw -I sw -I hw -I hw/rtl -I hw/rtl/libs \
  -I hw/rtl/interfaces -I hw/rtl/mem -I hw/rtl/fpu \
  -I hw/rtl/core -I hw/rtl/cp -I hw/unittest/cp_engine \
  hw/rtl/VX_gpu_pkg.sv hw/rtl/VX_trace_pkg.sv \
  hw/rtl/cp/VX_cp_pkg.sv hw/rtl/cp/VX_cp_engine_bid_if.sv \
  hw/rtl/cp/VX_cp_engine.sv hw/unittest/cp_engine/VX_cp_engine_top.sv \
  > results/exp04/ppa/cp_engine_sv2v_default.v
```

sv2v 对接口成员保留了多余的顶层前缀。下列机械清理只将其恢复为 generate scope 内的接口线网，不改变 RTL 逻辑。随后生成参数关闭和打开的两份输入：

```bash
cp results/exp04/ppa/cp_engine_sv2v_default.v /tmp/cp_engine_flat.v
sed -i 's/VX_cp_engine_top\.bid_/bid_/g' /tmp/cp_engine_flat.v

sed "s/parameter \[0:0\] ENABLE_NOP_FAST_PATH = 1'b1;/parameter [0:0] ENABLE_NOP_FAST_PATH = 1'b0;/" \
  /tmp/cp_engine_flat.v > results/exp04/ppa/baseline/cp_engine_input.v
sed "s/parameter \[0:0\] ENABLE_NOP_FAST_PATH = 1'b1;/parameter [0:0] ENABLE_NOP_FAST_PATH = 1'b1;/" \
  /tmp/cp_engine_flat.v > results/exp04/ppa/fastpath/cp_engine_input.v
```

## 6. 运行 FPGA LUT/FF 代理综合

ABC 可执行文件必须加入 `PATH`，否则 Yosys 0.9 会报告找不到 `berkeley-abc`：

```bash
export PATH=/home/houdong/vortex/build/tools/yosys-local/root/usr/bin:$PATH

build/tools/yosys/bin/yosys \
  -l results/exp04/ppa/baseline/fpga_yosys.log \
  -p 'read_verilog -defer results/exp04/ppa/baseline/cp_engine_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_engine_top; stat'

build/tools/yosys/bin/yosys \
  -l results/exp04/ppa/fastpath/fpga_yosys.log \
  -p 'read_verilog -defer results/exp04/ppa/fastpath/cp_engine_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_engine_top; stat'
```

检查报告中不存在断线或错误：

```bash
rg 'Estimated number of LCs|FDRE|Warning: Identifier|ERROR' \
  results/exp04/ppa/baseline/fpga_yosys.log \
  results/exp04/ppa/fastpath/fpga_yosys.log
```

## 7. 运行 NanGate 15 nm 面积与时序代理

为两套输入创建 filelist，然后以相同 400 MHz 目标映射：

```bash
printf '%s\n' results/exp04/ppa/baseline/cp_engine_input.v \
  > results/exp04/ppa/baseline/sources.f
printf '%s\n' results/exp04/ppa/fastpath/cp_engine_input.v \
  > results/exp04/ppa/fastpath/sources.f

TOP=VX_cp_engine_top \
SRC_FILE=results/exp04/ppa/baseline/sources.f \
LIB_TGT=/home/houdong/vortex/hw/syn/libs/NangateOpenCellLibrary_typical.lib \
SDC_FILE=/home/houdong/vortex/hw/syn/yosys/project.sdc \
OUT_DIR=results/exp04/ppa/baseline/asic400_out \
RPT_DIR=results/exp04/ppa/baseline/asic400_reports \
RUN_STA=0 CLOCK_FREQ=400 \
YOSYS=/home/houdong/vortex/build/tools/yosys/bin/yosys \
hw/syn/yosys/run_synth.sh
```

Fast Path 使用相同命令，只把路径中的 `baseline` 替换为 `fastpath`。

Ubuntu 的 Yosys 0.9 不支持脚本生成的 `stat -tech cmos`，需删除该报告选项后重跑生成脚本；`stat -liberty` 仍会给出 cell area：

```bash
sed -i 's/ -tech cmos//' \
  results/exp04/ppa/baseline/asic400_out/synth.ys \
  results/exp04/ppa/fastpath/asic400_out/synth.ys

build/tools/yosys/bin/yosys -q \
  -s results/exp04/ppa/baseline/asic400_out/synth.ys \
  -l results/exp04/ppa/baseline/asic400_reports/yosys.log
build/tools/yosys/bin/yosys -q \
  -s results/exp04/ppa/fastpath/asic400_out/synth.ys \
  -l results/exp04/ppa/fastpath/asic400_reports/yosys.log
```

最后运行 OpenSTA：

```bash
TOP=VX_cp_engine_top \
NETLIST=results/exp04/ppa/baseline/asic400_out/VX_cp_engine_top_mapped.v \
LIB_TGT=/home/houdong/vortex/hw/syn/libs/NangateOpenCellLibrary_typical.lib \
SDC_FILE=results/exp04/ppa/baseline/asic400_out/VX_cp_engine_top.resolved.sdc \
RPT_DIR=results/exp04/ppa/baseline/asic400_reports \
build/tools/sta/sta/bin/sta hw/syn/yosys/run_sta.tcl \
  > results/exp04/ppa/baseline/asic400_reports/sta.log 2>&1
```

Fast Path 同样将路径中的 `baseline` 替换为 `fastpath`。提取结果：

```bash
rg 'Chip area' results/exp04/ppa/{baseline,fastpath}/asic400_reports/stat_lib.rpt
rg 'wns max|data arrival time|data required time|slack' \
  results/exp04/ppa/{baseline,fastpath}/asic400_reports/sta.log
```

## 8. 最终结果与决策

- Baseline：211 estimated LCs、359 FDRE、2703.092 um^2、Fmax proxy 389.35 MHz。
- Fast Path：220 estimated LCs、359 FDRE、2698.304 um^2、Fmax proxy 364.30 MHz。
- NOP CPC 从 3.0 降到 2.0，改善 33.33%。
- Fmax proxy 下降 6.43%，超过指导书的 2% 重新评估线。

结论为：功能验证通过，但拒绝作为整机默认配置；保留参数化实验实现，并保持 `ENABLE_NOP_FAST_PATH=0` 的默认值。
