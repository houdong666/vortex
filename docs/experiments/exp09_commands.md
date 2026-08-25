# 实验 9 操作与逐步复现命令

## 步骤 1：重新生成构建目录

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/tool
```

## 步骤 2：检查 EVENT_WAIT 原始路径

```bash
cd /home/houdong/vortex
rg -n "EVENT_WAIT|S_REQ_AR|S_WAIT_R|event_done" \
  hw/rtl/cp/VX_cp_event_unit.sv hw/rtl/cp/VX_cp_engine.sv hw/rtl/cp/VX_cp_core.sv
```

确认原实现比较失败后直接从 `S_WAIT_R` 回到 `S_REQ_AR`，命令没有释放 EVENT 单元。

## 步骤 3：实现 Release/Retry/Backoff

修改：

```text
hw/rtl/cp/VX_cp_event_unit.sv
hw/rtl/cp/VX_cp_engine.sv
hw/rtl/cp/VX_cp_core.sv
```

实现 `ready` 资源门控、`S_RETRY` 脉冲和 `S_EVENT_BACKOFF` 重新竞标。所有新增关键逻辑均带中文注释。

## 步骤 4：构建并运行四队列对照测试

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_event_fairness clean run \
  EVENT_WAIT_FAIRNESS=0
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_event_fairness clean run \
  EVENT_WAIT_FAIRNESS=1
```

基线预期 SIGNAL 在 WAIT 之后退休；公平模式预期 Q1/Q2/Q3 在第 100 周期释放 X 以前退休。

## 步骤 5：自动生成日志和 CSV

```bash
cd /home/houdong/vortex
python3 results/exp09/run_exp09.py
```

生成：

```text
results/exp09/baseline.log
results/exp09/fairness.log
results/exp09/event_fairness_metrics.csv
```

## 步骤 6：生成和查看波形

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_event_fairness clean all \
  DEBUG=1 EVENT_WAIT_FAIRNESS=1
VCD_FILE=/home/houdong/vortex/results/exp09/event_wait_fairness.vcd \
  ./hw/unittest/cp_event_fairness/cp_event_fairness
gtkwave /home/houdong/vortex/results/exp09/event_wait_fairness.vcd
```

重点观察 `event_bid`、`event_grant`、`event_ready`、`event_retry`、`event_done`、`retire_evt` 和 `u_event.state`。

## 步骤 7：运行原有 Engine 和完整 CP 回归

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean all \
  EVENT_WAIT_FAIRNESS=1
./hw/unittest/cp_core/cp_core \
  --workload=B1 --commands=100 --packing=1 --quiet
```

预期 `final_seqnum=100`、`dropped_count=0`、`duplicate_count=0`。

## 步骤 8：运行完整CP PPA

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_ppa.sh
cat results/exp09/ppa_metrics.csv
```

脚本固定四队列、Priority和Aging开启，只切换EVENT公平性开关。PPA结果使用完整CP顶层，不能与仅综合单个EVENT单元的数据混用。

## 步骤 9：运行最新统一回归

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_regression.sh
cat results/exp04_11_summary/regression_status.csv
```

## 步骤 10：检查最终修改

```bash
cd /home/houdong/vortex
git diff --check
git status --short
```

实验分析见 [`exp09_event_wait_fairness.md`](exp09_event_wait_fairness.md)，实验4～11统一结论见 [`exp04_11_unified_summary.md`](exp04_11_unified_summary.md)。
