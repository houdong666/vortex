# 实验六操作与复现命令

## 步骤 1：重新生成构建目录

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/tool
```

本实验修改了测试 Makefile，因此必须重新 configure。

## 步骤 2：运行 Baseline 与 Prefetch 功能测试

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path clean run PREFETCH_DEPTH=1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path clean run PREFETCH_DEPTH=2
```

两组均应输出 `PASSED — 4 scenarios`。

## 步骤 3：运行延迟扫描

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path clean all PREFETCH_DEPTH=1
for latency in 1 5 10 20 50 100; do
  ./hw/unittest/cp_axi_path/cp_axi_path --latency=$latency --benchmark-lines=64
done

env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path clean all PREFETCH_DEPTH=2
for latency in 1 5 10 20 50 100; do
  ./hw/unittest/cp_axi_path/cp_axi_path --latency=$latency --benchmark-lines=64
done
```

切换 `PREFETCH_DEPTH` 时必须执行 `clean`，避免使用上一组 Verilator 生成物。

## 步骤 4：生成关键波形

```bash
mkdir -p /home/houdong/vortex/results/exp06
env OBJCACHE= make -C hw/unittest/cp_axi_path clean all DEBUG=1 PREFETCH_DEPTH=2
VCD_FILE=/home/houdong/vortex/results/exp06/prefetch_wrap.vcd \
  ./hw/unittest/cp_axi_path/cp_axi_path --latency=10
```

## 步骤 5：验证 seqnum

```bash
./hw/unittest/cp_core/cp_core --workload=B1 --commands=1000 --packing=1 --quiet
```

预期：`final_seqnum=1000`、`dropped_count=0`、`duplicate_count=0`。

## 步骤 6：运行相关回归

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_unpack clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dma clean run
```

## 步骤 7：运行 PPA 对照

本次使用并长期保留以下工具：

```text
/home/houdong/tool/yosys/bin/yosys
/home/houdong/tool/yosys/bin/berkeley-abc
/home/houdong/tool/sv2v/bin/sv2v
/home/houdong/tool/opensta/usr/bin/sta
```

先用 `sv2v --top=VX_cp_fetch_top` 将 Fetch、Unpack、AXI interface 和 PPA wrapper 转为 Verilog，再分别生成 `PREFETCH_DEPTH=1/2` 输入。FPGA 代理综合命令的核心形式为：

```bash
PATH=/home/houdong/tool/yosys/bin:/usr/bin:/bin \
  /home/houdong/tool/yosys/bin/yosys \
  -l results/exp06/ppa/baseline/fpga_yosys.log \
  -p 'read_verilog results/exp06/ppa/baseline/cp_fetch_input.v; synth_xilinx -flatten -family xc7 -top VX_cp_fetch_top; stat'
```

Depth=2 使用相同命令，将 `baseline` 替换为 `prefetch`。ASIC 映射使用仓库的 `hw/syn/yosys/run_synth.sh`、NanGate typical Liberty 和 400 MHz 共同目标，时序使用 `hw/syn/yosys/run_sta.tcl`。

## 步骤 8：最终检查

```bash
cd /home/houdong/vortex
git diff --check
git status --short
```

环境中存在 `DEBUG=release` 时，RTL 构建应使用 `env -u DEBUG`；只有生成 VCD 时显式传入 `DEBUG=1`。
