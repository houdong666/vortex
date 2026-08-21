
// 版权所有 © 2019-2023
// 根据 Apache License, Version 2.0 授权许可。

`include "VX_define.vh"

// ============================================================================
// VX_cp_fetch — 每个CPE的环形缓冲区读取器。
//
// 每个 VX_cp_engine 有一个该模块实例。通过 AXI4 主控子端口（即 VX_mem_axi_xbar
// 的每个CPE输入端）从主机锁定的环形缓冲区读取 64 字节缓存行，使用内嵌的
// VX_cp_unpack 解码，并将解码后的 cmd_t 记录逐个流式发送到其 CPE 的 cmd_in 端口。
//
// 请求侧通过 fetch_head 跟踪已发出的缓存行，响应侧进入最多 2 项的有序 FIFO，
// 消费侧通过 head 跟踪已完成解包的缓存行。三者相互解耦，因此下一条缓存行的
// AXI 延迟可以与当前行的命令输出重叠。最多允许 PREFETCH_DEPTH 个有序在途请求；
// 不使用乱序响应或额外 AXI ID。
//
// 每次环形总线事务仍为单拍 512 位 AR（一个缓存行）。
// 环形缓冲区大小为 `1 << ring_size_log2` 字节；head/tail 是字节偏移量，
// 通过 ring_size_mask 进行回绕。tail 从主机角度看是单调递增的；
// 该读取器不监视回绕。
// ============================================================================

module VX_cp_fetch
  import VX_cp_pkg::*;
#(
  parameter int  QID    = 0,
  parameter int  ID_W   = VX_CP_AXI_TID_WIDTH_C,
  parameter int  PREFETCH_DEPTH = 1,
  // 交叉开关将源 ID 打包到 arid 的高位中。调用者为每个读取器实例分配
  // 唯一的 TID_PREFIX，以便响应能路由回来。
  parameter logic [ID_W-1:0] TID_PREFIX = '0
)(
  input  wire                       clk,
  input  wire                       reset,

  // 来自寄存器文件的每CPE状态镜像。
  input  cpe_state_t                state_in,
  // 更新后的头指针——寄存器文件/CPE状态镜像跟踪此指针，
  // 供主机回读。
  output logic [63:0]               head_out,

  // 解码后的命令流输出到 CPE。
  output logic                      cmd_out_valid,
  output cmd_t                      cmd_out,
  input  wire                       cmd_out_ready,

  // AXI4 主控子端口（VX_mem_axi_xbar 上的源之一）。
  VX_mem_axi_if.master             axi_m
);

  // ---- 已消费 head 与已请求 fetch_head，均为单调递增的字节偏移量 ----
  logic [63:0] head_r;
  logic [63:0] fetch_head_r;
  assign head_out = head_r;

  // 返回 FIFO 同时容纳当前消费行和已预取行；在途请求也占用对应容量，
  // 保证响应到达时一定存在可写位置。
  localparam int FIFO_PTR_W = (PREFETCH_DEPTH > 1) ? $clog2(PREFETCH_DEPTH) : 1;
  localparam int FIFO_CNT_W = $clog2(PREFETCH_DEPTH + 1);
  // PREFETCH_DEPTH 仅允许 1/2，以下窄化是经过范围约束的常量编码。
  /* verilator lint_off WIDTHTRUNC */
  localparam logic [FIFO_PTR_W-1:0] FIFO_LAST_PTR =
      PREFETCH_DEPTH - 1;
  localparam logic [FIFO_CNT_W-1:0] FIFO_DEPTH_COUNT =
      PREFETCH_DEPTH;
  localparam logic [FIFO_CNT_W:0] FIFO_DEPTH_ALLOC =
      PREFETCH_DEPTH;
  /* verilator lint_on WIDTHTRUNC */
  logic [CL_BITS-1:0] cl_fifo [PREFETCH_DEPTH];
  logic [FIFO_PTR_W-1:0] read_ptr_r, write_ptr_r;
  logic [FIFO_CNT_W-1:0] fifo_count_r;
  logic [FIFO_CNT_W-1:0] request_count_r;

  wire fifo_empty = (fifo_count_r == 0);
  wire fifo_full  = (fifo_count_r == FIFO_DEPTH_COUNT);
  wire [CL_BITS-1:0] cl_data_r = cl_fifo[read_ptr_r];

  // ---- 当前缓存行内的单命令顺序解码 ----
  localparam int       OFF_W = $clog2(CL_BYTES + 1);
  logic [OFF_W-1:0]    offset_r;     // 当前正在发出的命令的字节偏移量
  cmd_t                cmd_w;        // 在 offset_r 处解码出的命令
  logic                has_cmd_w;    // 1 = offset_r 处有有效命令（0 = 行结束）
  logic [OFF_W-1:0]    cmd_size_w;   // cmd_w 占用的字节数

  // 精确解码当前偏移量处的命令。FSM 通过每次发出命令后前进 offset_r += cmd_size_w
  // 来逐条处理行，而不是组合解码整行（原先是 35 级关键路径）。
  VX_cp_unpack u_unpack (
    .cl_data   (cl_data_r),
    .offset    (offset_r),
    .has_cmd   (has_cmd_w),
    .cmd       (cmd_w),
    .cmd_size  (cmd_size_w)
  );

  typedef enum logic [1:0] { S_IDLE, S_ISSUE_AR, S_WAIT_R, S_EMIT } state_e;
  state_e state;

  wire [63:0] fetch_ring_offset =
      fetch_head_r & {48'd0, state_in.ring_size_mask};
  wire [FIFO_CNT_W:0] allocated_lines =
      {1'b0, fifo_count_r} + {1'b0, request_count_r};
  wire can_issue = state_in.enabled
                && (fetch_head_r < state_in.tail)
                && (allocated_lines < FIFO_DEPTH_ALLOC);
  wire push_line = axi_m.rvalid && axi_m.rready;
  wire pop_line  = !fifo_empty && !has_cmd_w;

  // 保留原有四态观测编码，便于性能计数和波形对照；请求和消费控制本身已解耦。
  always_comb begin
    if (!fifo_empty)
      state = S_EMIT;
    else if (request_count_r != 0)
      state = S_WAIT_R;
    else if (can_issue)
      state = S_ISSUE_AR;
    else
      state = S_IDLE;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      head_r            <= '0;
      fetch_head_r      <= '0;
      read_ptr_r        <= '0;
      write_ptr_r       <= '0;
      fifo_count_r      <= '0;
      request_count_r   <= '0;
      offset_r          <= '0;
    end else begin
      if (axi_m.arvalid && axi_m.arready) begin
        fetch_head_r <= fetch_head_r + 64'd64;
      end

      if (push_line) begin
        cl_fifo[write_ptr_r] <= axi_m.rdata;
        write_ptr_r <= (write_ptr_r == FIFO_LAST_PTR)
                     ? '0 : write_ptr_r + 1'b1;
      end

      case ({axi_m.arvalid && axi_m.arready, push_line})
        2'b10: request_count_r <= request_count_r + 1'b1;
        2'b01: request_count_r <= request_count_r - 1'b1;
        default: request_count_r <= request_count_r;
      endcase

      if (pop_line) begin
        read_ptr_r <= (read_ptr_r == FIFO_LAST_PTR)
                    ? '0 : read_ptr_r + 1'b1;
        head_r     <= head_r + 64'd64;
        offset_r   <= '0;
      end else if (!fifo_empty && cmd_out_ready) begin
        offset_r <= offset_r + cmd_size_w;
      end

      case ({push_line, pop_line})
        2'b10: fifo_count_r <= fifo_count_r + 1'b1;
        2'b01: fifo_count_r <= fifo_count_r - 1'b1;
        default: fifo_count_r <= fifo_count_r;
      endcase
    end
  end

  // ---- 输出驱动 ----
  always_comb begin
    // AXI 主控默认值。fetch 只使用 AR/R；AW/W/B 保持默认关闭。
    axi_m.awvalid = 1'b0;
    axi_m.awaddr  = '0;
    axi_m.awid    = '0;
    axi_m.awlen   = '0;
    axi_m.awsize  = '0;
    axi_m.awburst = 2'b01;
    axi_m.wvalid  = 1'b0;
    axi_m.wdata   = '0;
    axi_m.wstrb   = '0;
    axi_m.wlast   = 1'b0;
    axi_m.bready  = 1'b1;
    axi_m.rready  = (request_count_r != 0) && !fifo_full;

    // AR 驱动
    axi_m.arvalid = can_issue;
    axi_m.araddr  = state_in.ring_base + fetch_ring_offset;
    axi_m.arid    = TID_PREFIX;
    axi_m.arlen   = 8'd0;                  // 单拍
    axi_m.arsize  = 3'd6;                  // 每次传输 64 字节
    axi_m.arburst = 2'b01;                 // INCR

    // 命令输出
    cmd_out_valid = !fifo_empty && has_cmd_w;
    cmd_out       = cmd_w;
  end

  `UNUSED_VAR (axi_m.bvalid)
  `UNUSED_VAR (axi_m.bid)
  `UNUSED_VAR (axi_m.bresp)
  `UNUSED_VAR (axi_m.awready)
  `UNUSED_VAR (axi_m.wready)
  `UNUSED_VAR (axi_m.rid)
  `UNUSED_VAR (axi_m.rlast)
  `UNUSED_VAR (axi_m.rresp)
  `UNUSED_VAR (state_in.head_addr)
  `UNUSED_VAR (state_in.cmpl_addr)
  `UNUSED_VAR (state_in.head)
  `UNUSED_VAR (state_in.seqnum)
  `UNUSED_VAR (state_in.prio)
  `UNUSED_VAR (state_in.profile_en)
  `UNUSED_VAR (state)
  `UNUSED_PARAM (QID)

  initial begin
    assert (PREFETCH_DEPTH >= 1 && PREFETCH_DEPTH <= 2)
      else $error("PREFETCH_DEPTH must be 1 or 2");
  end

endmodule : VX_cp_fetch
