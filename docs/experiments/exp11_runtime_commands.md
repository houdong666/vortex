# 实验11：Runtime多硬件队列接入与复现命令

本文记录公共 Runtime 从“所有软件 Queue 共用 Q0”改为“每个软件 Queue 独占一个硬件 QID”的实现过程。命令均以仓库 `/home/houdong/vortex` 为例。

## 步骤1：确认软硬件接口

```bash
cd /home/houdong/vortex
rg -n "DEV_CAPS|NUM_QUEUES|Q_CONTROL|Q_TAIL|Q_SEQNUM" \
  hw/rtl/cp sw/runtime/common
rg -n "class Queue|cp_ring_|cp_tail_|cp_expected_seqnum_" \
  sw/runtime/common
```

检查结论：RTL通过能力寄存器报告硬件队列数，每个QID的寄存器块间隔为`0x40`；旧Runtime只有一套Device级Ring、Tail、Seqnum和Packing状态，所以多个软件Queue最终仍共用Q0。

## 步骤2：先写接入方案

新增：

```text
docs/proposals/cp_runtime_multi_queue_proposal.md
```

方案明确四项约束：软件Queue生命周期内独占QID；每QID拥有独立提交状态；DCR/KMU配置序列需要设备级互斥；当前不实现软件Queue超量复用。

## 步骤3：把Device提交状态改成每QID一份

修改：

```text
sw/runtime/common/vortex2_internal.h
sw/runtime/common/device.cpp
```

新增`CpQueueState`，每个硬件队列保存：

```text
Ring / Head / Completion
Tail / Expected Seqnum
Pending Packing Line
Batch Target / Batch State
Assigned State / Queue Lock
```

`cp_init()`先读取`CP_DEV_CAPS.NUM_QUEUES`，再为所有QID分配并配置缓冲区。Q0保留给兼容路径使用，其他QID在软件Queue绑定时启用。

所有CP提交函数增加可选`qid`参数，默认值仍为0，因此旧调用路径保持兼容。写Ring、敲对应QID门铃和轮询对应Seqnum都使用同一个QID。

## 步骤4：实现软件Queue到硬件QID的绑定

修改：

```text
sw/runtime/common/queue.cpp
sw/runtime/common/buffer.cpp
```

`vx_queue_create()`申请空闲QID，将Queue Priority和Profiling位写入该QID的`Q_CONTROL`；Queue工作线程提交DMA、DCR、Launch、Draw、Map和Unmap时都携带自己的QID。Queue析构先排空工作线程，再释放QID。

QID复用时不清零Tail和Seqnum，而是从原值继续单调推进。这样可避免依赖当前尚未连接到CPE内部状态机的硬件Reset脉冲。

## 步骤5：处理跨队列并发边界

Runtime使用三类锁：

```text
每QID递归锁：保护本队列Ring、Packing和Batch
设备MMIO短锁：避免多个Host线程并发调用非线程安全后端
设备配置锁：保护全局DCR配置与随后KMU Launch的原子关系
```

每QID锁只约束同一个Ring，所以不同QID的DMA等命令仍可并发。设备配置锁只用于DCR/KMU相关序列，防止Queue A写了一半启动参数时被Queue B插入全局DCR写。

批处理结束时只在批次包含Launch或Draw时清空COUT。纯DCR批次不产生控制台输出，不再额外插入两条COUT读取命令。

## 步骤6：增加Runtime功能测试

新增：

```text
tests/unittest/cp_runtime_multi_queue/Makefile
tests/unittest/cp_runtime_multi_queue/mock_backend.cpp
tests/unittest/cp_runtime_multi_queue/main.cpp
```

Mock-CP报告4个硬件QID，并分别模拟Ring寄存器、Tail、Seqnum和Completion。测试验证：

1. 四个软件Queue分别占用Q0～Q3。
2. Priority和Profiling正确写入`Q_CONTROL`。
3. 第五个Queue在QID耗尽时创建失败。
4. 四个Host工作线程向四个Ring独立提交命令。
5. 两条DCR命令能Packing到同一64B缓存行，但Seqnum仍增加2。
6. Queue释放后QID可复用，Tail和Seqnum保持单调。

## 步骤7：重新生成64位构建目录

```bash
cd /home/houdong/vortex/build64
../configure --xlen=64 --tooldir=/home/houdong/tool
```

修改Runtime源码通常会被Makefile直接捕获；新增测试目录或修改构建清单后必须重新执行`configure`，避免生成树过期。

## 步骤8：编译公共Runtime

```bash
cd /home/houdong/vortex/build64
make -C sw/runtime/stub -j2
make -C sw/runtime/simx -j2 DEBUG=0
```

本机环境变量`DEBUG=release`会被编译器当成非法宏值，因此SimX编译显式使用`DEBUG=0`。这属于环境配置问题，不是Runtime源代码错误。

## 步骤9：运行Runtime四队列测试

```bash
cd /home/houdong/vortex/build64
make -C tests/unittest/cp_runtime_multi_queue clean run
```

通过标志：

```text
PASS: Runtime四队列绑定、优先级、提交和复用
```

## 步骤10：运行SimX单队列兼容性冒烟

```bash
cd /home/houdong/vortex/build64
./ci/blackbox.sh --driver=simx --app=demo
```

SimX当前能力字只报告一个硬件队列，因此这一步验证默认Q0兼容路径没有被破坏，不代表SimX已经具备多队列时序模型。

## 步骤11：运行实验4～11统一回归

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_regression.sh
cat results/exp04_11_summary/regression_status.csv
```

实验11关键结果仍为：

```text
T_serial   = 110 cycles
T_parallel = 43 cycles
Speedup    = 2.558x
```

## 步骤12：运行实验9和11 PPA

```bash
cd /home/houdong/vortex
results/exp04_11_summary/run_ppa.sh
cat results/exp09/ppa_metrics.csv
cat results/exp11/ppa_metrics.csv
```

## 步骤13：检查代码和工作区

```bash
cd /home/houdong/vortex
git diff --check
git status --short
git diff --stat
```

重点确认没有空白错误、构建产物没有进入源码目录，并审查所有Runtime、RTL、测试、实验文档和结果文件。

## 当前完成边界

已完成公共Runtime的QID发现、分配、独立状态、优先级配置、并发保护、提交路由、Packing和QID复用，并通过Mock-CP、SimX兼容路径及实验7～11回归。

尚未完成的是多队列XRT/FPGA真板验证。后续需要在具备4Q CP位流的板卡上检查XRT寄存器偏移、Host可见Ring缓存一致性、四Queue端到端正确性和真实并发吞吐；不能用Mock或Verilator结果代替该门禁。
