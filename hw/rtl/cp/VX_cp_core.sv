// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_define.vh"

// ============================================================================
// VX_cp_core — 命令处理器（CP）顶层包装模块。
//
// 本模块将 rtl/cp/ 目录下的所有子模块集成在一起，供 AFU 胶合逻辑（shim）
// 与 Vortex 核心一同实例化。其整体架构如下：
//
//                         ┌──────────────────────────┐
//   AXI4-Lite 主机控制面 ──►│  VX_cp_axil_regfile      │── 每个队列的
//   （控制平面）           │                          │   cpe_state 配置
//                         └──┬───────────────────────┘
//                            │ q_state[NUM_QUEUES]
//                  ┌─────────┴────────┬──────────────┬──────────┐
//                  │ fetch[NUM_QUEUES] │ engine[N]    │ cmpl     │
//                  │ + 内嵌解包        │  + 4路仲裁   │  退役槽  │
//                  │  → cmd_in 流      │   请求线     │          │
//                  └─────────┬─────────┴───┬──────────┴────┬─────┘
//                            │              │               │
//                            ▼              ▼               ▼
//      ┌──────────────────────────────┐   ┌────────────────────────┐
//      │  主机交叉开关：取指[N] + 完成 │   │  设备交叉开关：DMA(设备)│
//      │            + DMA(主机)       │   │          + 事件单元    │
//      └───────────────┬──────────────┘   └───────────┬────────────┘
//                      ▼ axi_host (AXI4)              ▼ axi_dev (AXI4)
//
//   双数据平面：XRT 将每个内核 AXI 主设备固定映射到一个内存资源，
//   因此 CP 携带两个 AXI 主接口 —— axi_host 用于访问主机内存（命令环驻留在此，也是所有上传/下载的一端），
//   axi_dev 用于访问设备内存。DMA 引擎横跨两者：其操作码选择读源端口和写目的端口。
//   共享的 KMU 启动 / DCR 代理通过 gpu_if（Vortex 侧接口）连接。
//
// AXI 主设备的事务 ID（TID）布局（每个交叉开关）：
//   高 [ID_W-1 : ID_W-SRC_W] 位 = 源索引（交叉开关据此进行响应路由）
//   低 [ID_W-SRC_W-1 : 0]    位 = 子标签，由源模块自定义
// ============================================================================

// 宏：将 VX_mem_axi_if 类型的 `src`（主设备）连接到交叉开关 `xbar` 的
//     某个 `slot` 输入（交叉开关将该输入视为 AXI 从设备）。
//     该宏完成所有 AXI 信号的直接连线。
`define CP_AXI_LINK(slot, src)            \
  assign slot.awvalid = src.awvalid;      \
  assign slot.awaddr  = src.awaddr;       \
  assign slot.awid    = src.awid;         \
  assign slot.awlen   = src.awlen;        \
  assign slot.awsize  = src.awsize;       \
  assign slot.awburst = src.awburst;      \
  assign src.awready  = slot.awready;     \
  assign slot.wvalid  = src.wvalid;       \
  assign slot.wdata   = src.wdata;        \
  assign slot.wstrb   = src.wstrb;        \
  assign slot.wlast   = src.wlast;        \
  assign src.wready   = slot.wready;      \
  assign src.bvalid   = slot.bvalid;      \
  assign src.bid      = slot.bid;         \
  assign src.bresp    = slot.bresp;       \
  assign slot.bready  = src.bready;       \
  assign slot.arvalid = src.arvalid;      \
  assign slot.araddr  = src.araddr;       \
  assign slot.arid    = src.arid;         \
  assign slot.arlen   = src.arlen;        \
  assign slot.arsize  = src.arsize;       \
  assign slot.arburst = src.arburst;      \
  assign src.arready  = slot.arready;     \
  assign src.rvalid   = slot.rvalid;      \
  assign src.rdata    = slot.rdata;       \
  assign src.rid      = slot.rid;         \
  assign src.rlast    = slot.rlast;       \
  assign src.rresp    = slot.rresp;       \
  assign slot.rready  = src.rready

module VX_cp_core
  import VX_cp_pkg::*;   // 导入 CP 相关的参数和类型定义
#(
  parameter int NUM_QUEUES = VX_CP_NUM_QUEUES_C,   // 命令队列数量
  parameter int ADDR_W     = 64,                   // AXI 地址位宽
  parameter int DATA_W     = 512,                 // AXI 数据位宽（用于数据搬运）
  parameter int ID_W       = VX_CP_AXI_TID_WIDTH_C, // AXI 事务 ID 位宽
  parameter int AXIL_AW    = 16,                  // AXI-Lite 控制接口的地址位宽
  // 将实验 4/6 的局部开关提升到 CP 顶层，便于整机回归和同顶层 PPA 对照。
  parameter bit ENABLE_NOP_FAST_PATH = 0,
  parameter int PREFETCH_DEPTH = 1,
  parameter bit ENABLE_PRIORITY_ARBITRATION = 0,
  parameter bit ENABLE_ARBITRATION_AGING = 0,
  parameter bit ENABLE_EVENT_WAIT_FAIRNESS = 0
)(
  input  wire                       clk,          // 时钟
  input  wire                       reset,        // 复位

  // 主机控制平面（AXI4-Lite 从设备）—— 用于配置 CP 内部寄存器
  VX_cp_axil_s_if.slave             axil_s,

  // 主机内存数据平面（AXI4 主设备）—— 用于访问主机内存：
  // 包括命令环读取、完成写回、以及 DMA 上传/下载的主机端
  VX_mem_axi_if.master             axi_host,

  // 设备内存数据平面（AXI4 主设备）—— 用于访问设备内存：
  // 包括 DMA 上传/下载的设备端、以及事件计数器的读写
  VX_mem_axi_if.master             axi_dev,

  // 面向 GPU 的握手接口（Vortex 侧的 DCR 以及启动/忙信号）
  VX_cp_gpu_if.master               gpu_if,

  // 单周期脉冲，在任意队列退役一条命令后产生（驱动平台中断引脚）。
  // 命名为 `irq` 而非 `interrupt`，因为后者是 SystemVerilog 保留关键字。
  output wire                       irq
);

  // ----- 内部常数定义 -----

  // 主机交叉开关（host xbar）的输入源数量：
  // NUM_QUEUES 个取指单元 + 1 个完成写回单元 + 1 个 DMA（主机端）
  localparam int N_SRC_HOST = NUM_QUEUES + 2;

  // 设备交叉开关（dev xbar）的输入源数量：
  // 1 个 DMA（设备端）+ 1 个事件单元
  localparam int N_SRC_DEV  = 2;

  // 定义每个源在交叉开关输入槽位中的具体索引
  localparam int SLOT_CMPL     = NUM_QUEUES;       // 完成写回单元（主机 xbar）
  localparam int SLOT_DMA_HOST = NUM_QUEUES + 1;   // DMA 主机端（主机 xbar）
  localparam int SLOT_DMA_DEV  = 0;                // DMA 设备端（设备 xbar）
  localparam int SLOT_EVENT    = 1;                // 事件单元（设备 xbar）

  // ----- 寄存器文件（AXI-Lite 控制接口）管理的每队列状态 -----
  cpe_state_t q_state          [NUM_QUEUES]; // 每个队列的可编程状态（由主机配置）
  logic       q_reset_pulse    [NUM_QUEUES]; // 队列复位脉冲（当前未使用）

  // 从 CPE 反馈给寄存器文件的遥测信息
  logic [63:0] q_head_to_reg   [NUM_QUEUES]; // 每个队列当前 head 指针
  logic [63:0] q_seqnum_to_reg [NUM_QUEUES]; // 每个队列当前命令序号
  logic [31:0] q_error_to_reg  [NUM_QUEUES]; // 每个队列错误状态（预留）

  // 聚合的 CP 状态，供主机通过 CP_STATUS 寄存器读取
  logic cp_busy;   // CP 是否忙碌
  logic cp_error;  // CP 是否发生错误

  wire [`VX_DCR_DATA_BITS-1:0] dcr_last_rsp_data; // 最近一次 DCR 读返回的数据

  // 实例化寄存器文件模块
  VX_cp_axil_regfile #(
    .NUM_QUEUES (NUM_QUEUES),
    .ADDR_W     (AXIL_AW)
  ) u_regfile (
    .clk            (clk),
    .reset          (reset),
    .axil_s         (axil_s),                  // AXI-Lite 从设备接口
    .cp_busy        (cp_busy),                 // 输入：CP 忙状态
    .cp_error       (cp_error),                // 输入：CP 错误状态
    .q_head         (q_head_to_reg),           // 输入：各队列 head
    .q_seqnum       (q_seqnum_to_reg),         // 输入：各队列 seqnum
    .q_error        (q_error_to_reg),          // 输入：各队列错误
    .last_dcr_rsp   (dcr_last_rsp_data),       // 输入：最近 DCR 读数据
    .q_state        (q_state),                 // 输出：各队列状态配置
    .q_reset_pulse  (q_reset_pulse)            // 输出：各队列复位脉冲
  );

  // ----- 每个队列（CPE）的内部连线 -----
  logic [63:0] seqnum_out [NUM_QUEUES]; // 每个队列当前 seqnum 输出

  // 四条资源仲裁请求线（每个 CPE 有四个 bid 接口）
  VX_cp_engine_bid_if bid_kmu   [NUM_QUEUES] (); // 指向 KMU 启动资源
  VX_cp_engine_bid_if bid_dma   [NUM_QUEUES] (); // 指向 DMA 搬运资源
  VX_cp_engine_bid_if bid_dcr   [NUM_QUEUES] (); // 指向 DCR 读写资源
  VX_cp_engine_bid_if bid_event [NUM_QUEUES] (); // 指向事件单元

  // 从每个 CPE 发出的退役/性能分析信号
  logic        retire_evt    [NUM_QUEUES]; // 退役事件（单周期脉冲）
  logic [63:0] retire_seqnum [NUM_QUEUES]; // 退役的命令序号
  logic        retire_ready  [NUM_QUEUES]; // 完成写回单元反压（ready）
  logic        submit_evt    [NUM_QUEUES]; // 命令提交事件（用于 profile）
  logic        start_evt     [NUM_QUEUES]; // 命令开始执行事件
  logic        end_evt       [NUM_QUEUES]; // 命令执行结束事件
  logic [63:0] profile_slot  [NUM_QUEUES]; // 性能分析槽数据（当前未使用）

  // 取指单元输出给引擎的解码后命令流
  logic       cpe_cmd_valid [NUM_QUEUES]; // 命令有效
  cmd_t       cpe_cmd       [NUM_QUEUES]; // 命令内容（结构体）
  logic       cpe_cmd_ready [NUM_QUEUES]; // 引擎准备好接收

  // 共享资源完成的脉冲（广播给所有 CPE）
  logic launch_done, dma_done, dcr_done, event_done, event_retry;
  wire event_ready;

  // 每个队列内部的 AXI 子主设备（仅取指单元使用 AXI）
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W))
                       fetch_axi [NUM_QUEUES] ();

  // ----- 实例化 NUM_QUEUES 个 CPE（取指 + 引擎）-----
  generate
    for (genvar q = 0; q < NUM_QUEUES; ++q) begin : g_cpe
      // 取指单元：负责从主机内存的命令环读取命令并解包
      VX_cp_fetch #(
        .QID            (q),
        .PREFETCH_DEPTH (PREFETCH_DEPTH)
      ) u_fetch (
        .clk           (clk),
        .reset         (reset),
        .state_in      (q_state[q]),            // 本队列的配置状态
        .head_out      (q_head_to_reg[q]),      // 更新后的 head 指针
        .cmd_out_valid (cpe_cmd_valid[q]),      // 输出有效命令
        .cmd_out       (cpe_cmd[q]),            // 输出命令体
        .cmd_out_ready (cpe_cmd_ready[q]),      // 下游 ready
        .axi_m         (fetch_axi[q])           // AXI 主设备（读命令环）
      );

      // 命令执行引擎：解码并执行来自取指单元的命令
      VX_cp_engine #(
        .QID                  (q),
        .ENABLE_NOP_FAST_PATH (ENABLE_NOP_FAST_PATH)
      ) u_engine (
        .clk           (clk),
        .reset         (reset),
        .prio_in       (q_state[q].prio),       // 队列优先级
        .seqnum_out    (seqnum_out[q]),         // 当前命令序号输出
        .cmd_in_valid  (cpe_cmd_valid[q]),      // 输入命令有效
        .cmd_in        (cpe_cmd[q]),            // 输入命令
        .cmd_in_ready  (cpe_cmd_ready[q]),      // 反压信号
        .bid_kmu       (bid_kmu[q]),            // KMU 请求线
        .bid_dma       (bid_dma[q]),            // DMA 请求线
        .bid_dcr       (bid_dcr[q]),            // DCR 请求线
        .bid_event     (bid_event[q]),          // 事件请求线
        // 下面四个 done 信号由共享资源模块广播；只有获得授权的 CPE
        // 在进入 S_WAIT_DONE 状态时才会响应对应脉冲
        .kmu_done_i    (launch_done),
        .dma_done_i    (dma_done),
        .dcr_done_i    (dcr_done),
        .event_done_i  (event_done),
        .event_retry_i (event_retry),
        .retire_evt    (retire_evt[q]),         // 输出退役事件
        .retire_seqnum (retire_seqnum[q]),      // 输出退役序号
        .retire_ready_i(retire_ready[q]),       // 完成写回单元反压
        .submit_evt    (submit_evt[q]),         // 提交事件（profile）
        .start_evt     (start_evt[q]),          // 开始事件
        .end_evt       (end_evt[q]),            // 结束事件
        .profile_slot  (profile_slot[q])        // 性能数据
      );

      // 遥测数据直接连到寄存器文件
      assign q_seqnum_to_reg[q] = seqnum_out[q];
      assign q_error_to_reg [q] = 32'd0;   // 每队列错误报告预留
    end
  endgenerate

  // ----- 四个资源仲裁器（轮询调度）-----
  // 每个仲裁器接收所有 CPE 的 bid 请求，选出当前授权者

  // KMU 仲裁器输入信号
  wire        kmu_valid   [NUM_QUEUES]; // 各 CPE 是否请求 KMU
  wire [1:0]  kmu_prio    [NUM_QUEUES]; // 各请求的优先级
  cmd_t       kmu_cmd     [NUM_QUEUES]; // 各请求携带的命令
  logic       kmu_grant   [NUM_QUEUES]; // 仲裁器输出授权标志

  // DMA 仲裁器输入信号
  wire        dma_valid   [NUM_QUEUES];
  wire [1:0]  dma_prio    [NUM_QUEUES];
  cmd_t       dma_cmd     [NUM_QUEUES];
  logic       dma_grant   [NUM_QUEUES];

  // DCR 仲裁器输入信号
  wire        dcr_valid   [NUM_QUEUES];
  wire [1:0]  dcr_prio    [NUM_QUEUES];
  cmd_t       dcr_cmd     [NUM_QUEUES];
  logic       dcr_grant   [NUM_QUEUES];

  // 事件仲裁器输入信号
  wire        event_valid [NUM_QUEUES];
  wire [1:0]  event_prio  [NUM_QUEUES];
  cmd_t       event_cmd   [NUM_QUEUES];
  logic       event_grant [NUM_QUEUES];

  // 将 bid 接口信号连接到相应的仲裁器输入数组
  generate
    for (genvar q = 0; q < NUM_QUEUES; ++q) begin : g_unpack_bids
      assign kmu_valid[q]     = bid_kmu[q].valid;
      assign kmu_prio[q]      = bid_kmu[q].priority_;
      assign kmu_cmd[q]       = bid_kmu[q].cmd;
      assign bid_kmu[q].grant = kmu_grant[q];

      assign dma_valid[q]     = bid_dma[q].valid;
      assign dma_prio[q]      = bid_dma[q].priority_;
      assign dma_cmd[q]       = bid_dma[q].cmd;
      assign bid_dma[q].grant = dma_grant[q];

      assign dcr_valid[q]     = bid_dcr[q].valid;
      assign dcr_prio[q]      = bid_dcr[q].priority_;
      assign dcr_cmd[q]       = bid_dcr[q].cmd;
      assign bid_dcr[q].grant = dcr_grant[q];

      // EVENT 单元忙碌时禁止新授权，确保完成或重试只属于当前命令。
      assign event_valid[q]     = bid_event[q].valid && event_ready;
      assign event_prio[q]      = bid_event[q].priority_;
      assign event_cmd[q]       = bid_event[q].cmd;
      assign bid_event[q].grant = event_grant[q];
    end
  endgenerate

  // 实例化四个仲裁器
  VX_cp_arbiter #(.N(NUM_QUEUES), .ENABLE_PRIORITY(ENABLE_PRIORITY_ARBITRATION), .ENABLE_AGING(ENABLE_ARBITRATION_AGING)) u_arb_kmu (
    .clk(clk), .reset(reset),
    .bid_valid(kmu_valid), .bid_priority(kmu_prio), .bid_grant(kmu_grant),
    `UNUSED_PIN(rr_pointer_o), `UNUSED_PIN(selected_queue_o),
    `UNUSED_PIN(wait_counter_o), `UNUSED_PIN(aging_boost_o), `UNUSED_PIN(effective_priority_o)
  );
  VX_cp_arbiter #(.N(NUM_QUEUES), .ENABLE_PRIORITY(ENABLE_PRIORITY_ARBITRATION), .ENABLE_AGING(ENABLE_ARBITRATION_AGING)) u_arb_dma (
    .clk(clk), .reset(reset),
    .bid_valid(dma_valid), .bid_priority(dma_prio), .bid_grant(dma_grant),
    `UNUSED_PIN(rr_pointer_o), `UNUSED_PIN(selected_queue_o),
    `UNUSED_PIN(wait_counter_o), `UNUSED_PIN(aging_boost_o), `UNUSED_PIN(effective_priority_o)
  );
  VX_cp_arbiter #(.N(NUM_QUEUES), .ENABLE_PRIORITY(ENABLE_PRIORITY_ARBITRATION), .ENABLE_AGING(ENABLE_ARBITRATION_AGING)) u_arb_dcr (
    .clk(clk), .reset(reset),
    .bid_valid(dcr_valid), .bid_priority(dcr_prio), .bid_grant(dcr_grant),
    `UNUSED_PIN(rr_pointer_o), `UNUSED_PIN(selected_queue_o),
    `UNUSED_PIN(wait_counter_o), `UNUSED_PIN(aging_boost_o), `UNUSED_PIN(effective_priority_o)
  );
  VX_cp_arbiter #(.N(NUM_QUEUES), .ENABLE_PRIORITY(ENABLE_PRIORITY_ARBITRATION), .ENABLE_AGING(ENABLE_ARBITRATION_AGING)) u_arb_event (
    .clk(clk), .reset(reset),
    .bid_valid(event_valid), .bid_priority(event_prio), .bid_grant(event_grant),
    `UNUSED_PIN(rr_pointer_o), `UNUSED_PIN(selected_queue_o),
    `UNUSED_PIN(wait_counter_o), `UNUSED_PIN(aging_boost_o), `UNUSED_PIN(effective_priority_o)
  );

  // ----- 从授权者中选出对应的命令体，供各共享资源模块使用 -----
  //确保每个共享资源（KMU、DMA、DCR、事件）在同一时刻只接收来自唯一被授权队列的命令，从而避免多源冲突。
  logic any_kmu_grant, any_dma_grant, any_dcr_grant, any_event_grant;
  cmd_t granted_kmu_cmd, granted_dma_cmd, granted_dcr_cmd, granted_event_cmd;

  always_comb begin
    any_kmu_grant = 1'b0; granted_kmu_cmd = '0;
    any_dma_grant = 1'b0; granted_dma_cmd = '0;
    any_dcr_grant = 1'b0; granted_dcr_cmd = '0;
    any_event_grant = 1'b0; granted_event_cmd = '0;
    for (int i = 0; i < NUM_QUEUES; ++i) begin
      if (kmu_grant[i])   begin any_kmu_grant   = 1'b1; granted_kmu_cmd   = kmu_cmd[i];   end
      if (dma_grant[i])   begin any_dma_grant   = 1'b1; granted_dma_cmd   = dma_cmd[i];   end
      if (dcr_grant[i])   begin any_dcr_grant   = 1'b1; granted_dcr_cmd   = dcr_cmd[i];   end
      if (event_grant[i]) begin any_event_grant = 1'b1; granted_event_cmd = event_cmd[i]; end
    end
  end

  `UNUSED_VAR (granted_kmu_cmd) // 当前 KMU 命令未直接使用（启动仅需脉冲）

  // 内部 GPU 接口（寄存器切片前），用于连接各子模块与顶层 gpu_if
  VX_cp_gpu_if gpu_if_int();

  // ----- 共享的 KMU 启动单元（响应 KMU 仲裁授权）-----
  VX_cp_launch u_launch (
    .clk      (clk),
    .reset    (reset),
    .grant    (any_kmu_grant),          // 来自仲裁器的有效授权
    .start    (gpu_if_int.start),       // 向 GPU 发送启动脉冲
    .gpu_busy (gpu_if_int.busy),        // 接收 GPU 忙信号
    .done     (launch_done)             // 输出完成脉冲（广播）
  );

  // ----- 共享的 DCR 代理单元（响应 DCR 仲裁授权）-----
  VX_cp_dcr_proxy u_dcr (
    .clk           (clk),
    .reset         (reset),
    .grant         (any_dcr_grant),              // 有效授权
    .cmd           (granted_dcr_cmd),            // 要执行的 DCR 命令
    .done          (dcr_done),                   // 完成脉冲
    .last_rsp_data (dcr_last_rsp_data),          // 最近读返回数据（送寄存文件）
    .dcr_req_valid (gpu_if_int.dcr_req_valid),   // 向 GPU 发出的 DCR 请求有效
    .dcr_req_rw    (gpu_if_int.dcr_req_rw),      // 读/写标志
    .dcr_req_addr  (gpu_if_int.dcr_req_addr),    // DCR 地址
    .dcr_req_data  (gpu_if_int.dcr_req_data),    // 写数据
    .dcr_rsp_valid (gpu_if_int.dcr_rsp_valid),   // GPU 返回的响应有效
    .dcr_rsp_data  (gpu_if_int.dcr_rsp_data)     // GPU 返回的数据
  );
  `UNUSED_VAR (gpu_if_int.dcr_req_ready) // DCR 请求反压（当前未连接）

  // ----- DMA 单元（横跨主机和设备两个交叉开关）-----
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) dma_host_axi ();
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) dma_dev_axi  ();
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) cmpl_axi     ();
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) event_axi    ();

  VX_cp_dma u_dma (
    .clk      (clk),
    .reset    (reset),
    .grant    (any_dma_grant),        // DMA 仲裁授权
    .cmd      (granted_dma_cmd),      // 要执行的 MEM_* 命令
    .done     (dma_done),             // 完成脉冲
    .axi_host (dma_host_axi),         // 连接到主机交叉开关的 AXI 主设备
    .axi_dev  (dma_dev_axi)           // 连接到设备交叉开关的 AXI 主设备
  );

  // ----- 事件单元（处理 EVENT_SIGNAL / EVENT_WAIT）-----
  VX_cp_event_unit #(
    .ENABLE_WAIT_RELEASE(ENABLE_EVENT_WAIT_FAIRNESS)
  ) u_event (
    .clk   (clk),
    .reset (reset),
    .grant (any_event_grant),         // 事件仲裁授权
    .cmd   (granted_event_cmd),       // 事件命令
    .done  (event_done),              // 完成脉冲
    .retry (event_retry),             // WAIT 未满足时通知原队列重新竞标
    .ready (event_ready),             // 仅空闲状态接收新命令
    .axi_m (event_axi)                // 连接到设备交叉开关的 AXI 主设备
  );

  // ----- 完成写回单元（向主机内存写回退役序号）-----
  wire [63:0] cmpl_addr_arr [NUM_QUEUES];
  generate
    for (genvar q = 0; q < NUM_QUEUES; ++q) begin : g_cmpl_addr
      assign cmpl_addr_arr[q] = q_state[q].cmpl_addr; // 从每个队列状态获取完成地址
    end
  endgenerate

  VX_cp_completion #(
    .NUM_QUEUES (NUM_QUEUES)
  ) u_completion (
    .clk           (clk),
    .reset         (reset),
    .retire_evt    (retire_evt),      // 各队列退役事件
    .retire_seqnum (retire_seqnum),   // 各队列退役序号
    .cmpl_addr     (cmpl_addr_arr),   // 各队列的完成写回地址
    .retire_ready  (retire_ready),    // 向 CPE 反馈反压
    .axi_m         (cmpl_axi)         // 连接到主机交叉开关的 AXI 主设备
  );

  // ============================================================================
  // 主机交叉开关 — 汇聚取指[N] + 完成单元 + DMA(主机端) → axi_host
  // ============================================================================
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W))xbar_host_src [N_SRC_HOST] ();

  // 将取指单元的 AXI 主设备连接到主机交叉开关的对应槽位
  generate
    for (genvar q = 0; q < NUM_QUEUES; ++q) begin : g_host_fetch
      `CP_AXI_LINK(xbar_host_src[q], fetch_axi[q]);
    end
  endgenerate

  // 连接完成单元和 DMA(主机端) 到指定槽位
  `CP_AXI_LINK(xbar_host_src[SLOT_CMPL],     cmpl_axi);
  `CP_AXI_LINK(xbar_host_src[SLOT_DMA_HOST], dma_host_axi);

  // 寄存器切片：打断从 CP 主设备到远端主机内存的长路径，
  // 保证时钟收敛
  VX_mem_axi_if #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) axi_host_pre [1] ();

  // 支持多未完成事务（通过 ID 路由）的交叉开关：
  // 输入源在 ID 的高位预留空间，交叉开关自动打上源索引标签，
  // 并将响应按 ID 分发回对应的源，使各源可并发发起多个事务。
  VX_mem_axi_xbar #(
    .NUM_INPUTS  (N_SRC_HOST),
    .NUM_OUTPUTS (1),
    .ADDR_WIDTH  (ADDR_W),
    .DATA_WIDTH  (DATA_W),
    .ID_WIDTH    (ID_W),
    .MULTI_OUT   (1)
  ) u_xbar_host (
    .clk   (clk),
    .reset (reset),
    .s     (xbar_host_src),   // 所有输入源
    .m     (axi_host_pre)     // 唯一输出
  );

  // 输出端寄存器切片
  VX_mem_axi_slice #(
    .ADDR_WIDTH (ADDR_W),
    .DATA_WIDTH (DATA_W),
    .ID_WIDTH   (ID_W)
  ) u_slice_host (
    .clk   (clk),
    .reset (reset),
    .s     (axi_host_pre[0]),
    .m     (axi_host)         // 顶层 axi_host 端口
  );

  // ============================================================================
  // 设备交叉开关 — 汇聚 DMA(设备端) + 事件单元 → axi_dev
  // ============================================================================
  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W))
                       xbar_dev_src [N_SRC_DEV] ();

  `CP_AXI_LINK(xbar_dev_src[SLOT_DMA_DEV], dma_dev_axi);
  `CP_AXI_LINK(xbar_dev_src[SLOT_EVENT],   event_axi);

  // 设备端寄存器切片
  VX_mem_axi_if #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) axi_dev_pre [1] ();

  VX_mem_axi_xbar #(
    .NUM_INPUTS  (N_SRC_DEV),
    .NUM_OUTPUTS (1),
    .ADDR_WIDTH  (ADDR_W),
    .DATA_WIDTH  (DATA_W),
    .ID_WIDTH    (ID_W),
    .MULTI_OUT   (1)
  ) u_xbar_dev (
    .clk   (clk),
    .reset (reset),
    .s     (xbar_dev_src),
    .m     (axi_dev_pre)
  );

  VX_mem_axi_slice #(
    .ADDR_WIDTH (ADDR_W),
    .DATA_WIDTH (DATA_W),
    .ID_WIDTH   (ID_W)
  ) u_slice_dev (
    .clk   (clk),
    .reset (reset),
    .s     (axi_dev_pre[0]),
    .m     (axi_dev)           // 顶层 axi_dev 端口
  );

  // ----- 聚合状态（cp_busy / cp_error）-----
  // 当任一 CPE 有命令正在处理，或任一共享资源正在活动时，判定为忙碌。
  always_comb begin
    cp_busy = 1'b0;
    cp_error = 1'b0;
    for (int i = 0; i < NUM_QUEUES; ++i) begin
      if (cpe_cmd_valid[i]) cp_busy = 1'b1;
    end
    if (any_kmu_grant || any_dma_grant || any_dcr_grant ||
        any_event_grant) cp_busy = 1'b1;
  end

  // 寄存器文件输出的队列复位脉冲（Q_CONTROL.reset / CP_CTRL.reset_all）
  // 当前未使用：如需停用队列，主机应清除 Q_CONTROL.enable，取指单元将
  // 在空闲状态暂停，正在执行的命令会自然排空。
  generate
    for (genvar q = 0; q < NUM_QUEUES; ++q) begin : g_unused_reset
      `UNUSED_VAR (q_reset_pulse[q])
    end
  endgenerate

  // ----- 中断请求（IRQ）：任意队列退役命令时产生单周期脉冲 -----
  // 当前尚无主机可见的应答/ISR 寄存器（运行时通过轮询 Q_SEQNUM 完成），
  // 此信号用于驱动平台中断引脚，为后续中断驱动的启动-等待机制预留。
  reg irq_r;
  always_ff @(posedge clk) begin
    if (reset) begin
      irq_r <= 1'b0;
    end else begin
      irq_r <= 1'b0;
      for (int q = 0; q < NUM_QUEUES; ++q) begin
        if (retire_evt[q])
          irq_r <= 1'b1;
      end
    end
  end
  assign irq = irq_r;

  // 性能分析脉冲当前未向外路由，此处抑制未使用信号警告
  generate
    for (genvar q = 0; q < NUM_QUEUES; ++q) begin : g_unused_prof
      `UNUSED_VAR (submit_evt[q])
      `UNUSED_VAR (start_evt[q])
      `UNUSED_VAR (end_evt[q])
      `UNUSED_VAR (profile_slot[q])
    end
  endgenerate

  `UNUSED_PARAM (ADDR_W)
  `UNUSED_PARAM (DATA_W)

  // ----- CP 与 Vortex 核心之间的寄存器切片（跨 SLR 安全）-----
  VX_cp_gpu_slice u_gpu_slice (
    .clk      (clk),
    .reset    (reset),
    .cp_side  (gpu_if_int),   // CP 内部接口
    .gpu_side (gpu_if)        // 顶层 GPU 接口
  );

endmodule : VX_cp_core

`undef CP_AXI_LINK
