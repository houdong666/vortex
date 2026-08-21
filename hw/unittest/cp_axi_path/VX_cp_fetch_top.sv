// 版权所有 © 2019-2023
// 根据 Apache License, Version 2.0 授权许可。

`include "VX_define.vh"

// 仅用于实验六 PPA 的扁平端口封装；功能验证仍使用完整 AXI path wrapper。
module VX_cp_fetch_top
  import VX_cp_pkg::*;
#(
  parameter int ADDR_W = 64,
  parameter int DATA_W = 512,
  parameter int ID_W = VX_CP_AXI_TID_WIDTH_C,
  parameter int PREFETCH_DEPTH = 2
)(
  input  wire                         clk,
  input  wire                         reset,
  input  wire [$bits(cpe_state_t)-1:0] state_in_packed,
  output wire [63:0]                  head_out,
  output wire                         cmd_out_valid,
  output wire [$bits(cmd_t)-1:0]      cmd_out_packed,
  input  wire                         cmd_out_ready,
  output wire                         m_arvalid,
  input  wire                         m_arready,
  output wire [ADDR_W-1:0]            m_araddr,
  output wire [ID_W-1:0]              m_arid,
  output wire [7:0]                   m_arlen,
  output wire [2:0]                   m_arsize,
  output wire [1:0]                   m_arburst,
  input  wire                         m_rvalid,
  output wire                         m_rready,
  input  wire [DATA_W-1:0]            m_rdata,
  input  wire [ID_W-1:0]              m_rid,
  input  wire                         m_rlast,
  input  wire [1:0]                   m_rresp
);

  VX_mem_axi_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) axi_if ();
  cpe_state_t state_typed;
  cmd_t cmd_typed;

  assign state_typed = cpe_state_t'(state_in_packed);
  assign cmd_out_packed = cmd_typed;
  assign m_arvalid = axi_if.arvalid;
  assign axi_if.arready = m_arready;
  assign m_araddr = axi_if.araddr;
  assign m_arid = axi_if.arid;
  assign m_arlen = axi_if.arlen;
  assign m_arsize = axi_if.arsize;
  assign m_arburst = axi_if.arburst;
  assign axi_if.rvalid = m_rvalid;
  assign m_rready = axi_if.rready;
  assign axi_if.rdata = m_rdata;
  assign axi_if.rid = m_rid;
  assign axi_if.rlast = m_rlast;
  assign axi_if.rresp = m_rresp;

  assign axi_if.awready = 1'b0;
  assign axi_if.wready = 1'b0;
  assign axi_if.bvalid = 1'b0;
  assign axi_if.bid = '0;
  assign axi_if.bresp = '0;

  VX_cp_fetch #(
    .QID            (0),
    .PREFETCH_DEPTH (PREFETCH_DEPTH)
  ) u_fetch (
    .clk           (clk),
    .reset         (reset),
    .state_in      (state_typed),
    .head_out      (head_out),
    .cmd_out_valid (cmd_out_valid),
    .cmd_out       (cmd_typed),
    .cmd_out_ready (cmd_out_ready),
    .axi_m         (axi_if)
  );

endmodule : VX_cp_fetch_top
