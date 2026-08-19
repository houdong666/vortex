// 版权所有 © 2019-2023
// 根据 Apache 许可证 2.0 版授权。

`include "VX_define.vh"

// ============================================================================
// VX_cp_dma —— 双端口突发 DMA 引擎，用于处理 CMD_MEM_WRITE / CMD_MEM_READ /
// CMD_MEM_COPY 命令。由 DMA 资源仲裁器持有。
//
// 命令编码：
//   arg0 = 目标地址
//   arg1 = 源地址
//   arg2 = 传输字节数（向上取整到 64 字节的倍数）
//
// 双端口：XRT 将每个内核的 AXI 主设备固定映射到一个内存资源
// （一个 HBM/DDR 存储体或 HOST[0]），因此 CP 携带两个主设备 —— axi_host 用于
// 主机内存（命令环驻留于此，并且是所有上传/下载的一端）和 axi_dev 用于设备内存。
// 操作码选择读取源端口和写入目标端口：
//   CMD_MEM_WRITE : 源 = host,   目标 = device   （上传）
//   CMD_MEM_READ  : 源 = device, 目标 = host     （下载）
//   CMD_MEM_COPY  : 源 = device, 目标 = device   （设备本地拷贝）
//
// 传输以 <=4 KB 的块为单位流式进行；每个块是一个 AXI INCR 突发
// （最多 MAX_BURST 个 512 位节拍），因此没有突发会跨越 4 KB 地址边界。
// 一个块先完整读入 buf_r，然后写入 —— 顺序执行，非流水线。
//
// 状态机：
//   S_IDLE   : 获得授权 -> 锁存操作码/目标/源/大小                 -> S_SETUP
//   S_SETUP  : 大小为 0 -> S_DONE；否则计算当前块大小             -> S_REQ_AR
//   S_REQ_AR : 在读端口驱动 AR；arready 有效                     -> S_READ
//   S_READ   : 将 rdata 节拍捕获到 buf_r 中；最后一个节拍        -> S_REQ_AW
//   S_REQ_AW : 在写端口驱动 AW；awready 有效                     -> S_WRITE
//   S_WRITE  : 从 buf_r 驱动 W 节拍；最后一个节拍                -> S_WAIT_B
//   S_WAIT_B : bvalid 有效 -> 推进当前块                         -> S_SETUP
//   S_DONE   : 脉冲 `done` 一个周期                               -> S_IDLE
// ============================================================================

module VX_cp_dma
  import VX_cp_pkg::*;
#(
  parameter int ID_W = VX_CP_AXI_TID_WIDTH_C,
  parameter logic [ID_W-1:0] TID_PREFIX = '0
)(
  input  wire                       clk,
  input  wire                       reset,

  input  wire                       grant,
  input  cmd_t                      cmd,
  output logic                      done,

  // 主机内存 AXI 主设备（命令环侧 / 上传源 / 下载目标）
  VX_mem_axi_if.master             axi_host,
  // 设备内存 AXI 主设备
  VX_mem_axi_if.master             axi_dev
);

  localparam int MAX_BURST = 64;          // 64 x 64 B = 每个突发最大 4 KB
  localparam int BIDX_W    = 6;           // 节拍索引 0..63
  localparam int BCNT_W    = 7;           // 块长度 1..64

  typedef enum logic [2:0] {
    S_IDLE, S_SETUP, S_REQ_AR, S_READ, S_REQ_AW, S_WRITE, S_WAIT_B, S_DONE
  } state_e;

  state_e               state;
  logic [7:0]           op_r;             // 锁存的操作码（主机/设备路由）
  logic [63:0]          dst_r, src_r;
  logic [63:0]          rem_beats;        // 仍需传输的 64 B 节拍数
  logic [BCNT_W-1:0]    chunk_beats;      // 当前块的节拍数
  logic [BIDX_W-1:0]    beat_idx;
  logic [CL_BITS-1:0]   buf_r [MAX_BURST];

  // 从 64 B 对齐地址到下一个 4 KB 边界的节拍数。`cl_idx`
  // 是 4 KB 页内的缓存行索引（addr[11:6]，0..63）。
  function automatic logic [BCNT_W-1:0] beats_to_4k(input logic [5:0] cl_idx);
    return BCNT_W'(MAX_BURST) - BCNT_W'({1'b0, cl_idx});
  endfunction

  // 下一个块长度 = min(rem_beats, 源 4K 跨度, 目标 4K 跨度)
  logic [BCNT_W-1:0] next_chunk;
  always_comb begin
    logic [BCNT_W-1:0] s4k, d4k, lim;
    s4k = beats_to_4k(src_r[11:6]);
    d4k = beats_to_4k(dst_r[11:6]);
    lim = (s4k < d4k) ? s4k : d4k;
    if (rem_beats < 64'({1'b0, lim}))
      next_chunk = BCNT_W'(rem_beats);
    else
      next_chunk = lim;
  end

  // 从锁存的操作码选择读取源 / 写入目标端口
  wire rd_from_host = (cp_opcode_e'(op_r) == CMD_MEM_WRITE);  // 上传：读取主机
  wire wr_to_host   = (cp_opcode_e'(op_r) == CMD_MEM_READ);   // 下载：写入主机

  // 当前块的最后一个节拍
  wire last_beat = (BCNT_W'({1'b0, beat_idx}) == (chunk_beats - BCNT_W'(1)));

  // ---- 状态机 ----
  always_ff @(posedge clk) begin
    if (reset) begin
      state       <= S_IDLE;
      op_r        <= '0;
      dst_r       <= '0;
      src_r       <= '0;
      rem_beats   <= '0;
      chunk_beats <= '0;
      beat_idx    <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (grant) begin
            op_r      <= cmd.hdr.opcode;
            dst_r     <= cmd.arg0;
            src_r     <= cmd.arg1;
            // 将字节计数向上取整到完整缓存行
            rem_beats <= (cmd.arg2 + 64'd63) >> 6;
            state     <= S_SETUP;
          end
        end
        S_SETUP: begin
          if (rem_beats == 64'd0) begin
            state <= S_DONE;
          end else begin
            chunk_beats <= next_chunk;
            beat_idx    <= '0;
            state       <= S_REQ_AR;
          end
        end
        S_REQ_AR: begin
          if (rd_arvalid && rd_arready) begin
            beat_idx <= '0;
            state    <= S_READ;
          end
        end
        S_READ: begin
          if (rd_rvalid && rd_rready) begin
            buf_r[beat_idx] <= rd_rdata;
            if (last_beat) begin
              beat_idx <= '0;
              state    <= S_REQ_AW;
            end else begin
              beat_idx <= beat_idx + BIDX_W'(1);
            end
          end
        end
        S_REQ_AW: begin
          if (wr_awvalid && wr_awready) begin
            beat_idx <= '0;
            state    <= S_WRITE;
          end
        end
        S_WRITE: begin
          if (wr_wvalid && wr_wready) begin
            if (last_beat) begin
              state <= S_WAIT_B;
            end else begin
              beat_idx <= beat_idx + BIDX_W'(1);
            end
          end
        end
        S_WAIT_B: begin
          if (wr_bvalid && wr_bready) begin
            src_r     <= src_r + (64'({1'b0, chunk_beats}) << 6);
            dst_r     <= dst_r + (64'({1'b0, chunk_beats}) << 6);
            rem_beats <= rem_beats - 64'({1'b0, chunk_beats});
            state     <= S_SETUP;
          end
        end
        S_DONE: begin
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // ---- 逻辑读通道 ----
  wire               rd_arvalid = (state == S_REQ_AR);
  wire               rd_rready  = (state == S_READ);
  wire               rd_arready = rd_from_host ? axi_host.arready : axi_dev.arready;
  wire               rd_rvalid  = rd_from_host ? axi_host.rvalid  : axi_dev.rvalid;
  wire [CL_BITS-1:0] rd_rdata   = rd_from_host ? axi_host.rdata   : axi_dev.rdata;

  // ---- 逻辑写通道 ----
  wire               wr_awvalid = (state == S_REQ_AW);
  wire               wr_wvalid  = (state == S_WRITE);
  wire               wr_bready  = (state == S_WAIT_B);
  wire               wr_awready = wr_to_host ? axi_host.awready : axi_dev.awready;
  wire               wr_wready  = wr_to_host ? axi_host.wready  : axi_dev.wready;
  wire               wr_bvalid  = wr_to_host ? axi_host.bvalid  : axi_dev.bvalid;

  wire [7:0]         burst_len  = 8'({1'b0, chunk_beats - BCNT_W'(1)});

  // ---- 驱动两个 AXI 主设备；只有路由端口有效时断言 valid ----
  always_comb begin
    // ----- axi_host -----
    axi_host.arvalid = rd_arvalid &  rd_from_host;
    axi_host.araddr  = src_r;
    axi_host.arid    = TID_PREFIX;
    axi_host.arlen   = burst_len;
    axi_host.arsize  = 3'd6;                 // 每个节拍 64 字节
    axi_host.arburst = 2'b01;                // INCR
    axi_host.rready  = rd_rready  &  rd_from_host;

    axi_host.awvalid = wr_awvalid &  wr_to_host;
    axi_host.awaddr  = dst_r;
    axi_host.awid    = TID_PREFIX;
    axi_host.awlen   = burst_len;
    axi_host.awsize  = 3'd6;
    axi_host.awburst = 2'b01;
    axi_host.wvalid  = wr_wvalid  &  wr_to_host;
    axi_host.wdata   = buf_r[beat_idx];
    axi_host.wstrb   = '1;
    axi_host.wlast   = last_beat;
    axi_host.bready  = wr_bready  &  wr_to_host;

    // ----- axi_dev -----
    axi_dev.arvalid  = rd_arvalid & ~rd_from_host;
    axi_dev.araddr   = src_r;
    axi_dev.arid     = TID_PREFIX;
    axi_dev.arlen    = burst_len;
    axi_dev.arsize   = 3'd6;
    axi_dev.arburst  = 2'b01;
    axi_dev.rready   = rd_rready  & ~rd_from_host;

    axi_dev.awvalid  = wr_awvalid & ~wr_to_host;
    axi_dev.awaddr   = dst_r;
    axi_dev.awid     = TID_PREFIX;
    axi_dev.awlen    = burst_len;
    axi_dev.awsize   = 3'd6;
    axi_dev.awburst  = 2'b01;
    axi_dev.wvalid   = wr_wvalid  & ~wr_to_host;
    axi_dev.wdata    = buf_r[beat_idx];
    axi_dev.wstrb    = '1;
    axi_dev.wlast    = last_beat;
    axi_dev.bready   = wr_bready  & ~wr_to_host;

    done = (state == S_DONE);
  end

  // 辅助 / 未使用信号
  `UNUSED_VAR (cmd.hdr.flags)
  `UNUSED_VAR (cmd.hdr.reserved)
  `UNUSED_VAR (cmd.profile_slot)
  `UNUSED_VAR (axi_host.bid)
  `UNUSED_VAR (axi_host.bresp)
  `UNUSED_VAR (axi_host.rid)
  `UNUSED_VAR (axi_host.rlast)
  `UNUSED_VAR (axi_host.rresp)
  `UNUSED_VAR (axi_dev.bid)
  `UNUSED_VAR (axi_dev.bresp)
  `UNUSED_VAR (axi_dev.rid)
  `UNUSED_VAR (axi_dev.rlast)
  `UNUSED_VAR (axi_dev.rresp)

endmodule : VX_cp_dma
