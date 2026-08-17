
// 版权 © 2019-2023
// 根据 Apache License, Version 2.0 授权许可。

`include "VX_define.vh"

// ============================================================================
// VX_cp_engine — 每队列命令处理引擎（CPE）
//
// 从 `cmd_in` 接收解码后的命令流，将每条命令分类到三个共享资源之一
// （KMU / DMA / DCR），通过 engine_bid 接口向资源发起竞标（bid），
// 并在资源发出完成信号后退役该命令。
//
// FSM 状态机：
//   IDLE         : 无待处理命令；置 cmd_in_ready 为 1
//   DECODE       : 组合逻辑判断命令 opcode → 资源类型
//   BID          : 向选中的资源发起竞标
//   WAIT_DONE    : 保持竞标，直到资源发出完成信号
//   RETIRE       : 发出退役脉冲 + 推进 seqnum；返回 IDLE
//
// 支持的操作码：
//   - CMD_NOP / CMD_FENCE                          （立即退役）
//   - CMD_LAUNCH                                   （竞标 KMU）
//   - CMD_DCR_WRITE / CMD_DCR_READ / CMD_CACHE_FLUSH （竞标 DCR）
//   - CMD_MEM_*                                    （竞标 DMA）
//   - CMD_EVENT_SIGNAL / CMD_EVENT_WAIT            （竞标 EVENT）
// ============================================================================

module VX_cp_engine
  import VX_cp_pkg::*;
#(
  parameter int QID = 0
)(
  input  wire clk,
  input  wire reset,

  // 队列优先级（来自寄存器文件 q_state 的一个字段），用于标记仲裁器的竞标。
  // 引擎本身不需要队列状态中的其他信息。
  input  wire [1:0]               prio_in,
  // 退役序号遥测输出，回传给寄存器文件的 Q_SEQNUM。
  // 这是一个裸标量（不是 cpe_state_t 直通），原因见下方 seqnum_out 的驱动逻辑。
  output wire [63:0]              seqnum_out,

  // 解码后的命令流输入（由 VX_cp_fetch + VX_cp_unpack 驱动）。
  input  wire                     cmd_in_valid,
  input  cmd_t                    cmd_in,
  output logic                    cmd_in_ready,

  // 指向四个资源仲裁器的竞标线。
  VX_cp_engine_bid_if.bidder      bid_kmu,
  VX_cp_engine_bid_if.bidder      bid_dma,
  VX_cp_engine_bid_if.bidder      bid_dcr,
  VX_cp_engine_bid_if.bidder      bid_event,

  // 各资源的完成信号。这些信号来自资源模块（launch/dma/dcr_proxy/event_unit），
  // 在资源完成当前命令时脉冲高一个周期。
  // 引擎在 S_WAIT_DONE 状态下消费这些信号，以判断何时可以退役。
  input  wire                     kmu_done_i,
  input  wire                     dma_done_i,
  input  wire                     dcr_done_i,
  input  wire                     event_done_i,

  // 退役信号给 VX_cp_completion。`retire_evt` 在 S_RETIRE 状态下保持高，
  // 直到观察到 `retire_ready_i` — 这是 valid/ready 握手机制，确保完成模块
  // 不会在周期冲突时丢失 seqnum（详见 VX_cp_completion 的每源锁存器）。
  output logic                    retire_evt,
  output logic [63:0]             retire_seqnum,
  input  wire                     retire_ready_i,

  // 性能采样脉冲（由事件单元消费）。
  output logic                    submit_evt,
  output logic                    start_evt,
  output logic                    end_evt,
  output logic [63:0]             profile_slot
);

  typedef enum logic [2:0] {
    S_IDLE,
    S_DECODE,
    S_BID,
    S_WAIT_DONE,
    S_RETIRE
  } state_e;

  state_e       fsm;
  cmd_t         cur_cmd;
  cp_resource_e cur_res;
  logic         no_resource;        // 对于绕过仲裁器的操作码为真（NOP, FENCE, EVENT_*）
  logic [63:0]  seqnum_r;

  // -------------------------------------------------------------------------
  // 操作码 → 资源分类（基于 cur_cmd 的组合逻辑）。
  // -------------------------------------------------------------------------
  function automatic cp_resource_e classify(cp_opcode_e op,
                                            output logic skip);
    skip = 1'b0;
    case (op)
      CMD_LAUNCH:                    return RES_KMU;
      CMD_DCR_WRITE, CMD_DCR_READ,
      CMD_CACHE_FLUSH:               return RES_DCR;
      CMD_MEM_WRITE,
      CMD_MEM_READ,
      CMD_MEM_COPY:                  return RES_DMA;
      CMD_EVENT_SIGNAL,
      CMD_EVENT_WAIT:                return RES_EVT;
      default: begin
        skip = 1'b1;
        return RES_KMU;   // 当 skip=1 时此返回值不被使用
      end
    endcase
  endfunction

  // 完成信号（kmu_done_i / dma_done_i / dcr_done_i）由共享资源模块广播到每个 CPE。
  // 仲裁器每次只授权一个 CPE 访问某个资源，且资源一次只处理一条命令，
  // 因此当匹配的完成信号到达时，只有处于 S_WAIT_DONE 状态且已被授权的 CPE
  // 会响应它；未被授权的 CPE 会忽略它。

  // -------------------------------------------------------------------------
  // 状态机（FSM）
  // -------------------------------------------------------------------------

  always_ff @(posedge clk) begin
    automatic cp_resource_e res;
    automatic logic         skip_flag;
    if (reset) begin
      fsm         <= S_IDLE;
      cur_cmd     <= '0;
      cur_res     <= RES_KMU;
      no_resource <= 1'b0;
      seqnum_r    <= '0;
    end else begin
      case (fsm)
        S_IDLE: begin
          if (cmd_in_valid) begin
            cur_cmd <= cmd_in;
            fsm     <= S_DECODE;
          end
        end
        S_DECODE: begin
          res         = classify(cp_opcode_e'(cur_cmd.hdr.opcode), skip_flag);
          cur_res     <= res;
          no_resource <= skip_flag;
          if (skip_flag) begin
            fsm <= S_RETIRE;
          end else begin
            fsm <= S_BID;
          end
        end
        S_BID: begin
          // 等待本引擎获得仲裁授权。
          case (cur_res)
            RES_KMU:   if (bid_kmu.grant)   fsm <= S_WAIT_DONE;
            RES_DMA:   if (bid_dma.grant)   fsm <= S_WAIT_DONE;
            RES_DCR:   if (bid_dcr.grant)   fsm <= S_WAIT_DONE;
            RES_EVT: if (bid_event.grant) fsm <= S_WAIT_DONE;
            default:                        fsm <= S_RETIRE;
          endcase
        end
        S_WAIT_DONE: begin
          // 等待资源发出实际的完成信号后再退役。
          case (cur_res)
            RES_KMU:   if (kmu_done_i)   fsm <= S_RETIRE;
            RES_DMA:   if (dma_done_i)   fsm <= S_RETIRE;
            RES_DCR:   if (dcr_done_i)   fsm <= S_RETIRE;
            RES_EVT: if (event_done_i) fsm <= S_RETIRE;
            default:                     fsm <= S_RETIRE;
          endcase
        end
        S_RETIRE: begin
          // 保持 S_RETIRE（以及 retire_evt），直到完成模块接受该退役请求。
          // seqnum_r 仅在移出该状态的那个周期递增，因此 retire_seqnum
          // 会一直向锁存器提供相同的值。
          if (retire_ready_i) begin
            seqnum_r <= seqnum_r + 64'd1;
            fsm      <= S_IDLE;
          end
        end
        default: fsm <= S_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // 输出驱动
  // -------------------------------------------------------------------------

  always_comb begin
    cmd_in_ready = (fsm == S_IDLE);

    // 一次只竞标一个资源。
    bid_kmu.valid     = (fsm == S_BID) && (cur_res == RES_KMU);
    bid_kmu.priority_ = prio_in;
    bid_kmu.cmd       = cur_cmd;

    bid_dma.valid     = (fsm == S_BID) && (cur_res == RES_DMA);
    bid_dma.priority_ = prio_in;
    bid_dma.cmd       = cur_cmd;

    bid_dcr.valid     = (fsm == S_BID) && (cur_res == RES_DCR);
    bid_dcr.priority_ = prio_in;
    bid_dcr.cmd       = cur_cmd;

    bid_event.valid     = (fsm == S_BID) && (cur_res == RES_EVT);
    bid_event.priority_ = prio_in;
    bid_event.cmd       = cur_cmd;

    retire_evt    = (fsm == S_RETIRE);
    retire_seqnum = seqnum_r;

    submit_evt   = (fsm == S_DECODE) && cur_cmd.hdr.flags[F_PROFILE];
    // end_evt 与退役握手的触发周期对齐（每条命令一个脉冲），
    // 而不是与多周期的 S_RETIRE 状态对齐，这样性能分析单元
    // 能对每条退役的命令恰好计数一次。
    end_evt      = (fsm == S_RETIRE) && retire_ready_i
                                     && cur_cmd.hdr.flags[F_PROFILE];
    profile_slot = cur_cmd.profile_slot;
  end

  // start_evt 读取仲裁器的授权线。如果把它放在上面的 always_comb 块中，
  // 该块既会读取 `grant` 又会驱动 `bid_*.valid`；按块进行依赖分析时，
  // 会看到一条假循环（valid -> 仲裁器 -> grant -> 块 -> valid），
  // 并在无法拆分该块时报告 UNOPTFLAT（例如在 -O0 优化级别下）。
  // 用独立的连续赋值语句可以在所有优化级别下打破这个表观循环。
  assign start_evt = (fsm == S_BID) && cur_cmd.hdr.flags[F_PROFILE] &&
                     ((cur_res == RES_KMU && bid_kmu.grant)   ||
                      (cur_res == RES_DMA && bid_dma.grant)   ||
                      (cur_res == RES_DCR && bid_dcr.grant)   ||
                      (cur_res == RES_EVT && bid_event.grant));

  // 引擎对队列状态唯一的贡献是退役序号。
  // 将其作为裸寄存器读出（而不是从 state_in 构建 cpe_state_t）
  // 可以防止按块分析将输出视为依赖于输入：
  // 如果做结构体直通，会通过寄存器文件形成假组合环
  // q_seqnum -> q_state -> state_in -> state_out -> q_seqnum。
  // seqnum_r 是寄存器，因此该路径本质上是无环的。
  assign seqnum_out = seqnum_r;

  `UNUSED_VAR (QID)
  `UNUSED_VAR (no_resource)

endmodule : VX_cp_engine
