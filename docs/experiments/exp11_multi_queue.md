# 实验 11：Multi-Queue 多队列并发

## 1. 为什么做这个实验

实验 7～9 分别验证了 Priority、Aging 和 EVENT_WAIT 公平性，但大部分结论来自仲裁器或事件单元的局部测试。实验 11 要回答两个系统级问题：

1. 四个独立命令队列竞争同一执行资源时，调度策略是否仍然正确，是否存在命令丢失、重复退役或低优先级长时间等待。
2. 四个队列分别使用 DMA、DCR、EVENT、KMU 时，资源能否真实重叠执行，而不是仍被单队列前端串行化。

因此本实验不是简单把 `NUM_QUEUES` 改成 4，而是使用完整 `VX_cp_core`，让每个队列都经过自己的 Ring Fetch、Engine、Tail、Completion 和 Seqnum 路径。

## 2. 实现内容

### 2.1 四队列配置与Ring所有权

测试驱动在 `hw/unittest/cp_multi_queue/main.cpp` 中为 Q0～Q3 分别配置：

```text
独立 ring_base
独立 completion address
独立 tail
独立 seqnum
priority = 0/1/2/3
```

所有Ring和Tail先在 `CP_CTRL.enable=0` 时完成配置，最后统一写 `CP_CTRL=1`。这样四个队列从同一起点启动，避免主机配置顺序伪造优先级结果。

公共 Runtime 现已通过 `CP_DEV_CAPS.NUM_QUEUES` 发现硬件队列数，并在 Device 初始化时为每个 QID 分配独立的 Ring、Head 和 Completion 缓冲区。软件 `Queue` 创建时独占一个空闲 QID，销毁并排空工作线程后归还；软件优先级和 Profiling 开关同步写入该 QID 的 `Q_CONTROL`。

每个 QID 分别维护 Tail、Expected Seqnum、Packing 缓存行和 Batch 状态，因此四个软件 Queue 不会再汇入 Q0。当前不做“软件 Queue 数大于硬件 QID 数”时的时分复用：硬件 QID 用尽后，创建 Queue 明确返回资源不足。

Runtime 并发保护分成三层：

```text
每QID递归锁     → 保护本队列Ring、Tail、Packing和Batch
设备MMIO短锁    → 保护可能不支持多Host线程的后端寄存器回调
设备配置锁      → 保护全局DCR配置到KMU Launch之间不被其他队列插入
```

其中 DMA 等独立命令仍可跨 QID 并发；只有涉及全局 DCR/KMU 状态的配置序列需要串行化。QID 复用时保留单调递增的 Tail 和 Seqnum，不依赖当前尚未接入 CPE 的队列 Reset 脉冲。

### 2.2 修复共享资源忙碌期间的伪授权

实验首先发现一个真实多队列错误：原仲裁器每周期都可能产生授权，但 DMA、DCR、KMU、EVENT 执行单元同一时间只能接受一条命令。如果执行单元忙碌时另一个Engine仍收到 `grant`，它会提前进入 `WAIT_DONE`；前一条命令的广播 `done` 可能让它错误退役。

修复方法：

```text
执行单元 state == IDLE → ready=1
ready=1 且仲裁选中     → grant=1，推进RR指针并清零该队列等待计数
ready=0                → grant=0，保持请求并继续累计等待时间
```

`VX_cp_arbiter` 新增 `grant_enable`，三个原本没有空闲指示的执行单元新增 `ready`。这既保证命令所有权正确，也让Aging把资源忙碌时间计入真实等待时间。

### 2.3 多队列可观测性

`VX_cp_core_top.sv` 新增四队列紧凑调试向量，能够同时观察：

```text
q_enabled
engine_fsm / engine_res
KMU、DMA、DCR、EVENT的bid与grant
retire_evt / retire_ready
各资源done
```

原始VCD见 `results/exp11/multi_queue_parallel.vcd`，便于使用GTKWave查看层级内部的Ring、Head和Seqnum；逐周期紧凑数据见 `multi_queue_timeline.csv`。

## 3. 验证场景

### 3.1 同资源竞争

Q0～Q3各提交4条64B `MEM_COPY`，共16条DMA命令。每个源区域包含不同数据模式，每个目标区域相互独立。分别编译运行：

```text
Round-Robin
Strict Priority
Priority + Aging
```

检查每队列授权次数、平均/最大等待、最终Seqnum、完成内存和DMA目标内容。

### 3.2 不同资源并行

```text
Q0 → 512B MEM_COPY（DMA）
Q1 → DCR_WRITE（DCR）
Q2 → EVENT_SIGNAL（EVENT）
Q3 → LAUNCH（KMU）
```

先分别单独运行四条命令得到 `T_DMA/T_DCR/T_EVT/T_KMU`，再让四队列同时运行得到 `T_parallel`。所有周期均从统一开启CP到完成写回，包含Ring Fetch、执行和Completion开销。

## 4. 实验结果

### 4.1 同DMA竞争

| 模式 | Q0最大等待 | Q1最大等待 | Q2最大等待 | Q3最大等待 | 总周期 | Jain公平指数 |
|---|---:|---:|---:|---:|---:|---:|
| Round-Robin | 35 | 35 | 35 | 35 | 222 | 1.000000 |
| Strict Priority | 113 | 115 | 22 | 9 | 222 | 1.000000 |
| Priority + Aging | 74 | 50 | 35 | 35 | 222 | 1.000000 |

每个队列均获得4次授权并退休4条命令，最终 `seqnum=3`。三种模式均为 `dropped=0`、`duplicate=0`、`dma_ok=1`。

严格优先级明显缩短P3等待，但把P0/P1最大等待提高到113/115周期。加入Aging后，P0最大等待降为74周期，P1降为50周期；代价是P3最大等待由9周期增加到35周期。这证明实验8的Aging机制在完整四队列CP中仍然生效。

Jain指数基于最终服务数量计算。本场景每个队列的命令总数相同且最终都完成，因此指数为1；它证明没有服务份额丢失，但不能单独反映尾延迟，必须与 `max_wait` 一起阅读。

### 4.2 不同资源并行

| 指标 | 周期 |
|---|---:|
| `T_DMA` | 41 |
| `T_DCR` | 17 |
| `T_EVT` | 21 |
| `T_KMU` | 31 |
| `T_serial` | 110 |
| `T_parallel` | 43 |
| `max(T_i)` | 41 |

```text
Speedup = 110 / 43 = 2.558x
T_parallel / max(T_i) = 43 / 41 = 1.049
```

并发总时间只比最慢的DMA单项高2周期，而不是接近110周期，说明四套CP资源路径实现了真实重叠。加速没有达到4倍，是因为四条命令服务时间不同，而且Ring Fetch、Completion以及DMA/EVENT共用的AXI交叉开关仍有少量串行开销。

## 5. 多队列容量PPA

PPA固定Priority、Aging和EVENT公平性开启，只切换`NUM_QUEUES=1/4`，因此测量的是从单队列扩展到四队列的容量成本。

| 指标 | 1 Queue | 4 Queues | 变化 | 每增加1Q平均增量 |
|---|---:|---:|---:|---:|
| FPGA estimated LCs | 6145 | 11406 | +85.61% | 1753.667 |
| FPGA FDRE | 7348 | 11407 | +55.24% | 1353 |
| ASIC cell area | 337524.474 µm² | 406066.556 µm² | +20.31% | 22847.361 µm² |

每个新增QID都需要自己的Fetch、Engine、Ring指针、Completion和队列上下文，因此面积增加是预期结果。DMA、DCR、EVENT和KMU执行单元仍由所有队列共享，所以四队列ASIC面积只增加20.31%，而不是接近4倍。该数据是开源工具面积代理，不包含Vivado布局布线后的Fmax。

机器可读数据见`results/exp11/ppa_metrics.csv`，报告见`results/exp04_11_summary/ppa/{q1_full,q4_full}/`。

## 6. 正确性与回归

- 三种同DMA竞争模式全部PASS，16条命令无丢失、无重复。
- DMA逐字节比较通过，EVENT_SIGNAL的64位事件值正确。
- 混合场景四队列各退休一次，四个Completion均为0。
- `cp_arbiter` Aging回归PASS。
- `cp_event_fairness` Release/Backoff回归PASS。
- `cp_launch`、`cp_dcr_proxy`、`cp_dma`单元回归PASS。
- 单队列完整 `cp_core` B1/100回归PASS：`final_seqnum=100`、`dropped=0`、`duplicate=0`。
- Runtime Mock-CP 四队列测试PASS：Q0～Q3绑定、Priority/Profiling控制位、独立提交、第五个Queue拒绝、QID释放复用均正确。
- Runtime批处理测试PASS：Q2的一条64B Ring缓存行承载两条DCR命令，Seqnum仍按命令数增加2；纯DCR批次不会额外提交COUT读取。
- 64位公共Runtime `stub` 和 `simx` 后端编译通过，SimX `demo` 冒烟测试PASS。
- 实验7 Priority、实验8 Aging、实验9 EVENT_WAIT公平性回归PASS。

本实验已经完成“公共Runtime软件Queue → 独立硬件QID”的代码接入和Host侧功能验证，也完成了Verilator下完整CP RTL集成验证。由于当前环境没有可用的多队列XRT/FPGA板卡，尚未验证真实XRT寄存器端点、Host可见Ring一致性以及板上并发性能，因此不能把Mock和Verilator结果表述成板卡交付结果。

最新统一回归还验证了实验4～9全开组合1000命令、SimX `demo`、RTL `demo`和`sgemm -n16`，全部PASS。状态表位于`results/exp04_11_summary/regression_status.csv`。

## 7. 结论

实验11完成了从“RTL内部支持多队列”到“公共Runtime能分配并使用硬件QID”的关键连接。共享资源在增加 `ready/grant_enable` 后能按Round-Robin、Priority和Aging正确串行服务；互不相同的DMA、DCR、EVENT、KMU资源能够在多队列下真实并行，实测并发加速2.558倍。实验还发现并修复了单队列测试无法暴露的忙碌期伪授权问题，以及纯DCR批次无条件清空COUT造成的额外命令问题。

原始数据位于 `results/exp11/`，RTL逐步复现命令见 [`exp11_commands.md`](exp11_commands.md)，Runtime接入和验证命令见 [`exp11_runtime_commands.md`](exp11_runtime_commands.md)，统一回归与PPA见 [`exp04_11_unified_summary.md`](exp04_11_unified_summary.md)。
