
// 版权所有 © 2019-2023
// 根据 Apache 许可证 2.0 版授权。

`include "VX_define.vh"

// ============================================================================
// VX_cp_event_unit —— 处理 CMD_EVENT_SIGNAL 和 CMD_EVENT_WAIT 命令。
//
// 由 EVENT 资源仲裁器持有。每个 CP_core 一个实例。
//
// 命令编码（cmd_t 字段）：
//   arg0 = 主机内存中事件计数器槽位的 64 位字节地址
//   arg1 = 64 位值（SIGNAL：写入此值；WAIT：目标值）
//   arg2 = 位 [1:0] = wait_op_e（WAIT_OP_EQ / GE / GT / NE）
//          其余位保留
//
// 状态机：
//   S_IDLE     ：grant 上升 → 锁存 cmd + 操作码，→ S_REQ_AW（SIGNAL）
//                                              或 S_REQ_AR（WAIT）
//
//   ---- SIGNAL 路径 ----
//   S_REQ_AW   ：在 arg0 驱动 AW，awsize=3（8 字节节拍）；awready → S_REQ_W
//   S_REQ_W    ：用 arg1 的低 8 字节驱动 W（wstrb 选择字节 0..7）；
//                wready → S_WAIT_B
//   S_WAIT_B   ：bvalid → S_DONE
//
//   ---- WAIT 路径 ----
//   S_REQ_AR   ：在 arg0 驱动 AR，arsize=3；arready → S_WAIT_R
//   S_WAIT_R   ：rvalid → 捕获 rdata 低 8 字节；根据 wait_op 与 arg1 比较：
//                EQ  匹配条件：读值 == arg1
//                GE  匹配条件：读值 >= arg1
//                GT  匹配条件：读值 >  arg1
//                NE  匹配条件：读值 != arg1
//                匹配 → S_DONE
//                不匹配 → 基线回到 S_REQ_AR；公平模式进入 S_RETRY 并释放资源
//
//   S_DONE     ：脉冲 `done` 一个周期 → S_IDLE
//
// 公平模式每次只执行一次 Poll，失败后通过 retry 让原 Engine 重新竞标，
// 从而允许其他队列的 SIGNAL 或 WAIT 插入执行。
// ============================================================================

module VX_cp_event_unit
  import VX_cp_pkg::*;
#(
  parameter int ID_W = VX_CP_AXI_TID_WIDTH_C,
  parameter logic [ID_W-1:0] TID_PREFIX = '0,
  parameter bit ENABLE_WAIT_RELEASE = 1'b0
)(
  input  wire                       clk,
  input  wire                       reset,

  input  wire                       grant,
  // cmd 携带 arg0/arg1/arg2 以及头部（我们从中读取操作码）；
  // 其余字段被转发但本单元不使用。
  input  cmd_t                      cmd,
  output logic                      done,
  output logic                      retry,
  output wire                       ready,

  VX_mem_axi_if.master             axi_m
);

  // 本单元未使用的 cmd 字段（上面已读取操作码/arg0/arg1/arg2[1:0]）
  `UNUSED_VAR (cmd.hdr.reserved)
  `UNUSED_VAR (cmd.hdr.flags)
  `UNUSED_VAR (cmd.arg2[63:2])
  `UNUSED_VAR (cmd.profile_slot)

  // ---- 状态机 ----
  typedef enum logic [3:0] {
    S_IDLE, S_REQ_AW, S_REQ_W, S_WAIT_B,
            S_REQ_AR, S_WAIT_R, S_RETRY, S_DONE
  } state_e;

  state_e          state;
  logic [63:0]     addr_r;
  logic [63:0]     value_r;      // SIGNAL：要写入的值；WAIT：目标值
  wait_op_e        wait_op_r;
  logic            is_signal_r;

  // ---- WAIT 的组合比较逻辑 ----
  logic [63:0] rdata_lo;
  assign rdata_lo = axi_m.rdata[63:0];

  logic match;
  always_comb begin
    match = 1'b0;
    case (wait_op_r)
      WAIT_OP_EQ: match = (rdata_lo == value_r);
      WAIT_OP_GE: match = (rdata_lo >= value_r);
      WAIT_OP_GT: match = (rdata_lo >  value_r);
      WAIT_OP_NE: match = (rdata_lo != value_r);
      default:    match = 1'b0;
    endcase
  end

  // ---- 状态转移 ----
  always_ff @(posedge clk) begin
    if (reset) begin
      state       <= S_IDLE;
      addr_r      <= '0;
      value_r     <= '0;
      wait_op_r   <= WAIT_OP_EQ;
      is_signal_r <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (grant) begin
            addr_r      <= cmd.arg0;
            value_r     <= cmd.arg1;
            wait_op_r   <= wait_op_e'(cmd.arg2[1:0]);
            is_signal_r <= (cmd.hdr.opcode == CMD_EVENT_SIGNAL);
            state       <= (cmd.hdr.opcode == CMD_EVENT_SIGNAL)
                             ? S_REQ_AW : S_REQ_AR;
          end
        end

        // SIGNAL 路径
        S_REQ_AW: if (axi_m.awvalid && axi_m.awready) state <= S_REQ_W;
        S_REQ_W:  if (axi_m.wvalid  && axi_m.wready)  state <= S_WAIT_B;
        S_WAIT_B: if (axi_m.bvalid  && axi_m.bready)  state <= S_DONE;

        // WAIT 路径
        S_REQ_AR: if (axi_m.arvalid && axi_m.arready) state <= S_WAIT_R;
        S_WAIT_R: begin
          if (axi_m.rvalid && axi_m.rready) begin
            // 公平模式下，不满足条件的 WAIT 释放单元并通知原队列重新竞标。
            state <= match ? S_DONE
                           : (ENABLE_WAIT_RELEASE ? S_RETRY : S_REQ_AR);
          end
        end

        S_RETRY: state <= S_IDLE;
        S_DONE:  state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // ---- AXI 主设备输出驱动 ----
  always_comb begin
    // ---- AW（SIGNAL） ----
    axi_m.awvalid = (state == S_REQ_AW);
    axi_m.awaddr  = addr_r;
    axi_m.awid    = TID_PREFIX;
    axi_m.awlen   = 8'd0;        // 1 个节拍
    axi_m.awsize  = 3'd3;        // 2^3 = 8 字节
    axi_m.awburst = 2'b01;       // INCR

    // ---- W（SIGNAL） ----
    axi_m.wvalid = (state == S_REQ_W);
    axi_m.wdata  = '0;
    axi_m.wdata[63:0] = value_r;
    axi_m.wstrb  = '0;
    axi_m.wstrb[7:0] = 8'hFF;    // 字节 0..7 有效（总线的低 8 字节）
    axi_m.wlast  = 1'b1;

    // ---- B（SIGNAL） ----
    axi_m.bready = (state == S_WAIT_B);

    // ---- AR（WAIT） ----
    axi_m.arvalid = (state == S_REQ_AR);
    axi_m.araddr  = addr_r;
    axi_m.arid    = TID_PREFIX;
    axi_m.arlen   = 8'd0;
    axi_m.arsize  = 3'd3;
    axi_m.arburst = 2'b01;

    // ---- R（WAIT） ----
    axi_m.rready = (state == S_WAIT_R);

    // done 表示命令完成；retry 只表示本轮轮询未满足，不能触发退役。
    done = (state == S_DONE);
    retry = (state == S_RETRY);
  end

  // 仅空闲时允许仲裁器发出新授权，避免忙碌期间接受第二条命令。
  assign ready = (state == S_IDLE);

  // 辅助 / 未使用信号
  `UNUSED_VAR (axi_m.bid)
  `UNUSED_VAR (axi_m.bresp)
  `UNUSED_VAR (axi_m.rid)
  `UNUSED_VAR (axi_m.rlast)
  `UNUSED_VAR (axi_m.rresp)
  `UNUSED_VAR (is_signal_r)

endmodule : VX_cp_event_unit
