
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
// Aging 会逐段提升长时间等待者的有效优先级，避免严格优先级导致饥饿。
// ============================================================================

module VX_cp_arbiter
  import VX_cp_pkg::*;
#(
  parameter int N = 1,
  parameter bit ENABLE_PRIORITY = 0,
  parameter bit ENABLE_AGING = 0
)(
  input  wire                  clk,
  input  wire                  reset,
  // 共享执行单元忙碌时只累计等待时间，不得让请求者误认为已经获权。
  input  wire                  grant_enable,

  input  wire                  bid_valid    [N],
  input  wire [1:0]            bid_priority [N],
  output logic                 bid_grant    [N],
  output wire [(N > 1 ? $clog2(N) : 1)-1:0] rr_pointer_o,
  output wire [(N > 1 ? $clog2(N) : 1)-1:0] selected_queue_o,
  output wire [6:0]            wait_counter_o      [N],
  output wire [1:0]            aging_boost_o       [N],
  output wire [1:0]            effective_priority_o[N]
);
  localparam int PTR_W = (N > 1) ? $clog2(N) : 1;

  logic [PTR_W-1:0] rr_pointer;
  logic [PTR_W-1:0] selected_queue;
  logic             selected_valid;
  logic [1:0]       highest_priority;
  logic [N-1:0]     eligible;
  logic [6:0]       wait_counter       [N];
  logic [1:0]       aging_boost        [N];
  logic [1:0]       effective_priority [N];
  integer           i;
  integer           j;
  integer           offset;
  integer           scan_index;

  assign rr_pointer_o     = rr_pointer;
  assign selected_queue_o = selected_queue;

  for (genvar g = 0; g < N; ++g) begin : g_ports
    assign bid_grant[g] = grant_enable && selected_valid
                       && (selected_queue == PTR_W'(g));
    assign wait_counter_o[g]       = wait_counter[g];
    assign aging_boost_o[g]        = aging_boost[g];
    assign effective_priority_o[g] = effective_priority[g];
  end

  always_comb begin
    // 等待周期达到 16/32/64 时分别提升 1/2/3 级。
    for (i = 0; i < N; ++i) begin
      if (!ENABLE_AGING || (wait_counter[i] < 7'd16))
        aging_boost[i] = 2'd0;
      else if (wait_counter[i] < 7'd32)
        aging_boost[i] = 2'd1;
      else if (wait_counter[i] < 7'd64)
        aging_boost[i] = 2'd2;
      else
        aging_boost[i] = 2'd3;

      // 有效优先级在 P3 饱和，防止 2 位加法溢出回绕。
      if ({1'b0, bid_priority[i]} + {1'b0, aging_boost[i]} >= 3'd3)
        effective_priority[i] = 2'd3;
      else
        effective_priority[i] = bid_priority[i] + aging_boost[i];
    end

    highest_priority = '0;
    for (i = 0; i < N; ++i) begin
      if (bid_valid[i] && (effective_priority[i] > highest_priority))
        highest_priority = effective_priority[i];
    end

    for (i = 0; i < N; ++i) begin
      eligible[i] = bid_valid[i]
                 && (!ENABLE_PRIORITY || (effective_priority[i] == highest_priority));
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
      for (j = 0; j < N; ++j)
        wait_counter[j] <= '0;
    end else begin
      if (grant_enable && selected_valid) begin
        if (selected_queue == PTR_W'(N - 1))
          rr_pointer <= '0;
        else
          rr_pointer <= selected_queue + PTR_W'(1);
      end

      for (j = 0; j < N; ++j) begin
        // 撤销请求或成功获权都结束本轮等待；其余持续请求饱和累加。
        if (!ENABLE_AGING
         || !bid_valid[j]
         || (grant_enable && selected_valid
          && (selected_queue == PTR_W'(j)))) begin
          wait_counter[j] <= '0;
        end else if (wait_counter[j] != 7'h7f) begin
          wait_counter[j] <= wait_counter[j] + 7'd1;
        end
      end
    end
  end

endmodule
