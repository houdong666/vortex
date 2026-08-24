
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
// VX_cp_arbiter —— 优先级优先、同优先级轮询的单周期仲裁器。
// 轮询指针始终移到获胜者之后，避免同优先级请求者被固定索引偏置。
// ============================================================================

module VX_cp_arbiter
  import VX_cp_pkg::*;
#(
  parameter int N = 1,
  parameter bit ENABLE_PRIORITY = 0
)(
  input  wire                  clk,
  input  wire                  reset,

  input  wire                  bid_valid    [N],
  input  wire [1:0]            bid_priority [N],
  output logic                 bid_grant    [N],
  output wire [(N > 1 ? $clog2(N) : 1)-1:0] rr_pointer_o,
  output wire [(N > 1 ? $clog2(N) : 1)-1:0] selected_queue_o
);
  localparam int PTR_W = (N > 1) ? $clog2(N) : 1;

  logic [PTR_W-1:0] rr_pointer;
  logic [PTR_W-1:0] selected_queue;
  logic             selected_valid;
  logic [1:0]       highest_priority;
  logic [N-1:0]     eligible;
  integer           i;
  integer           offset;
  integer           scan_index;

  assign rr_pointer_o     = rr_pointer;
  assign selected_queue_o = selected_queue;

  for (genvar g = 0; g < N; ++g) begin : g_ports
    assign bid_grant[g] = selected_valid && (selected_queue == PTR_W'(g));
  end

  always_comb begin
    highest_priority = '0;
    for (i = 0; i < N; ++i) begin
      if (bid_valid[i] && (bid_priority[i] > highest_priority))
        highest_priority = bid_priority[i];
    end

    for (i = 0; i < N; ++i) begin
      eligible[i] = bid_valid[i]
                 && (!ENABLE_PRIORITY || (bid_priority[i] == highest_priority));
    end

    selected_queue = rr_pointer;
    selected_valid = 1'b0;
    scan_index = int'(rr_pointer);
    for (offset = 0; offset < N; ++offset) begin
      scan_index = int'(rr_pointer) + offset;
      if (scan_index >= N)
        scan_index = scan_index - N;
      if (!selected_valid && eligible[scan_index]) begin
        selected_queue = PTR_W'(scan_index);
        selected_valid = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      rr_pointer <= '0;
    end else if (selected_valid) begin
      if (selected_queue == PTR_W'(N - 1))
        rr_pointer <= '0;
      else
        rr_pointer <= selected_queue + PTR_W'(1);
    end
  end

endmodule
