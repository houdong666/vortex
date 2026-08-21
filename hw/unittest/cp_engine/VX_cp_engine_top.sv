// 版权所有 © 2019-2023
// 根据 Apache 许可证 2.0 版授权。

`include "VX_define.vh"

// ============================================================================
// VX_cp_engine_top —— 便于 Verilator 驱动的 VX_cp_engine 包装模块。
//
// VX_cp_engine 通过 SystemVerilog 接口连接四个资源仲裁器，而 C++ 测试台
// 无法直接驱动这些接口。本包装模块在内部实例化四个竞标接口，将其展开为
// C++ 测试台可读写的扁平端口，再通过 modport 连接到引擎。
//
// CPE 状态镜像精简为 `state_prio` 输入；这是引擎 FSM 唯一使用的队列状态
// 字段，用于标记仲裁竞标。包装模块还导出 FSM 和 seqnum 观测点供单测检查。
// ============================================================================

module VX_cp_engine_top
  import VX_cp_pkg::*;
#(
  parameter bit ENABLE_NOP_FAST_PATH = 1'b1
)
(
  input  wire        clk,
  input  wire        reset,

  // CPE 状态镜像——引擎竞标线只使用 `prio`。
  input  wire [1:0]  state_prio,

  // 命令流输入（打包后的 cmd_t）。
  input  wire                          cmd_in_valid,
  input  wire [$bits(cmd_t)-1:0]       cmd_in_packed,
  output wire                          cmd_in_ready,

  // 各资源的扁平竞标信号。
  output wire                          bid_kmu_valid,
  output wire [1:0]                    bid_kmu_prio,
  output wire [$bits(cmd_t)-1:0]       bid_kmu_cmd,
  input  wire                          bid_kmu_grant,

  output wire                          bid_dma_valid,
  output wire [1:0]                    bid_dma_prio,
  output wire [$bits(cmd_t)-1:0]       bid_dma_cmd,
  input  wire                          bid_dma_grant,

  output wire                          bid_dcr_valid,
  output wire [1:0]                    bid_dcr_prio,
  output wire [$bits(cmd_t)-1:0]       bid_dcr_cmd,
  input  wire                          bid_dcr_grant,

  output wire                          bid_event_valid,
  output wire [1:0]                    bid_event_prio,
  output wire [$bits(cmd_t)-1:0]       bid_event_cmd,
  input  wire                          bid_event_grant,

  // 资源完成脉冲，由测试台驱动以模拟资源模块执行完毕。若旧测试仍把授权
  // 视为完成，可直接把这些信号连接到延迟一周期的相应 bid_*_grant 输入。
  input  wire                          kmu_done_i,
  input  wire                          dma_done_i,
  input  wire                          dcr_done_i,
  input  wire                          event_done_i,

  // 退役信号。
  output wire                          retire_evt,
  output wire [63:0]                   retire_seqnum,
  output wire [63:0]                   seqnum_out,
  output wire [2:0]                    engine_fsm,
  output wire                          nop_fast_path,

  // 性能分析脉冲。
  output wire                          submit_evt,
  output wire                          start_evt,
  output wire                          end_evt,
  output wire [63:0]                   profile_slot
);

  // ---- 将 cmd_in_packed 转回引擎使用的 cmd_t ----------------------------
  cmd_t cmd_in_typed;
  assign cmd_in_typed = cmd_t'(cmd_in_packed);

  // ---- 引擎退役序号观测信号 ----------------------------------------------
  wire [63:0] seqnum_out_w;

  // ---- 竞标接口 ---------------------------------------------------------
  VX_cp_engine_bid_if bid_kmu_if   ();
  VX_cp_engine_bid_if bid_dma_if   ();
  VX_cp_engine_bid_if bid_dcr_if   ();
  VX_cp_engine_bid_if bid_event_if ();

  // 测试台驱动引擎授权信号，并读取引擎输出。
  assign bid_kmu_if.grant   = bid_kmu_grant;
  assign bid_dma_if.grant   = bid_dma_grant;
  assign bid_dcr_if.grant   = bid_dcr_grant;
  assign bid_event_if.grant = bid_event_grant;

  assign bid_kmu_valid = bid_kmu_if.valid;
  assign bid_kmu_prio  = bid_kmu_if.priority_;
  assign bid_kmu_cmd   = bid_kmu_if.cmd;

  assign bid_dma_valid = bid_dma_if.valid;
  assign bid_dma_prio  = bid_dma_if.priority_;
  assign bid_dma_cmd   = bid_dma_if.cmd;

  assign bid_dcr_valid = bid_dcr_if.valid;
  assign bid_dcr_prio  = bid_dcr_if.priority_;
  assign bid_dcr_cmd   = bid_dcr_if.cmd;

  assign bid_event_valid = bid_event_if.valid;
  assign bid_event_prio  = bid_event_if.priority_;
  assign bid_event_cmd   = bid_event_if.cmd;

  // ---- 被测模块 ---------------------------------------------------------
  logic cmd_in_ready_w;
  assign cmd_in_ready = cmd_in_ready_w;

  VX_cp_engine #(
    .QID(0),
    .ENABLE_NOP_FAST_PATH(ENABLE_NOP_FAST_PATH)
  ) u_engine (
    .clk           (clk),
    .reset         (reset),
    .prio_in       (state_prio),
    .seqnum_out    (seqnum_out_w),
    .cmd_in_valid  (cmd_in_valid),
    .cmd_in        (cmd_in_typed),
    .cmd_in_ready  (cmd_in_ready_w),
    .bid_kmu       (bid_kmu_if),
    .bid_dma       (bid_dma_if),
    .bid_dcr       (bid_dcr_if),
    .bid_event     (bid_event_if),
    .kmu_done_i    (kmu_done_i),
    .dma_done_i    (dma_done_i),
    .dcr_done_i    (dcr_done_i),
    .event_done_i  (event_done_i),
    .retire_evt    (retire_evt),
    .retire_seqnum (retire_seqnum),
    .retire_ready_i(1'b1),                // unit-test: completion is always ready
    .submit_evt    (submit_evt),
    .start_evt     (start_evt),
    .end_evt       (end_evt),
    .profile_slot  (profile_slot)
  );

  assign seqnum_out   = seqnum_out_w;
  assign engine_fsm   = u_engine.fsm;
  assign nop_fast_path = ENABLE_NOP_FAST_PATH;

endmodule : VX_cp_engine_top
