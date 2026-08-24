// 实验9四队列集成测试顶层：覆盖 Engine、Arbiter 和 EVENT 单元的真实握手。
`include "VX_define.vh"

module VX_cp_event_fairness_top
  import VX_cp_pkg::*;
#(
  parameter bit ENABLE_EVENT_WAIT_FAIRNESS = 1'b1
)(
  input  wire clk,
  input  wire reset,
  input  wire start,
  input  wire release_x,
  output wire [3:0] retire_evt,
  output wire [3:0] event_bid,
  output wire [3:0] event_grant,
  output wire event_ready,
  output wire event_retry,
  output wire event_done,
  output wire [7:0] event_state,
  output wire [31:0] poll_count,
  output wire [31:0] busy_cycles
);
  // 测试顶层只观察公平性相关信号，其余 AXI 属性和竞标载荷有意不采样。
  /* verilator lint_off UNUSEDSIGNAL */
  localparam int N = 4;
  localparam logic [63:0] X_ADDR = 64'h1000;

  VX_cp_engine_bid_if bid_kmu[N]();
  VX_cp_engine_bid_if bid_dma[N]();
  VX_cp_engine_bid_if bid_dcr[N]();
  VX_cp_engine_bid_if bid_evt[N]();
  logic [3:0] cmd_pending;
  logic [63:0] seqnum[N];
  logic valid_gated[N];
  wire evt_valid[N];
  logic [1:0] bid_prio[N];
  logic grant[N];
  cmd_t commands[N];

  VX_mem_axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(VX_CP_AXI_TID_WIDTH_C)) event_axi();

  // Q0 等待 X，Q1～Q3 写入三个独立事件；测试台稍后单独释放 X。
  always_comb begin
    for (int q = 0; q < N; ++q) begin
      commands[q] = '0;
      commands[q].hdr.opcode = (q == 0) ? CMD_EVENT_WAIT : CMD_EVENT_SIGNAL;
      commands[q].arg0 = (q == 0) ? X_ADDR : (X_ADDR + 64'(q * 8));
      commands[q].arg1 = 64'd1;
      commands[q].arg2 = 64'(WAIT_OP_GE);
      bid_prio[q] = 2'd0;
      valid_gated[q] = evt_valid[q] && event_ready;
    end
  end

  always_ff @(posedge clk) begin
    if (reset)
      cmd_pending <= '0;
    else begin
      if (start)
        cmd_pending <= 4'hf;
      for (int q = 0; q < N; ++q) begin
        if (cmd_pending[q] && evt_valid[q])
          cmd_pending[q] <= 1'b0;
      end
    end
  end

  for (genvar q = 0; q < N; ++q) begin : g_engines
    assign evt_valid[q] = bid_evt[q].valid;
    assign bid_evt[q].grant = grant[q];
    assign bid_kmu[q].grant = 1'b0;
    assign bid_dma[q].grant = 1'b0;
    assign bid_dcr[q].grant = 1'b0;
    VX_cp_engine #(.QID(q)) u_engine (
      .clk(clk), .reset(reset), .prio_in(2'd0), .seqnum_out(seqnum[q]),
      .cmd_in_valid(cmd_pending[q]), .cmd_in(commands[q]), `UNUSED_PIN(cmd_in_ready),
      .bid_kmu(bid_kmu[q]), .bid_dma(bid_dma[q]), .bid_dcr(bid_dcr[q]),
      .bid_event(bid_evt[q]), .kmu_done_i(1'b0), .dma_done_i(1'b0),
      .dcr_done_i(1'b0), .event_done_i(event_done), .event_retry_i(event_retry),
      .retire_evt(retire_evt[q]), `UNUSED_PIN(retire_seqnum), .retire_ready_i(1'b1),
      `UNUSED_PIN(submit_evt), `UNUSED_PIN(start_evt), `UNUSED_PIN(end_evt),
      `UNUSED_PIN(profile_slot)
    );
    assign event_bid[q] = evt_valid[q];
    assign event_grant[q] = grant[q];
    assign event_state[2*q +: 2] = u_engine.fsm[1:0];
  end

  VX_cp_arbiter #(.N(N)) u_arbiter (
    .clk(clk), .reset(reset), .bid_valid(valid_gated), .bid_priority(bid_prio),
    .bid_grant(grant), `UNUSED_PIN(rr_pointer_o), `UNUSED_PIN(selected_queue_o),
    `UNUSED_PIN(wait_counter_o), `UNUSED_PIN(aging_boost_o),
    `UNUSED_PIN(effective_priority_o)
  );

  logic any_grant;
  cmd_t granted_cmd;
  always_comb begin
    any_grant = 1'b0;
    granted_cmd = '0;
    for (int q = 0; q < N; ++q) begin
      if (grant[q]) begin
        any_grant = 1'b1;
        granted_cmd = commands[q];
      end
    end
  end

  VX_cp_event_unit #(.ENABLE_WAIT_RELEASE(ENABLE_EVENT_WAIT_FAIRNESS)) u_event (
    .clk(clk), .reset(reset), .grant(any_grant), .cmd(granted_cmd),
    .done(event_done), .retry(event_retry), .ready(event_ready), .axi_m(event_axi)
  );

  // 简化的单周期设备内存：足以精确验证 EVENT 读写顺序和释放行为。
  logic [63:0] event_mem[4];
  logic [63:0] write_addr;
  logic bvalid_r, rvalid_r;
  logic [511:0] rdata_r;
  logic [31:0] poll_count_r, busy_cycles_r;
  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < 4; ++i) event_mem[i] <= '0;
      write_addr <= '0;
      bvalid_r <= 1'b0;
      rvalid_r <= 1'b0;
      rdata_r <= '0;
      poll_count_r <= '0;
      busy_cycles_r <= '0;
    end else begin
      if (release_x) event_mem[0] <= 64'd1;
      if (!event_ready) busy_cycles_r <= busy_cycles_r + 1;
      if (event_axi.awvalid) write_addr <= event_axi.awaddr;
      if (event_axi.wvalid) begin
        event_mem[write_addr[4:3]] <= event_axi.wdata[63:0];
        bvalid_r <= 1'b1;
      end else if (bvalid_r && event_axi.bready) begin
        bvalid_r <= 1'b0;
      end
      if (event_axi.arvalid) begin
        rdata_r <= '0;
        rdata_r[63:0] <= event_mem[event_axi.araddr[4:3]];
        rvalid_r <= 1'b1;
        poll_count_r <= poll_count_r + 1;
      end else if (rvalid_r && event_axi.rready) begin
        rvalid_r <= 1'b0;
      end
    end
  end

  assign event_axi.awready = 1'b1;
  assign event_axi.wready = 1'b1;
  assign event_axi.bvalid = bvalid_r;
  assign event_axi.bid = '0;
  assign event_axi.bresp = '0;
  assign event_axi.arready = 1'b1;
  assign event_axi.rvalid = rvalid_r;
  assign event_axi.rdata = rdata_r;
  assign event_axi.rid = '0;
  assign event_axi.rlast = 1'b1;
  assign event_axi.rresp = '0;
  assign poll_count = poll_count_r;
  assign busy_cycles = busy_cycles_r;
endmodule
