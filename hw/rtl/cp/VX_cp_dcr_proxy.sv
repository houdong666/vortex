// 版权所有 © 2019-2023
// 根据 Apache 许可证 2.0 版授权。

`include "VX_define.vh"

// ============================================================================
// VX_cp_dcr_proxy —— CP 与 Vortex 之间的 DCR 请求/响应网关。
// 由 DCR 资源仲裁器持有。
//
// 对于 CMD_DCR_WRITE（cmd.arg0 = dcr_addr，cmd.arg1 = dcr_value）：
//   IDLE → REQ（驱动 dcr_req，rw=1）→ DONE → IDLE。
//
// 对于 CMD_DCR_READ（cmd.arg0 = dcr_addr）：
//   IDLE → REQ（驱动 dcr_req，rw=0）→ WAIT_RSP（在 valid 有效时锁存 dcr_rsp_data）
//        → DONE → IDLE。
//
// 对于 CMD_CACHE_FLUSH（cmd.arg0 = 核心数量）：
//   缓存刷新是对每个核心执行 DCR 读操作，地址为 VX_DCR_BASE_CACHE_FLUSH，
//   其响应是该核心的刷新完成信号（参见 VX_dcr_data）。
//   一条 CMD_CACHE_FLUSH 命令会遍历每个核心执行该读操作——每个核心经历 REQ/WAIT_RSP——
//   并且仅在最后一个核心的刷新完成后才结束。这是 ACQUIRE_MEM 模型：
//   命令环中的单条命令，由 CP 在所有核心上执行，主机在 CMD_LAUNCH 之后发布，
//   以便看到一致的结果。主机从 VX_CAPS_NUM_CORES 填充 cmd.arg0。
//
// 最近的读响应值会发布在 `last_rsp_data` 上，同时也会暴露给 AXI-Lite 寄存器文件，
// 以便主机在观察到 seqnum 推进后可以轮询它。
// ============================================================================

module VX_cp_dcr_proxy
  import VX_cp_pkg::*;
(
  input  wire clk,
  input  wire reset,

  input  wire  grant,
  // verilator lint_off UNUSED
  // 这里只读取 cmd.hdr.opcode、cmd.arg0 和 cmd.arg1。arg2 和 profile_slot
  // 在传递给引擎时原样通过；顶层实例化将完整结构体传递给我们。
  input  cmd_t cmd,
  // verilator lint_on UNUSED
  output logic done,

  // 最近一次 CMD_DCR_READ 的响应值（读操作完成后在 `done` 为高时有效；
  // 写操作后固定为 0）。引擎在观察到读命令的 done 时捕获此值。
  output logic [`VX_DCR_DATA_BITS-1:0] last_rsp_data,

  // Vortex DCR 端口（通过 VX_cp_gpu_if 由 VX_cp_core 驱动）
  output logic                         dcr_req_valid,
  output logic                         dcr_req_rw,
  output logic [`VX_DCR_ADDR_BITS-1:0] dcr_req_addr,
  output logic [`VX_DCR_DATA_BITS-1:0] dcr_req_data,
  input  wire                          dcr_rsp_valid,
  input  wire  [`VX_DCR_DATA_BITS-1:0] dcr_rsp_data
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_REQ,           // 保持 dcr_req_valid 直到被消耗（此处为单周期）
    S_WAIT_RSP,      // 仅读命令使用
    S_DONE
  } state_e;

  // 用于 CMD_CACHE_FLUSH 的逐核心扫描计数器宽度。刷新
  // 目标为 dcr_req_data[15:0] 中的 `mpm_target_cid`（参见 VX_dcr_data）。
  localparam int CIDW = 16;

  state_e state;
  logic   pending_is_read;
  logic   pending_is_flush;
  // cmd 字段仅在一个周期内有效（grant 脉冲）；在 IDLE → REQ 时捕获。
  logic [`VX_DCR_ADDR_BITS-1:0]  pending_addr;
  logic [`VX_DCR_DATA_BITS-1:0]  pending_data;
  logic [`VX_DCR_DATA_BITS-1:0]  rsp_data_r;
  logic [CIDW-1:0]               flush_total;  // 剩余核心数 + 完成
  logic [CIDW-1:0]               flush_cid;    // 当前正在刷新的核心

  wire                          is_read    = (cmd.hdr.opcode == 8'(CMD_DCR_READ));
  wire                          is_flush   = (cmd.hdr.opcode == 8'(CMD_CACHE_FLUSH));
  wire [`VX_DCR_ADDR_BITS-1:0]  cmd_addr   = cmd.arg0[`VX_DCR_ADDR_BITS-1:0];
  wire [`VX_DCR_DATA_BITS-1:0]  cmd_data   = cmd.arg1[`VX_DCR_DATA_BITS-1:0];
  wire [CIDW-1:0]               cmd_ncores = cmd.arg0[CIDW-1:0];

  always_ff @(posedge clk) begin
    if (reset) begin
      state            <= S_IDLE;
      pending_is_read  <= 1'b0;
      pending_is_flush <= 1'b0;
      pending_addr     <= '0;
      pending_data     <= '0;
      rsp_data_r       <= '0;
      flush_total      <= '0;
      flush_cid        <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (grant) begin
            pending_is_read  <= is_read;
            pending_is_flush <= is_flush;
            pending_addr     <= cmd_addr;
            pending_data     <= cmd_data;
            if (is_flush) begin
              flush_total <= cmd_ncores;
              flush_cid   <= '0;
              // 零核心刷新（退化情况）立即结束
              state       <= (cmd_ncores == '0) ? S_DONE : S_REQ;
            end else begin
              state <= S_REQ;
            end
          end
        end
        S_REQ: begin
          // Vortex DCR 总线在单周期内消耗请求
          // （req_valid 握手是组合逻辑；无 req_ready 反压）。
          if (pending_is_read || pending_is_flush)
            state <= S_WAIT_RSP;
          else
            state <= S_DONE;
        end
        S_WAIT_RSP: begin
          if (dcr_rsp_valid) begin
            rsp_data_r <= dcr_rsp_data;
            if (pending_is_flush && ((flush_cid + CIDW'(1)) < flush_total)) begin
              // 当前核心已刷新；扫描前进到下一个核心
              flush_cid <= flush_cid + CIDW'(1);
              state     <= S_REQ;
            end else begin
              state <= S_DONE;
            end
          end
        end
        S_DONE: begin
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    dcr_req_valid = (state == S_REQ);
    if (pending_is_flush) begin
      // 缓存刷新是对每个核心执行 DCR 读操作，地址为 VX_DCR_BASE_CACHE_FLUSH；
      // 目标核心索引位于 dcr_req_data 的低 16 位。
      dcr_req_rw   = 1'b0;
      dcr_req_addr = `VX_DCR_ADDR_BITS'(`VX_DCR_BASE_CACHE_FLUSH);
      dcr_req_data = `VX_DCR_DATA_BITS'(flush_cid);
    end else begin
      dcr_req_rw   = !pending_is_read;
      dcr_req_addr = pending_addr;
      dcr_req_data = pending_data;
    end
    done          = (state == S_DONE);
    last_rsp_data = rsp_data_r;
  end

endmodule : VX_cp_dcr_proxy
