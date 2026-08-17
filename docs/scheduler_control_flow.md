# Vortex Warp 调度控制流程学习笔记

这份文档用于学习 Vortex RTL 中的 warp 调度控制流：数据从哪里来、经过哪些模块、各个接口/函数/模块各自负责什么，以及 scheduler 如何根据流水线反馈更新每个 warp 的状态。

文档重点面向调度策略研究。信号名、模块名、结构体名保持代码原名，便于对照源码阅读。

## 1. 总体心智模型

`VX_scheduler` 是 core 前端的 per-warp 取指状态管理器。它本身不执行指令，也不决定一条指令能否提交。它主要负责：

- 记录哪些 warp 当前驻留在 core 中：`active_warps`
- 记录哪些 active warp 暂时不能继续取指：`stalled_warps`
- 记录每个 warp 下一次取指要用的 `PC`：`warp_pcs`
- 记录每个 warp 下一条指令的线程掩码：`thread_masks`
- 从 ready warp 中选择一个 warp，发给 fetch：`{wid, cta_id, PC, tmask, uuid}`
- 接收 decode、execute、commit、CTA dispatch、barrier、split/join 的反馈，更新上述 per-warp 状态

顶层连接在 [`VX_core.sv`](../hw/rtl/core/VX_core.sv)。核心数据流如下：

```text
KMU
  |
  v
VX_cta_dispatch
  | cta_fire / cta_wid / cta_PC / cta_tmask / cta_param
  v
VX_scheduler
  | schedule_if: valid, data, ready, ibuf_pop
  v
VX_fetch
  | fetch_if
  v
VX_decode ---------------> decode_sched_if
  | decode_if                    |
  v                              |
VX_issue ----------------> issue_sched_if
  | dispatch_if                  |
  v                              |
VX_execute --------------> branch_ctl_if, warp_ctl_if
  | commit_if                    |
  v                              |
VX_commit ---------------> commit_sched_if
```

可以把 scheduler 理解成一个闭环控制器：

1. Scheduler 选择一个 warp 送去 fetch。
2. 这个 warp 会立刻被置为 stalled，避免过早再次取指。
3. Decode 如果发现这是普通指令，会很快 unlock 该 warp。
4. Decode 如果发现这是分支、barrier、split、join、TMC 等控制类指令，就不会立即 unlock，而是等 execute 阶段反馈。
5. Execute 通过 `branch_ctl_if` 或 `warp_ctl_if` 修改 PC/tmask/barrier/split 状态，并解锁 warp。
6. Commit 通过 `commit_sched_if` 告诉 scheduler 哪些 warp 的指令提交了，用于 pending 计数和 `instret`。

## 2. 建议阅读顺序

按下面顺序读，比直接啃 `VX_scheduler.sv` 更容易建立全局图：

- [`VX_core.sv`](../hw/rtl/core/VX_core.sv)：实例化并连接 scheduler、fetch、decode、issue、execute、commit。
- [`VX_schedule_if.sv`](../hw/rtl/interfaces/VX_schedule_if.sv)：scheduler 到 fetch 的请求接口。
- [`VX_decode_sched_if.sv`](../hw/rtl/interfaces/VX_decode_sched_if.sv)：decode 回 scheduler 的 unlock/PC 更新接口。
- [`VX_issue_sched_if.sv`](../hw/rtl/interfaces/VX_issue_sched_if.sv)：issue 回 scheduler 的 pending 计数接口。
- [`VX_commit_sched_if.sv`](../hw/rtl/interfaces/VX_commit_sched_if.sv)：commit 回 scheduler 的提交掩码接口。
- [`VX_branch_ctl_if.sv`](../hw/rtl/interfaces/VX_branch_ctl_if.sv)：ALU 分支执行回 scheduler 的 PC 修正接口。
- [`VX_warp_ctl_if.sv`](../hw/rtl/interfaces/VX_warp_ctl_if.sv)：SFU warp-control 指令回 scheduler 的控制接口。
- [`VX_scheduler.sv`](../hw/rtl/core/VX_scheduler.sv)：调度状态、状态更新、仲裁策略。
- [`VX_fetch.sv`](../hw/rtl/core/VX_fetch.sv)：消费 `schedule_if`，发 icache 请求，返回 `fetch_if`。
- [`VX_decode.sv`](../hw/rtl/core/VX_decode.sv)：译码，并产生 `decode_sched_if`。
- [`VX_issue.sv`](../hw/rtl/core/VX_issue.sv) 和 [`VX_issue_slice.sv`](../hw/rtl/core/VX_issue_slice.sv)：ibuffer、scoreboard、operands、dispatcher，以及 issue 反馈。
- [`VX_execute.sv`](../hw/rtl/core/VX_execute.sv)：连接 ALU/LSU/SFU/FPU，并向 scheduler 暴露 branch/warp-control 反馈。
- [`VX_wctl_unit.sv`](../hw/rtl/core/VX_wctl_unit.sv)：把 SFU 控制指令转换成 `warp_ctl_if`。
- [`VX_alu_int.sv`](../hw/rtl/core/VX_alu_int.sv)：把分支、trap、MRET 结果转换成 `branch_ctl_if`。
- [`VX_commit.sv`](../hw/rtl/core/VX_commit.sv)：把各执行单元的 commit 结果整理成 per-warp committed mask。
- [`VX_cta_dispatch.sv`](../hw/rtl/core/VX_cta_dispatch.sv)：为新 CTA 分配 wid，并维护 wid 到 CTA id 的映射。
- [`VX_bar_unit.sv`](../hw/rtl/core/VX_bar_unit.sv)：维护 barrier 等待集合和释放掩码。
- [`VX_split_join.sv`](../hw/rtl/core/VX_split_join.sv)：维护分支发散/重汇聚栈。
- [`VX_priority_encoder.sv`](../hw/rtl/libs/VX_priority_encoder.sv)：当前固定优先级调度策略使用的基础模块。

## 3. Scheduler 周围的关键接口

### 3.1 `VX_schedule_if`

定义在 [`VX_schedule_if.sv`](../hw/rtl/interfaces/VX_schedule_if.sv)。

字段：

- `valid`：scheduler 有一个 warp 取指请求。
- `data`：类型是 `schedule_t`，定义在 [`VX_gpu_pkg.sv`](../hw/rtl/VX_gpu_pkg.sv)，包含 `uuid`、`wid`、`cta_id`、`tmask`、`PC`。
- `ready`：fetch 侧可以接收请求。
- `ibuf_pop`：从 issue ibuffer 返回的 pop 信号，每个 warp 一位。

这里要区分两个握手：

- `schedule_fire = schedule_valid && schedule_ready`：scheduler 内部选中的 warp 被放入输出 buffer。
- `schedule_if_fire = schedule_if.valid && schedule_if.ready`：输出 buffer 中的请求真正被 fetch 接收。

这个区别很重要：`stalled_warps[schedule_wid]` 在 `schedule_fire` 时置位；非 RVC 配置下 PC 前进使用 `schedule_if_fire`。

### 3.2 `VX_decode_sched_if`

定义在 [`VX_decode_sched_if.sv`](../hw/rtl/interfaces/VX_decode_sched_if.sv)。

字段：

- `valid`：decode 已经处理了某个 warp 的取指结果。
- `wid`：对应 warp id。
- `unlock`：是否清除 `stalled_warps[wid]`。
- `is_rvc`：启用压缩指令时，用于告诉 scheduler PC 前进 2 字节还是 4 字节。

普通指令通常会在 decode 阶段 unlock。控制类指令不会，因为它们需要等 execute 阶段计算完 PC/tmask/barrier 等状态。

### 3.3 `VX_issue_sched_if`

定义在 [`VX_issue_sched_if.sv`](../hw/rtl/interfaces/VX_issue_sched_if.sv)。

字段：

- `valid`：某个 issue slice 的 scoreboard 接受了一条指令。
- `wis`：warp 在该 issue slice 内部的编号。

Scheduler 用它增加 per-warp pending 计数。它不参与选择下一个 warp。

### 3.4 `VX_commit_sched_if`

定义在 [`VX_commit_sched_if.sv`](../hw/rtl/interfaces/VX_commit_sched_if.sv)。

字段：

- `committed_warps`：每个 warp 一位，表示该 warp 有一条 `eop` 指令提交。

Scheduler 用它更新 `instret`，并减少 per-warp pending 计数。

### 3.5 `VX_branch_ctl_if`

定义在 [`VX_branch_ctl_if.sv`](../hw/rtl/interfaces/VX_branch_ctl_if.sv)。

由 ALU 分支执行逻辑产生，告诉 scheduler：

- 分支结果有效：`valid`
- 属于哪个 warp：`wid`
- 是否 taken：`taken`
- 目标 PC：`dest`
- 是否 trap entry：`is_trap`
- 是否 MRET/SRET/URET 类返回：`is_mret`
- trap cause：`trap_cause`

Scheduler 用它修正 `warp_pcs[wid]` 并清除该 warp 的 stalled bit。

### 3.6 `VX_warp_ctl_if`

定义在 [`VX_warp_ctl_if.sv`](../hw/rtl/interfaces/VX_warp_ctl_if.sv)。

由 SFU 的 `VX_wctl_unit` 产生，承载 warp-control 指令事件：

- `tmc_valid`：更新 tmask；如果 tmask 为 0，则该 warp retire。
- `wspawn_valid`：激活新的 warp。
- `split_valid`：处理分支发散。
- `sjoin_valid`：处理重汇聚。
- `bar_valid`：处理 barrier arrive/wait/event。
- `wsync_valid`：当前 warp 等待前序指令 drain 完成。

它也有 scheduler 返回给 SFU 的信号：

- `warp_pending_alm_empty`：每个 warp 的 pending 计数接近空，用于 `WSYNC`。
- `lsu_sched_drained`：LSU scheduler 是否全空，用于 barrier memory fence。
- `dvstack_ptr`：split/join 栈指针读回。
- `bar_phase`：barrier phase 读回。

## 4. Scheduler 内部核心状态

`VX_scheduler.sv` 中最重要的寄存器：

- `active_warps`：当前驻留 warp 集合。`cta_fire` 或 `WSPAWN` 会置位；`TMC tmask=0` 会清零。
- `stalled_warps`：当前不能继续取指的 active warp 集合。注意它只是前端调度阻塞，不代表 warp 没有在流水线中执行。
- `thread_masks`：每个 warp 下一条取指要使用的线程掩码。
- `warp_pcs`：每个 warp 下一条取指 PC。
- `mscratch_r`：每个 warp 的参数/临时 CSR 数据。
- trap CSR：`mstatus_r`、`mtvec_r`、`mepc_r`、`mcause_r`、`mtval_r`、`mscratch_tmask_r`。
- `ibuf_full`：scheduler 估计的每个 warp 下游 ibuffer 是否满。
- `pending_warp_empty` / `pending_warp_alm_empty`：每个 warp issue 后尚未 commit 的指令计数状态。

核心 ready 定义非常简单：

```systemverilog
ready_warps = active_warps & ~stalled_warps;
```

也就是说，一个 warp 必须 active 且不 stalled，才可能被 scheduler 选择。

## 5. CTA 如何变成 Active Warp

`VX_cta_dispatch` 从 KMU 接收 CTA 启动信息，把一个 CTA 拆成多个 warp。

它输出给 scheduler：

- `cta_fire`：本周期有一个新 warp 发给 scheduler。
- `cta_wid`：为该 warp 分配的 wid。
- `cta_PC`：初始 PC。
- `cta_tmask`：完整或部分线程掩码。
- `cta_param`：kernel 参数，写入 `mscratch_r[cta_wid]`。
- `cta_init`：是否需要执行一次性 kernel prologue。

Scheduler 中对应逻辑：

```systemverilog
if (cta_fire) begin
    active_warps_n[cta_wid] = 1;
    warp_pcs_n[cta_wid] = cta_init ? cta_PC : (warp_pcs[cta_wid] - from_fullPC(`VX_CFG_XLEN'(20)));
    thread_masks_n[cta_wid] = cta_tmask;
end
```

`VX_cta_dispatch` 还维护 wid 到 CTA slot/id 的映射。Scheduler 输入 `schedule_wid`，CTA dispatcher 输出 `schedule_cta_id`，最终一起打包进 `schedule_if.data`。

Warp retire 的入口是：

```systemverilog
cta_warp_done = warp_ctl_if.tmc_valid && (warp_ctl_if.tmc.tmask == 0);
```

所以 kernel 退出最终会表现为 `TMC tmask=0`，该 warp 从 `active_warps` 中清除。

## 6. 当前固定优先级调度策略

当前调度选择逻辑在 `VX_scheduler.sv` 的 `schedule the next ready warp` 段。

第一步：找 ready warp。

```systemverilog
ready_warps = active_warps & ~stalled_warps;
```

第二步：优先选择 ibuffer 没满的 warp。

```systemverilog
preferred_warps = ready_warps & ~ibuf_full;
```

第三步：构造真正送入仲裁器的候选集合。

启用 L1 时：

```systemverilog
schedule_warps = all_ibuf_full ? ready_warps : preferred_warps;
```

未启用 L1 时：

```systemverilog
schedule_warps = preferred_warps;
```

第四步：用 `VX_priority_encoder` 选择 wid。

```systemverilog
VX_priority_encoder wid_select (
    .data_in(schedule_warps),
    .index_out(schedule_wid),
    .valid_out(schedule_valid),
    .onehot_out(schedule_onehot)
);
```

`VX_priority_encoder` 默认 `REVERSE=0`，即 LSB 优先。因为 wid 0 对应最低位，所以当前策略是固定优先级：多个 warp 同时 ready 时，最低 wid 获胜。

要实现 Round-Robin，最干净的位置就是替换这段 `VX_priority_encoder` 选择逻辑，但要保持输出语义：

- `schedule_wid`
- `schedule_valid`
- `schedule_onehot`

RR 指针应该在 `schedule_fire` 时更新，而不是在 `schedule_valid` 时更新。因为 `schedule_valid=1` 只说明存在候选 warp，不代表该选择已经进入输出 buffer。

## 7. 为什么日志看起来像 Round-Robin

简单测试中常看到：

```text
wid=0,1,2,3,0,1,2,3...
```

这不等于当前策略已经是 Round-Robin。原因是 scheduler 在选择一个 warp 后立刻执行：

```systemverilog
if (schedule_fire) begin
    stalled_warps_n[schedule_wid] = 1;
end
```

被选中的 warp 会临时从 `ready_warps` 中消失，直到 decode 或 execute 反馈解锁它。因此在平衡负载下，下一个 ready 的最低 wid 往往自然变成 `wid+1`。

判断固定优先级是否影响公平性，要观察 `schedule_warps` 同时有多个 bit 为 1 的窗口。如果 `schedule_warps` 多位为 1，而选择总是最低位，那才是当前固定优先级策略的直接证据。

## 8. 一条指令如何流过调度闭环

### 8.1 Scheduler 到 Fetch

Scheduler 选出 `schedule_wid` 后，从 per-warp 表中取：

- `thread_masks[schedule_wid]`
- `warp_pcs[schedule_wid]`
- `schedule_cta_id`
- `instr_uuid`

然后通过 `VX_elastic_buffer` 输出到 `schedule_if`。

Fetch 消费 `schedule_if`，发 icache 请求。为了在 icache response 回来时恢复上下文，`VX_fetch` 用一个 `tag_store` 按 wid 记录 `PC/tmask/cta_id`。

### 8.2 Fetch 到 Decode

`VX_fetch` 收到 icache response 后输出 `fetch_if`。

`VX_decode` 消费 `fetch_if`，解析：

- 执行单元类型：ALU/LSU/SFU/FPU 等
- 操作类型：`op_type`
- 操作参数：`op_args`
- 源/目的寄存器使用情况
- 是否写回
- 是否需要让 warp 继续 stalled：`is_wstall`

Decode 同时向 scheduler 返回：

```systemverilog
decode_sched_valid_r  <= fetch_fire;
decode_sched_unlock_r <= ~is_wstall;
decode_sched_wid_r    <= fetch_if.data.wid;
```

普通指令 `is_wstall=0`，decode 直接 unlock。控制类指令 `is_wstall=1`，warp 继续 stalled，等待 execute 阶段的控制反馈。

典型 `is_wstall=1` 指令：

- `JAL/JALR/BRANCH`
- trap entry / MRET 类系统控制流
- `TMC`
- `WSPAWN`
- `SPLIT`
- `JOIN`
- `BAR`
- `WSYNC`
- RTU trace/wait 相关指令

### 8.3 PC 如何前进

未启用压缩指令时，PC 在 fetch 接收 scheduler 输出时加 4：

```systemverilog
if (schedule_if_fire) begin
    warp_pcs_n[schedule_if.data.wid] = schedule_if.data.PC + from_fullPC(`VX_CFG_XLEN'(4));
end
```

启用压缩指令时，由 decode 告诉 scheduler 当前指令是 2 字节还是 4 字节：

```systemverilog
warp_pcs_n[decode_sched_if.wid] =
    warp_pcs_n[decode_sched_if.wid]
    + from_fullPC(decode_sched_if.is_rvc ? `VX_CFG_XLEN'(2) : `VX_CFG_XLEN'(4));
```

分支、trap、MRET 后续会通过 `branch_ctl_if` 覆盖 PC。

### 8.4 Decode 到 Issue

Issue 按 `ISSUE_WIDTH` 分成多个 `VX_issue_slice`。全局 wid 需要映射到 issue slice 和 slice 内编号，辅助函数在 [`VX_gpu_pkg.sv`](../hw/rtl/VX_gpu_pkg.sv)：

- `wid_to_isw(wid)`：得到 issue slice index。
- `wid_to_wis(wid)`：得到 warp 在 slice 内的编号。
- `wis_to_wid(wis, isw)`：从 slice 内编号恢复全局 wid。

每个 issue slice 内部数据流：

```text
decode_if -> VX_ibuffer -> VX_scoreboard -> VX_operands -> VX_dispatcher
```

`VX_issue_slice` 在 scoreboard 接收一条指令时通知 scheduler：

```systemverilog
scoreboard_fire = scoreboard_if.valid && scoreboard_if.ready;
warp_issued     = scoreboard_fire;
warp_issued_wis = scoreboard_if.data.wis;
```

Scheduler 收到 `issue_sched_if` 后增加该 warp 的 pending 计数。

### 8.5 Ibuffer 计数如何回到 Scheduler

Scheduler 对每个 warp 维护一个 ibuffer occupancy 估计：

```systemverilog
incr = schedule_fire && schedule_onehot[i];
decr = schedule_if.ibuf_pop[i];
size_n = size_r + incr - decr;
ibuf_full_n[i] = (size_n == VX_CFG_IBUF_SIZE);
```

`ibuf_pop` 从 issue ibuffer 反向传回：

```systemverilog
decode_if.ibuf_pop[w] = ibuffer_tmp_if.valid && ibuffer_tmp_if.ready;
```

因此 `ibuf_full` 表示该 warp 下游 instruction buffer 是否已经满，用于避免 scheduler 继续给它灌取指请求。

### 8.6 Execute 如何反馈 Scheduler

ALU 分支路径在 `VX_alu_int.sv` 中产生 `branch_ctl_if`：

- trap entry：PC 跳到 `mtvec`
- MRET：PC 从 `mepc` 恢复
- taken branch：PC 更新到 `branch_dest`
- valid branch feedback：清除对应 warp 的 stalled bit

SFU warp-control 路径在 `VX_wctl_unit.sv` 中产生 `warp_ctl_if`：

- `TMC/PRED`：更新 tmask，并清除 stalled。
- `TMC tmask=0`：让 warp retire，清除 active。
- `WSPAWN`：激活其他 warp。
- `SPLIT`：更新 tmask，并通过 split/join 栈记录重汇聚信息。
- `JOIN`：恢复或切换 tmask/PC。
- `BAR`：进入 barrier 单元；真正 release 时由 `bar_unlock_mask` 解锁。
- `WSYNC`：等 pending 指令 drain 后解锁。

### 8.7 Commit 如何反馈 Scheduler

`VX_commit` 从多个执行单元仲裁 commit 结果。每个 issue slot 如果 commit fire 且 `eop=1`，就记录该 slot 对应的 wid，然后构造全局 per-warp mask：

```systemverilog
committed_warp_mask[committed_slot_wid[i]] = 1'b1;
```

Scheduler 用 `committed_warps` 做三件事：

- `instret` 累加
- per-warp pending counter 递减
- `busy` 判断和 `WSYNC` drain 判断

## 9. Scheduler 状态更新顺序

`VX_scheduler` 在一个组合 `always @(*)` 中计算下一拍状态。顺序很重要，因为同一个 wid 上后面的赋值可能覆盖前面的赋值。

更新顺序：

1. 从当前 `active_warps`、`stalled_warps`、`thread_masks`、`warp_pcs` 开始。
2. `cta_fire`：激活新 warp，初始化 PC/tmask。
3. `decode_sched_if.unlock`：普通指令 decode 后解锁 warp。
4. `WSPAWN` 延迟处理：满足 single-warp 条件后激活目标 warps。
5. `TMC/PRED`：更新 active/tmask，并解锁。
6. `SPLIT`：如果发散，更新 tmask 到选中的路径，并解锁。
7. `JOIN`：恢复/切换 tmask，必要时更新 PC，并解锁。
8. Barrier unlock：`stalled_warps_n &= ~bar_unlock_mask`。
9. `WSYNC`：pending drain 后解锁。
10. Branch/trap/MRET：更新 PC，并解锁。
11. `schedule_fire`：刚被选中的 warp 重新置 stalled。
12. PC 顺序前进。
13. RTU async trap 处理，如果启用 RTU。

调度策略改造通常只需要改第 6 节的候选选择/仲裁逻辑，不应该随意改这些状态更新路径。

## 10. 控制类指令的解锁来源

调试某个 warp 长时间 stalled 时，先看它在等谁解锁：

| 指令类别 | Decode 不立即解锁的原因 | 解锁来源 |
| --- | --- | --- |
| 普通 ALU/LSU/FPU | 不需要修改 scheduler 控制状态 | Decode：`unlock=1` |
| Branch/JAL/JALR | PC 可能改变 | ALU：`branch_ctl_if` |
| ECALL/EBREAK/MRET | trap CSR、PC、tmask 可能改变 | ALU/scheduler trap path |
| `TMC/PRED` | tmask 改变 | `warp_ctl_if.tmc_valid` |
| `WSPAWN` | 需要复制/激活其他 warp 状态 | scheduler delayed `wspawn_valid` path |
| `SPLIT` | 发散栈和 tmask 改变 | `warp_ctl_if.split_valid` |
| `JOIN` | 重汇聚可能恢复 tmask/PC | `VX_split_join` 输出 |
| `BAR` | 可能等待其他 warp 或 event | `VX_bar_unit` 的 unlock mask |
| `WSYNC` | 必须等旧指令提交完成 | `warp_pending_alm_empty` 后 `wsync_valid` |

## 11. Barrier 控制流

`VX_wctl_unit` 解码 barrier 操作数，生成：

- `bar_valid`
- `bar.id`
- `bar.is_event`
- `bar.is_global`
- `bar.is_arrive`
- `bar.is_sync`
- `bar.phase`
- `bar.size_m1`

Barrier 进入 `VX_bar_unit` 前，`VX_wctl_unit` 会等待 LSU scheduler drain：

```systemverilog
warp_ctl_if.lsu_sched_drained
```

`VX_core` 将它连接为所有 LSU scheduler empty 位的 AND，因此 barrier 同时承担 memory fence 作用。

`VX_bar_unit` 维护每个 barrier 的：

- 等待 warp mask
- arrival count
- event count
- phase bit

条件满足后，barrier 单元输出：

```systemverilog
bar_unlock_valid
bar_unlock_mask
```

Scheduler 收到后清除对应 stalled 位：

```systemverilog
stalled_warps_n &= ~bar_unlock_mask;
```

## 12. Split/Join 发散控制流

`VX_wctl_unit` 根据每个 lane 的 predicate 计算：

- `then_tmask`
- `else_tmask`

`SPLIT` 时：

- 如果只有一边非空，则不算发散。
- 如果两边都非空，`split.is_dvg=1`。
- 代码会选择线程数较少的一边先执行，减少栈压力。
- `VX_split_join` 将 `{原始 tmask, next_pc}` push 到 IPDOM stack。
- Scheduler 将当前 warp 的 tmask 改成被选中的路径。

`JOIN` 时：

- `VX_split_join` 检查当前 stack pointer。
- 可能切换到 else 路径，并设置 `warp_pcs_n[join_wid] = join_pc`。
- 也可能在重汇聚点恢复原始 tmask。
- Scheduler 清除该 warp 的 stalled bit。

## 13. Pending 计数与 `WSYNC`

Scheduler 用 `VX_pending_size` 维护每个 warp 的 issued-but-not-committed 指令数量。

增加条件：

```systemverilog
issue_sched_if[isw].valid && (issue_sched_if[isw].wis == wid_to_wis(i))
```

减少条件：

```systemverilog
commit_sched_if.committed_warps[i]
```

输出：

- `pending_warp_empty`：用于 `busy` 判断。
- `pending_warp_alm_empty`：送给 `VX_wctl_unit`，用于 `WSYNC`。

`WSYNC` 在 `VX_wctl_unit` 中会 hold execute，直到：

```systemverilog
warp_ctl_if.warp_pending_alm_empty[wid]
```

然后发送 `wsync_valid`，scheduler 清除该 warp 的 stalled bit。

## 14. Round-Robin 应该改哪里

实现 Round-Robin 时，最直接的目标是替换 `VX_scheduler.sv` 中当前对 `schedule_warps` 的 `VX_priority_encoder`。

必须保持的约束：

- 不要改 `ready_warps = active_warps & ~stalled_warps`，除非算法确实需要新的 ready 条件。
- 保留 ibuffer 过滤：`preferred_warps = ready_warps & ~ibuf_full`。
- 保留 L1/no-L1 对 `all_ibuf_full` 的处理。
- 仍然输出 `schedule_wid`、`schedule_valid`、`schedule_onehot`。
- `last_wid_r` 这类 RR 指针只在 `schedule_fire` 时更新。
- 不要在 `schedule_if_fire` 更新 RR 指针，因为它是 fetch 侧握手，可能被 scheduler 输出 buffer 解耦。
- 本地研究时可以先用 RTL/rtlsim 建立行为闭环；如果要提交会改变周期行为的修改，必须同步更新 SimX timing model，保持 RTL 和 SimX lockstep。

Round-Robin 应该在 `schedule_warps` 上仲裁，而不是在 `active_warps` 上仲裁。因为 stalled 或 ibuffer-full 的 warp 不能被选中。

## 15. 推荐观察信号

做调度策略实验时，建议观察：

- `active_warps`
- `stalled_warps`
- `ready_warps`
- `preferred_warps`
- `schedule_warps`
- `schedule_valid`
- `schedule_ready`
- `schedule_fire`
- `schedule_wid`
- `schedule_onehot`
- `schedule_if.valid`
- `schedule_if.ready`
- `schedule_if.data.wid`
- `decode_sched_if.valid`
- `decode_sched_if.unlock`
- `decode_sched_if.wid`
- `branch_valid`
- `branch_wid`
- `branch_taken`
- `branch_dest`
- `warp_ctl_if.tmc_valid`
- `warp_ctl_if.split_valid`
- `warp_ctl_if.sjoin_valid`
- `warp_ctl_if.bar_valid`
- `warp_ctl_if.wsync_valid`
- `bar_unlock_valid`
- `bar_unlock_mask`
- `ibuf_full`
- `pending_warp_alm_empty`

如果加 `SCHED` 打印，最推荐的打印点是 `schedule_fire`，因为这里代表仲裁结果真正进入 scheduler 输出 buffer。

## 16. 实用验证闭环

验证 `VX_scheduler.sv` 这类 RTL 修改，要跑 `rtlsim`。`simx` 是 C++ timing model，不会执行 SystemVerilog 里的 `$display`。

推荐 smoke loop：

```bash
cd /home/houdong/vortex/build
../configure
env -u DEBUG CCACHE_DISABLE=1 make -C sim/rtlsim DEBUG=
env -u DEBUG CCACHE_DISABLE=1 ./ci/blackbox.sh --driver=rtlsim --app=vecadd 2>&1 | tee run.log
grep "SCHED" run.log
grep -i "passed" run.log
grep "PERF:" run.log
```

注意：

- `env -u DEBUG` 避免外部环境里的 `DEBUG=release` 被 Makefile 变成错误的 `-DVX_DBG_DEBUG_LEVEL=release`。
- `CCACHE_DISABLE=1` 可以避开 ccache 临时目录只读或 stale object 问题。
- 按仓库规则，测试前从 `build/` 执行 `../configure`，保证生成的配置头文件和 Makefile 是新的。

## 17. 常见误区

- `stalled_warps` 不是“warp 已经死了”，只是“前端暂时不要再取这个 warp”。
- `active_warps=0` 不代表 core 立刻完全空了；pending 指令可能还会让 `busy` 短暂保持。
- `schedule_fire` 和 `schedule_if_fire` 不是同一个握手。
- 日志出现 `0,1,2,3` 不代表策略是 Round-Robin。
- `issue_sched_if` 和 `commit_sched_if` 不参与选择下一个 warp，它们主要服务 pending 计数和性能状态。
- 顺序 PC 前进不是分支指令的最终 PC；分支 execute 后会通过 `branch_ctl_if` 修正。

## 18. 调试阅读 Checklist

遇到调度行为异常时，按顺序问：

1. 这个 warp 是否 active？
2. 它是否 stalled？
3. 如果 stalled，它应该由 decode、branch、warp_ctl、barrier、wsync 中的哪条路径解锁？
4. 它的 ibuffer 是否被认为 full？
5. 它是否出现在 `schedule_warps` 中？
6. 如果 `schedule_warps` 多位为 1，当前策略选择了哪一位？
7. 选中的 warp 是否到达 `schedule_fire`？
8. fetch 是否在 `schedule_if_fire` 接收了它？
9. decode 是否返回 `unlock=1`，还是该指令是控制类 `is_wstall=1`？
10. execute 是否产生了预期的 `branch_ctl_if` 或 `warp_ctl_if`？
11. commit 是否正确减少 pending 计数？

这个 checklist 可以把调度调试限制在真实数据流上，避免只根据最终输出值猜测。
