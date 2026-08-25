# 实验 11 操作与逐步复现命令

## 步骤 1：检查现有多队列能力和Runtime边界

```bash
cd /home/houdong/vortex
rg -n "NUM_QUEUES|kmu_valid|dma_valid|dcr_valid|event_valid" \
  hw/rtl/cp/VX_cp_core.sv hw/rtl/cp/VX_cp_axil_regfile.sv
rg -n "cp_ring_|CP_Q_RING_BASE|CP_Q_TAIL|CP_Q_SEQNUM" \
  sw/runtime/common/device.cpp sw/runtime/common/vortex2_internal.h
```

该检查用于定位实验开始时的缺口：RTL已经参数化多队列，但旧公共Runtime只配置Q0并维护一套Device级Ring状态。当前Runtime接入后的实现和复现方法见 [`exp11_runtime_commands.md`](exp11_runtime_commands.md)。

## 步骤 2：修复共享资源忙碌期伪授权

修改文件：

```text
hw/rtl/cp/VX_cp_arbiter.sv
hw/rtl/cp/VX_cp_core.sv
hw/rtl/cp/VX_cp_launch.sv
hw/rtl/cp/VX_cp_dma.sv
hw/rtl/cp/VX_cp_dcr_proxy.sv
```

为执行单元增加 `ready`，为仲裁器增加 `grant_enable`。资源忙碌时保留bid并累计等待，但不产生grant、不推进RR指针。

## 步骤 3：增加四队列完整CP测试驱动

新增：

```text
hw/unittest/cp_multi_queue/Makefile
hw/unittest/cp_multi_queue/main.cpp
```

测试驱动实现四套Ring/Completion/Tail/Seqnum配置、Host/Device AXI内存模型、GPU DCR/Launch模型、授权/等待统计和数据正确性检查。

`hw/unittest/cp_core/VX_cp_core_top.sv` 增加多队列调试向量，`cp_core/Makefile` 增加 `NUM_QUEUES` 参数。

## 步骤 4：重新生成构建目录

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/tool
```

## 步骤 5：手工运行同DMA竞争

Round-Robin：

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_multi_queue clean all \
  PRIORITY_ARBITRATION=0 ARBITRATION_AGING=0
./hw/unittest/cp_multi_queue/cp_multi_queue \
  --scenario=same-dma --commands=4
```

严格优先级：

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_multi_queue clean all \
  PRIORITY_ARBITRATION=1 ARBITRATION_AGING=0
./hw/unittest/cp_multi_queue/cp_multi_queue \
  --scenario=same-dma --commands=4
```

Priority + Aging：

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_multi_queue clean all \
  PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1
./hw/unittest/cp_multi_queue/cp_multi_queue \
  --scenario=same-dma --commands=4
```

检查每个队列 `commands=4`、`grants=4`、`final_seqnum=3`，并确认 `dropped=0 duplicate=0 dma_ok=1`。

## 步骤 6：手工运行跨资源并行测试

```bash
cd /home/houdong/vortex/build
for scenario in isolated-dma isolated-dcr isolated-event isolated-kmu mixed; do
  ./hw/unittest/cp_multi_queue/cp_multi_queue \
    --scenario=${scenario} --quiet
done
```

分别记录五个 `MQ_RESULT` 的 `total_cycles`，计算：

```text
T_serial = T_DMA + T_DCR + T_EVT + T_KMU
Speedup = T_serial / T_parallel
```

## 步骤 7：自动生成全部结果

```bash
cd /home/houdong/vortex
python3 results/exp11/run_exp11.py
```

生成：

```text
results/exp11/contention_metrics.csv
results/exp11/parallelism_metrics.csv
results/exp11/regression_summary.csv
results/exp11/multi_queue_timeline.csv
results/exp11/*.log
```

## 步骤 8：生成并查看VCD波形

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_multi_queue clean all \
  DEBUG=1 PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1
VCD_FILE=/home/houdong/vortex/results/exp11/multi_queue_parallel.vcd \
  ./hw/unittest/cp_multi_queue/cp_multi_queue --scenario=mixed --quiet
gtkwave /home/houdong/vortex/results/exp11/multi_queue_parallel.vcd
```

重点观察 `dbg_*_valid_all`、`dbg_*_grant_all`、`dbg_engine_fsm_all`、`dbg_retire_evt_all`、四个 `g_cpe` 的Fetch/Engine状态以及四个Seqnum。

## 步骤 9：运行受影响单元和单队列完整CP回归

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_arbiter clean run \
  PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_event_fairness clean run \
  EVENT_WAIT_FAIRNESS=1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_launch clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dcr_proxy clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dma clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean all \
  NUM_QUEUES=1 PRIORITY_ARBITRATION=1 ARBITRATION_AGING=1 \
  EVENT_WAIT_FAIRNESS=1
./hw/unittest/cp_core/cp_core \
  --workload=B1 --commands=100 --packing=1 --quiet
```

## 步骤 10：运行Runtime与统一回归

```bash
cd /home/houdong/vortex/build64
make -C sw/runtime/stub -j2
make -C tests/unittest/cp_runtime_multi_queue clean run

cd /home/houdong/vortex
results/exp04_11_summary/run_regression.sh
```

## 步骤 11：运行一队列/四队列PPA

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_ppa.sh
cat results/exp11/ppa_metrics.csv
```

该对照固定Priority、Aging和EVENT公平性，只改变`NUM_QUEUES`，所以结果表示多队列容量成本。

## 步骤 12：检查修改

```bash
cd /home/houdong/vortex
git diff --check
git status --short
```

实验原理、数据解释和限制见 [`exp11_multi_queue.md`](exp11_multi_queue.md)，Runtime多QID接入步骤见 [`exp11_runtime_commands.md`](exp11_runtime_commands.md)，统一结论见 [`exp04_11_unified_summary.md`](exp04_11_unified_summary.md)。
