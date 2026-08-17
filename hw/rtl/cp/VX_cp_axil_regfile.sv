
// 版权 © 2019-2023
// 根据 Apache License, Version 2.0 授权许可。

`include "VX_define.vh"

// ============================================================================
// VX_cp_axil_regfile — CP 的 AXI4-Lite 主机控制寄存器块。
//
// 这是 CP 的 AXI-Lite 端口上唯一的从设备；VX_cp_core 将其 `axil_s` 接口
// 直接传递给本模块。
//
// 寄存器映射（16 位字节地址）：
//
//   全局寄存器 (0x000..0x0FF)
//     0x000 CP_CTRL     RW   位0=全局使能, 位1=全局复位
//     0x004 CP_STATUS   RO   位0=忙碌, 位1=错误
//     0x008 CP_DEV_CAPS RO   [7:0]队列数 | [15:8]最大环大小对数
//                            [23:16]AXI TID 宽度
//     0x010 CP_CYCLE_LO RO   自由运行周期计数低 32 位
//     0x014 CP_CYCLE_HI RO   高 32 位
//     0x018 GPU_DEV_CAPS_LO RO  设备配置能力，低 32 位
//     0x01C GPU_DEV_CAPS_HI RO  设备配置能力，高 32 位
//     0x020 GPU_ISA_CAPS_LO RO  ISA 能力，低 32 位
//     0x024 GPU_ISA_CAPS_HI RO  ISA 能力，高 32 位
//
//   每队列寄存器，基址 = 0x100 + qid * 0x40
//     +0x00 Q_RING_BASE_LO  RW
//     +0x04 Q_RING_BASE_HI  RW
//     +0x08 Q_HEAD_ADDR_LO  RW
//     +0x0C Q_HEAD_ADDR_HI  RW
//     +0x10 Q_CMPL_ADDR_LO  RW
//     +0x14 Q_CMPL_ADDR_HI  RW
//     +0x18 Q_RING_SIZE_LOG2 RW （掩码推导为：(1<<值) - 1）
//     +0x1C Q_CONTROL       RW   位0=使能, 位1=复位脉冲,
//                                位[3:2]=优先级, 位4=性能分析使能
//     +0x20 Q_TAIL_LO       WO   暂存
//     +0x24 Q_TAIL_HI       WO   暂存 + 原子提交脉冲
//     +0x28 Q_SEQNUM        RO   最新退役序号（镜像完成槽）
//     +0x2C Q_ERROR         RO   每队列错误字
//
// 原子尾规则：主机先写 Q_TAIL_LO 到暂存寄存器（不推进 q_state.tail），
// 然后写 Q_TAIL_HI，该写操作在同一周期内将暂存的高半部分与之前写入的
// 低半部分组合，并提交完整的 64 位值到 q_state.tail。只写 Q_TAIL_LO不会推进队列。
// ============================================================================

module VX_cp_axil_regfile
  import VX_cp_pkg::*;
#(
  parameter int NUM_QUEUES = VX_CP_NUM_QUEUES_C,
  parameter int ADDR_W     = 16,
  // 静态设备能力字段（综合时从 VX_cp_pkg 获取）。
  parameter int RING_SIZE_LOG2_MAX = VX_CP_RING_SIZE_LOG2_C,
  parameter int AXI_TID_W          = VX_CP_AXI_TID_WIDTH_C
)(
  input  wire                       clk,
  input  wire                       reset,

  // AXI-Lite 从端口（每个 cp_core 只有一个实例）。
  VX_cp_axil_s_if.slave             axil_s,

  // 汇总的 CP 状态（各队列状态相或，由 cp_core 驱动）。
  input  wire                       cp_busy,
  input  wire                       cp_error,

  // 来自每个 CPE 的每队列运行时遥测信息。
  input  wire [63:0]                q_head    [NUM_QUEUES],
  input  wire [63:0]                q_seqnum  [NUM_QUEUES],
  input  wire [31:0]                q_error   [NUM_QUEUES],

  // 最后一次 CMD_DCR_READ 响应（来自 VX_cp_dcr_proxy）。
  // 在偏移 0x130 处暴露，以便主机在轮询 Q_SEQNUM 后读取响应。
  input  wire [31:0]                last_dcr_rsp,

  // 输出到每个 CPE 的可编程状态。
  output cpe_state_t                q_state   [NUM_QUEUES],

  // 当主机写 Q_CONTROL.reset 时，每个队列产生一个周期的复位脉冲。
  output logic                      q_reset_pulse [NUM_QUEUES]
);

  localparam int QID_W = (NUM_QUEUES > 1) ? $clog2(NUM_QUEUES) : 1;

  // ---- 每队列可编程状态 ----
  logic [63:0] r_ring_base       [NUM_QUEUES];
  logic [63:0] r_head_addr       [NUM_QUEUES];
  logic [63:0] r_cmpl_addr       [NUM_QUEUES];
  logic [7:0]  r_ring_size_log2  [NUM_QUEUES];
  logic [31:0] r_control         [NUM_QUEUES];
  logic [63:0] r_tail            [NUM_QUEUES];

  // 尾高半部分暂存寄存器。主机可在提交前多次写 Q_TAIL_LO；
  // 在 Q_TAIL_HI 原子提交时始终使用最近写入的值。
  // 引入 “临时寄存区 + 原子提交” 机制。低32位先放进临时区，不更新实际 tail；
  // 高32位写入时，才把高低两部分拼成一个完整的64位数，一次性存入实际 r_tail。CP 硬件要么看到旧值，要么看到完整新值，绝无中间状态。
  logic [31:0] r_tail_lo_staging [NUM_QUEUES];

  // 从设备忽略 wstrb —— 每个主机写入都视为完整 32 位。
  // 不支持对 CP 寄存器的子字写入。
  `UNUSED_VAR (axil_s.wstrb)

  // ---- 全局寄存器 ----
  logic [31:0] r_cp_ctrl;
  logic [63:0] r_cycle_count;

  always_ff @(posedge clk) begin
    if (reset) r_cycle_count <= '0;
    else       r_cycle_count <= r_cycle_count + 64'd1;
  end

  // ---- 静态 GPU 能力字 ----
  // 作为只读寄存器暴露，使主机运行时从一个统一的中立源读取设备/ISA 能力。
  // sw/runtime/common/vx_caps.h 负责解码。
  localparam int GPU_CLUSTER_SIZE = `VX_CFG_NUM_CORES / `VX_CFG_SOCKET_SIZE;
  localparam int GPU_BANK_ADDR_W  = `VX_CFG_PLATFORM_MEMORY_ADDR_WIDTH
                                  - `CLOG2(`VX_CFG_PLATFORM_MEMORY_NUM_BANKS);

  wire [63:0] gpu_dev_caps = {
    22'b0,
    5'(GPU_BANK_ADDR_W - 20),
    3'($clog2(`VX_CFG_PLATFORM_MEMORY_NUM_BANKS)),
    8'(`VX_CFG_LMEM_ENABLED ? `VX_CFG_LMEM_LOG_SIZE : 0),
    3'($clog2(`VX_CFG_ISSUE_WIDTH)),
    3'($clog2(`VX_CFG_NUM_CLUSTERS)),
    3'($clog2(GPU_CLUSTER_SIZE)),
    3'($clog2(`VX_CFG_SOCKET_SIZE)),
    3'($clog2(`VX_CFG_NUM_WARPS)),
    3'($clog2(`VX_CFG_NUM_THREADS)),
    8'(`VX_ISA_IMPL_ID)
  };

  wire [63:0] gpu_isa_caps = {
    32'(`VX_CFG_MISA_EXT),
    2'(`CLOG2(`VX_CFG_XLEN)-4),
    30'(`VX_CFG_MISA_STD)
  };

  // ---- 地址解码辅助函数 ----
  // 如果 `addr` 是偏移量为 `g_off` 的全局寄存器，返回 1。
  // 全局寄存器占用 0x000..0x0FF。
  function automatic logic is_global(input logic [ADDR_W-1:0] addr,
                                     input logic [7:0]        g_off);
    return (addr[ADDR_W-1:8] == '0) && (addr[7:0] == g_off);
  endfunction

  // 如果 `addr` 落在每队列块范围内（0x100..0x100 + NUM_QUEUES * 0x40 - 1），
  // 返回 1，并解码出 (qid, offset)。
  function automatic logic decode_queue(input logic [ADDR_W-1:0] addr,
                                        output logic [QID_W-1:0] qid_o,
                                        output logic [5:0]       off_o);
    // 队列步长 0x40 = 64 B，因此 (addr - 0x100) 的低 6 位是队内偏移，
    // 接下来的 $clog2(NUM_QUEUES) 位是队列 id。高于 (qid|off) 的位
    // 被有意截断——我们首先进行范围检查。
    logic [ADDR_W-1:0] rel;
    logic [ADDR_W-1:0] end_addr;
    int                slot_idx;
    qid_o = '0;
    off_o = '0;
    end_addr = ADDR_W'(16'h0100) + ADDR_W'(NUM_QUEUES) * ADDR_W'(16'h0040);
    if (addr < ADDR_W'(16'h0100)) return 1'b0;
    if (addr >= end_addr)         return 1'b0;
    rel = addr - ADDR_W'(16'h0100);
    off_o = rel[5:0];
    qid_o = rel[QID_W+6-1:6];
    `UNUSED_VAR (rel[ADDR_W-1:QID_W+6])
    slot_idx = int'(qid_o);
    if (slot_idx >= NUM_QUEUES) return 1'b0;
    return 1'b1;
  endfunction

  // ---- 读数据组合解码 ----
  function automatic logic [31:0] read_reg(input logic [ADDR_W-1:0] addr);
    logic [QID_W-1:0] qid;
    logic [5:0]       off;
    if (is_global(addr, 8'h00)) return r_cp_ctrl;
    if (is_global(addr, 8'h04)) return {30'd0, cp_error, cp_busy};
    if (is_global(addr, 8'h08)) return {8'd0,
                                        8'(AXI_TID_W),
                                        8'(RING_SIZE_LOG2_MAX),
                                        8'(NUM_QUEUES)};
    if (is_global(addr, 8'h10)) return r_cycle_count[31:0];
    if (is_global(addr, 8'h14)) return r_cycle_count[63:32];
    if (is_global(addr, 8'h18)) return gpu_dev_caps[31:0];
    if (is_global(addr, 8'h1C)) return gpu_dev_caps[63:32];
    if (is_global(addr, 8'h20)) return gpu_isa_caps[31:0];
    if (is_global(addr, 8'h24)) return gpu_isa_caps[63:32];
    if (decode_queue(addr, qid, off)) begin
      case (off)
        6'h00: return r_ring_base[qid][31:0];
        6'h04: return r_ring_base[qid][63:32];
        6'h08: return r_head_addr[qid][31:0];
        6'h0C: return r_head_addr[qid][63:32];
        6'h10: return r_cmpl_addr[qid][31:0];
        6'h14: return r_cmpl_addr[qid][63:32];
        6'h18: return {24'd0, r_ring_size_log2[qid]};
        6'h1C: return r_control[qid];
        6'h20: return r_tail_lo_staging[qid];     // 只写；为调试提供回读
        6'h24: return r_tail[qid][63:32];         // 返回当前已提交的高半部分
        6'h28: return q_seqnum[qid][31:0];        // 只读镜像
        6'h2C: return q_error[qid];               // 只读
        6'h30: return last_dcr_rsp;               // 只读 — 最后一次 CMD_DCR_READ 响应
        default: return 32'h0;
      endcase
    end
    return 32'hDEAD_BEEF;   // 返回时伴随 DECERR；该值有助于调试
  endfunction

  function automatic logic is_decoded(input logic [ADDR_W-1:0] addr);
    logic [QID_W-1:0] qid;   // 由 decode_queue 填充，但此处未使用
    logic [5:0]       off;
    `UNUSED_VAR (qid)
    if (is_global(addr, 8'h00)) return 1'b1;
    if (is_global(addr, 8'h04)) return 1'b1;
    if (is_global(addr, 8'h08)) return 1'b1;
    if (is_global(addr, 8'h10)) return 1'b1;
    if (is_global(addr, 8'h14)) return 1'b1;
    if (is_global(addr, 8'h18)) return 1'b1;
    if (is_global(addr, 8'h1C)) return 1'b1;
    if (is_global(addr, 8'h20)) return 1'b1;
    if (is_global(addr, 8'h24)) return 1'b1;
    if (decode_queue(addr, qid, off)) begin
      case (off)
        6'h00, 6'h04, 6'h08, 6'h0C, 6'h10, 6'h14,
        6'h18, 6'h1C, 6'h20, 6'h24, 6'h28, 6'h2C, 6'h30: return 1'b1;
        default: return 1'b0;
      endcase
    end
    return 1'b0;
  endfunction

  // ============================================================================
  // 写通道 — AW 和 W 必须都到达才能提交写操作。
  // 我们接受它们到来的任意顺序，并在两者均到达时提交。
  // ============================================================================

  logic              wr_addr_buf_valid;
  logic [ADDR_W-1:0] wr_addr_buf;
  logic              wr_data_buf_valid;
  logic [31:0]       wr_data_buf;

  // 当对应的缓冲区无未决数据时，准备接收。
  assign axil_s.awready = !wr_addr_buf_valid;
  assign axil_s.wready  = !wr_data_buf_valid;

  logic wr_commit;
  assign wr_commit = wr_addr_buf_valid && wr_data_buf_valid && !axil_s.bvalid;

  always_ff @(posedge clk) begin
    if (reset) begin
      wr_addr_buf_valid <= 1'b0;
      wr_data_buf_valid <= 1'b0;
      wr_addr_buf       <= '0;
      wr_data_buf       <= '0;
    end else begin
      if (axil_s.awvalid && axil_s.awready) begin
        wr_addr_buf       <= axil_s.awaddr;
        wr_addr_buf_valid <= 1'b1;
      end
      if (axil_s.wvalid && axil_s.wready) begin
        wr_data_buf       <= axil_s.wdata;
        wr_data_buf_valid <= 1'b1;
      end
      if (wr_commit) begin
        wr_addr_buf_valid <= 1'b0;
        wr_data_buf_valid <= 1'b0;
      end
    end
  end

  // 写响应（B通道）。保持有效直到主机用 bready 确认。
  always_ff @(posedge clk) begin
    if (reset) begin
      axil_s.bvalid <= 1'b0;
      axil_s.bresp  <= 2'b00;
    end else begin
      if (wr_commit) begin
        axil_s.bvalid <= 1'b1;
        axil_s.bresp  <= is_decoded(wr_addr_buf) ? 2'b00 : 2'b11; // OKAY / DECERR
      end else if (axil_s.bvalid && axil_s.bready) begin
        axil_s.bvalid <= 1'b0;
      end
    end
  end

  // ---- 将写操作应用到底层寄存器 ----
  // q_reset_pulse 是由 Q_CONTROL.bit1 或 CP_CTRL.bit1 驱动的单周期脉冲；
  // 它在下一周期自动回到 0。
  always_ff @(posedge clk) begin
    automatic logic [QID_W-1:0] qid;
    automatic logic [5:0]       off;
    if (reset) begin
      r_cp_ctrl <= '0;
      for (int i = 0; i < NUM_QUEUES; ++i) begin
        r_ring_base[i]       <= '0;
        r_head_addr[i]       <= '0;
        r_cmpl_addr[i]       <= '0;
        r_ring_size_log2[i]  <= 8'(RING_SIZE_LOG2_MAX);
        r_control[i]         <= '0;
        r_tail[i]            <= '0;
        r_tail_lo_staging[i] <= '0;
        q_reset_pulse[i]     <= 1'b0;
      end
    end else begin
      // 默认每周期脉冲为低；下面提交路径会在请求复位的周期覆盖它。
      for (int i = 0; i < NUM_QUEUES; ++i) q_reset_pulse[i] <= 1'b0;

      if (wr_commit && is_decoded(wr_addr_buf)) begin
        if (is_global(wr_addr_buf, 8'h00)) begin
          r_cp_ctrl <= wr_data_buf;
          if (wr_data_buf[1]) begin
            for (int i = 0; i < NUM_QUEUES; ++i) q_reset_pulse[i] <= 1'b1;
          end
        end else if (decode_queue(wr_addr_buf, qid, off)) begin
          case (off)
            6'h00: r_ring_base[qid][31:0]  <= wr_data_buf;
            6'h04: r_ring_base[qid][63:32] <= wr_data_buf;
            6'h08: r_head_addr[qid][31:0]  <= wr_data_buf;
            6'h0C: r_head_addr[qid][63:32] <= wr_data_buf;
            6'h10: r_cmpl_addr[qid][31:0]  <= wr_data_buf;
            6'h14: r_cmpl_addr[qid][63:32] <= wr_data_buf;
            6'h18: r_ring_size_log2[qid]   <= wr_data_buf[7:0];
            6'h1C: begin
              r_control[qid] <= wr_data_buf;
              // bit1 = 自清除复位脉冲
              if (wr_data_buf[1]) q_reset_pulse[qid] <= 1'b1;
            end
            6'h20: r_tail_lo_staging[qid] <= wr_data_buf;
            6'h24: begin
              // 原子尾提交：将暂存的高半部分与低半部分组合 -> tail
              r_tail[qid] <= {wr_data_buf, r_tail_lo_staging[qid]};
            end
            default: ;
          endcase
        end
      end
    end
  end

  // ============================================================================
  // 读通道 — 单次突发。AR 锁存到缓冲区，R 在下一周期返回解码值
  // （因此解码链是寄存的）。
  // ============================================================================

  logic              rd_addr_buf_valid;
  logic [ADDR_W-1:0] rd_addr_buf;

  assign axil_s.arready = !rd_addr_buf_valid;

  always_ff @(posedge clk) begin
    if (reset) begin
      rd_addr_buf_valid <= 1'b0;
      rd_addr_buf       <= '0;
      axil_s.rvalid     <= 1'b0;
      axil_s.rdata      <= '0;
      axil_s.rresp      <= 2'b00;
    end else begin
      if (axil_s.arvalid && axil_s.arready) begin
        rd_addr_buf       <= axil_s.araddr;
        rd_addr_buf_valid <= 1'b1;
      end
      if (rd_addr_buf_valid && !axil_s.rvalid) begin
        axil_s.rdata      <= read_reg(rd_addr_buf);
        axil_s.rresp      <= is_decoded(rd_addr_buf) ? 2'b00 : 2'b11;
        axil_s.rvalid     <= 1'b1;
        rd_addr_buf_valid <= 1'b0;
      end else if (axil_s.rvalid && axil_s.rready) begin
        axil_s.rvalid <= 1'b0;
      end
    end
  end

  // ============================================================================
  // 从可编程寄存器和遥测信息驱动 q_state 输出。
  // ============================================================================
  always_comb begin
    for (int i = 0; i < NUM_QUEUES; ++i) begin
      q_state[i]                = '0;
      q_state[i].ring_base      = r_ring_base[i];
      q_state[i].ring_size_mask = (VX_CP_RING_SIZE_LOG2_C)'(
                                    ((64'd1) << r_ring_size_log2[i]) - 64'd1);
      q_state[i].head_addr      = r_head_addr[i];
      q_state[i].cmpl_addr      = r_cmpl_addr[i];
      q_state[i].tail           = r_tail[i];
      q_state[i].head           = q_head[i];
      q_state[i].seqnum         = q_seqnum[i];
      q_state[i].prio           = r_control[i][3:2];
      q_state[i].enabled        = r_control[i][0] & r_cp_ctrl[0];
      q_state[i].profile_en     = r_control[i][4];
    end
  end

  // ============================================================================
  // 只读遥测信号在 NUM_QUEUES==1 且并非所有位都被 q_state 消费时，
  // 需进行未使用抑制。
  // ============================================================================
  generate
    for (genvar gi = 0; gi < NUM_QUEUES; ++gi) begin : g_unused_telemetry
      `UNUSED_VAR (q_head[gi])
      `UNUSED_VAR (q_seqnum[gi])
      `UNUSED_VAR (q_error[gi])
    end
  endgenerate

endmodule : VX_cp_axil_regfile
