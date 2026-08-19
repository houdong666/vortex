
// 版权所有 © 2019-2023
//
// 根据 Apache 许可证 2.0 版（“许可证”）授权；
// 除非遵守许可证，否则您不得使用此文件。
// 您可以在以下网址获取许可证副本：
// http://www.apache.org/licenses/LICENSE-2.0
//
// 除非适用法律要求或书面同意，否则根据许可证分发的软件
// 是按“原样”分发的，无任何明示或暗示的担保或条件。
// 请参阅许可证了解具体语言的管理权限和限制。

`include "VX_define.vh"

// ============================================================================
// VX_cp_arbiter —— 针对 N 个请求者（KMU、DMA、DCR、event）的轮询仲裁器。
// 每个周期最多授予一个请求者，并将指针移至获胜者之后。
// 授予持续一个周期；没有飞行跟踪。`bid_priority` 预留且当前未使用。
// 库 VX_rr_arbiter 的薄封装。
// ============================================================================

module VX_cp_arbiter
  import VX_cp_pkg::*;
#(
  parameter int N = 1
)(
  input  wire                  clk,
  input  wire                  reset,

  input  wire                  bid_valid    [N],
  input  wire [1:0]            bid_priority [N],
  output logic                 bid_grant    [N]
);
  wire [N-1:0] requests;
  wire [N-1:0] grant_onehot;

  for (genvar i = 0; i < N; ++i) begin : g_ports
    assign requests[i]  = bid_valid[i];
    assign bid_grant[i] = grant_onehot[i];
    `UNUSED_VAR (bid_priority[i])
  end

  // grant_ready 固定为高：每个被服务的周期都消耗一次授予，使指针前进
  //（单周期、非粘性授予）。
  VX_rr_arbiter #(
    .NUM_REQS (N)
  ) rr_arb (
    .clk          (clk),
    .reset        (reset),
    .requests     (requests),
    `UNUSED_PIN   (grant_index),
    .grant_onehot (grant_onehot),
    `UNUSED_PIN   (grant_valid),
    .grant_ready  (1'b1)
  );

endmodule
