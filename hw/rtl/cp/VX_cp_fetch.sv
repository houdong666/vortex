
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
// 有限状态机：
//   S_IDLE       : head < tail → S_ISSUE_AR
//                  head == tail → 等待（主机尚未发布更多数据）
//   S_ISSUE_AR   : 驱动 AR，地址 = ring_base + (head & mask)，
//                  arlen=0（单次 64 字节传输），arsize=6，arburst=INCR
//                  → 收到 arready 后进入 S_WAIT_R
//   S_WAIT_R     : 等待 rvalid；将 rdata 锁存到 cl_data_r
//                  → 当 rvalid && rlast 时进入 S_EMIT
//   S_EMIT       : 呈现 cmds[slot]；当 cmd_out_ready 时推进 slot。
//                  当 slot == cmd_count - 1 时：head += 64，→ S_IDLE
//                  纯填充行（cmd_count == 0）直接跳转到 head 前进 + IDLE。
//
// 每次环形总线事务发出一次单拍 512 位 AR（一个缓存行）。
// 环形缓冲区大小为 `1 << ring_size_log2` 字节；head/tail 是字节偏移量，
// 通过 ring_size_mask 进行回绕。tail 从主机角度看是单调递增的；
// 该读取器不监视回绕。
// ============================================================================

module VX_cp_fetch
  import VX_cp_pkg::*;
#(
  parameter int  QID    = 0,
  parameter int  ID_W   = VX_CP_AXI_TID_WIDTH_C,
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

  // ---- 内部头寄存器（字节偏移量，单调递增） ----
  logic [63:0] head_r;
  assign head_out = head_r;

  // ---- 锁存的缓存行 + 单命令顺序解码 ----
  logic [CL_BITS-1:0]  cl_data_r;
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

  // 考虑回绕的环形偏移量。
  wire [63:0] ring_offset = head_r & {48'd0, state_in.ring_size_mask};

  always_ff @(posedge clk) begin
    if (reset) begin
      state     <= S_IDLE;
      head_r    <= '0;
      cl_data_r <= '0;
      offset_r  <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (state_in.enabled && (head_r < state_in.tail)) begin
            state <= S_ISSUE_AR;
          end
        end
        S_ISSUE_AR: begin
          if (axi_m.arvalid && axi_m.arready) begin
            state <= S_WAIT_R;
          end
        end
        S_WAIT_R: begin
          if (axi_m.rvalid && axi_m.rready) begin
            cl_data_r <= axi_m.rdata;
            offset_r  <= '0;
            state     <= S_EMIT;
          end
        end
        S_EMIT: begin
          // 每个周期解码并发出一个命令。has_cmd_w==0 表示该行已耗尽
          //（零头填充、没有足够的空间容纳命令头，或者已越过最后一个命令）
          // → 前进 head，进入下一行。
          if (!has_cmd_w) begin
            head_r <= head_r + 64'd64;
            state  <= S_IDLE;
          end else if (cmd_out_ready) begin
            offset_r <= offset_r + cmd_size_w;
          end
        end
        default: state <= S_IDLE;
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
    axi_m.rready  = (state == S_WAIT_R);

    // AR 驱动
    axi_m.arvalid = (state == S_ISSUE_AR);
    axi_m.araddr  = state_in.ring_base + ring_offset;
    axi_m.arid    = TID_PREFIX;
    axi_m.arlen   = 8'd0;                  // 单拍
    axi_m.arsize  = 3'd6;                  // 每次传输 64 字节
    axi_m.arburst = 2'b01;                 // INCR

    // 命令输出
    cmd_out_valid = (state == S_EMIT) && has_cmd_w;
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
  `UNUSED_PARAM (QID)

endmodule : VX_cp_fetch
