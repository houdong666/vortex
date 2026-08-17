// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


// cp_opcode_e（命令类型） 写在 cmd_header_t（头） 里，
//cmd_header_t（头） 加上 arg0~arg2（参数） 打包成 cmd_t（完整命令）。
// CP 根据 cpe_state_t（引擎状态）从 Ring 里取出 cmd_t，解析出 opcode，映射成 cp_resource_e（目标资源），派发给下游硬件执行。
// 这几样东西合在一起，就是 CP 处理一条命令的完整数据流闭环。



`ifndef VX_CP_PKG_VH
`define VX_CP_PKG_VH

`include "VX_define.vh"

`IGNORE_UNUSED_BEGIN

package VX_cp_pkg;

  // ------------------------------------------------------------------------
  // 编译期参数，来源于 VX_config.toml 或构建标志。
  // 这些参数设有安全默认值，使得即使 VX_config.toml 中没有 [cp] 块，
  // rtl/cp 目录也能独立编译。当存在 [cp] 块时，configure 脚本会
  // 通过 -D 宏覆盖这些默认值。
  // ------------------------------------------------------------------------


  `ifndef VX_CP_NUM_QUEUES
    `define VX_CP_NUM_QUEUES 1
  `endif

  `ifndef VX_CP_RING_SIZE_LOG2
    `define VX_CP_RING_SIZE_LOG2 16   // 64 KiB per queue ring
    // 每个队列环（ring）的大小为 64KiB
  `endif

  `ifndef VX_CP_MAX_CMDS_PER_CL
    `define VX_CP_MAX_CMDS_PER_CL 5
  `endif

  `ifndef VX_CP_AXI_TID_WIDTH
    `define VX_CP_AXI_TID_WIDTH 6
  `endif

  // 将宏定义转为本地常量，方便 RTL 使用
  localparam int VX_CP_NUM_QUEUES_C      = `VX_CP_NUM_QUEUES;
  localparam int VX_CP_RING_SIZE_LOG2_C  = `VX_CP_RING_SIZE_LOG2;
  localparam int VX_CP_MAX_CMDS_PER_CL_C = `VX_CP_MAX_CMDS_PER_CL;
  localparam int VX_CP_AXI_TID_WIDTH_C   = `VX_CP_AXI_TID_WIDTH;

  // ------------------------------------------------------------------------
  // 缓存行几何参数，与 Vortex 其他部分定义的 CACHE_BLOCK_SIZE 一致。
  // ------------------------------------------------------------------------

  localparam int CL_BYTES = 64;
  localparam int CL_BITS  = CL_BYTES * 8;

  // ------------------------------------------------------------------------
  // 命令操作码枚举。
  // ------------------------------------------------------------------------

  typedef enum logic [7:0] {
    CMD_NOP          = 8'h00, // 空操作
    CMD_MEM_WRITE    = 8'h01, // 内存写
    CMD_MEM_READ     = 8'h02, // 内存读
    CMD_MEM_COPY     = 8'h03, // 内存拷贝
    CMD_DCR_WRITE    = 8'h04, // 设备控制寄存器（DCR）写
    CMD_DCR_READ     = 8'h05, // DCR 读
    CMD_LAUNCH       = 8'h06, // 启动内核
    CMD_FENCE        = 8'h07, // 屏障（栅栏）操作
    CMD_EVENT_SIGNAL = 8'h08, // 事件信号触发
    CMD_EVENT_WAIT   = 8'h09, // 事件等待
    CMD_CACHE_FLUSH  = 8'h0A  // 缓存刷新
  } cp_opcode_e;

  // ------------------------------------------------------------------------
  // 命令头中的标志位定义。
  // ------------------------------------------------------------------------

  localparam int F_PROFILE   = 0; // 启用性能分析（profile），在命令末尾附加 8 字节的时间戳槽
  localparam int F_FENCE_PRE = 1; // 执行命令前先完成之前的 fence（前栅栏）

  // 命令头结构：保留字段、标志位、操作码
  typedef struct packed {
    logic [15:0] reserved;
    logic [7:0]  flags;
    logic [7:0]  opcode;
  } cmd_header_t;

  // ------------------------------------------------------------------------
  // 由 VX_cp_unpack 模块产生的解码后的命令记录。
  // 最大负载为 28 字节（用于 CMD_MEM_*、CMD_EVENT_WAIT、CMD_DCR_READ）；
  // 若启用 F_PROFILE，则在末尾附加 8 字节的 profile_slot。
  typedef struct packed {
    cmd_header_t hdr;            // 命令头
    logic [63:0] arg0;           // 参数 0
    logic [63:0] arg1;           // 参数 1
    logic [63:0] arg2;           // 参数 2
    logic [63:0] profile_slot;   // 性能分析数据槽，有效当且仅当 hdr.flags[F_PROFILE] 为 1
  } cmd_t;

  // ------------------------------------------------------------------------
  // EVENT_WAIT 命令的比较操作类型，编码在 arg2 的低 2 位。
  // ------------------------------------------------------------------------

  typedef enum logic [1:0] {
    WAIT_OP_EQ = 2'd0, // 等于
    WAIT_OP_GE = 2'd1, // 大于等于
    WAIT_OP_GT = 2'd2, // 大于
    WAIT_OP_NE = 2'd3  // 不等于
  } wait_op_e;

  // ------------------------------------------------------------------------
  // FENCE 命令的掩码位，编码在 arg0 的低 2 位。
  // ------------------------------------------------------------------------

  localparam int FENCE_DMA_BIT = 0; // 表示等待 DMA 完成
  localparam int FENCE_GPU_BIT = 1; // 表示等待 GPU 执行完成

  // ------------------------------------------------------------------------
  // 每个命令处理引擎（CPE）的持久状态。
  // 每个 VX_cp_engine 内部维护一份该状态。AXI-Lite 从设备中的主机可见寄存器会写入这些字段。
  // ------------------------------------------------------------------------

  typedef struct packed {
    logic [63:0]                       ring_base;        // host IO addr of ring
                                                        // 主机 IO 地址，指向命令环的基址
    logic [VX_CP_RING_SIZE_LOG2_C-1:0] ring_size_mask;   // size_bytes - 1
                                                        // 环大小掩码（size_bytes - 1）
    logic [63:0]                       head_addr;        // CP publishes head here
                                                        // CP 将 head 指针写入此地址（主机可见）
    logic [63:0]                       cmpl_addr;        // CP publishes seqnum here
                                                        // CP 将完成序号（seqnum）写入此地址（主机可见）
    logic [63:0]                       tail;             // last committed via doorbell
                                                        // 最近一次通过门铃（doorbell）提交的 tail 值
    logic [63:0]                       head;             // CPE consumer pointer
                                                        // CPE 内部的消费者指针（head）
    logic [63:0]                       seqnum;           // next-to-retire seqnum
                                                        // 下一个将要退役的命令序号
    logic [1:0]                        prio;             // 0=lo, 3=hi
                                                        // 队列优先级（0 低，3 高）
    logic                              enabled;          // 队列是否使能
    logic                              profile_en;       // 是否启用性能分析
  } cpe_state_t;

  // ------------------------------------------------------------------------
  // 每个资源仲裁器的请求类型（从 CPE 到仲裁器）。
  // 每个 CPE 有三条这样的请求线（分别对应 KMU、DMA、DCR）。
  // ------------------------------------------------------------------------

  typedef enum logic [1:0] {
    RES_KMU = 2'd0, // 内核管理单元（负责启动 Kernel）
    RES_DMA = 2'd1, // 直接内存访问（负责内存传输）
    RES_DCR = 2'd2, // 设备控制寄存器（负责 DCR 读写）
    RES_EVT = 2'd3  // 事件处理（负责 CMD_EVENT_SIGNAL 和 CMD_EVENT_WAIT）
  } cp_resource_e;

  // ------------------------------------------------------------------------
  // 辅助函数
  // 判断某个操作码是否为 CP 能够识别的有效命令。
  // VX_cp_unpack 在遇到未知操作码时会丢弃当前缓存行剩余数据，
  // 因为无法得知其大小，继续解析会将负载字节误解析为伪命令。
  // ------------------------------------------------------------------------

  function automatic logic cmd_opcode_valid(cp_opcode_e op);
    case (op)
      CMD_NOP,
      CMD_MEM_WRITE,
      CMD_MEM_READ,
      CMD_MEM_COPY,
      CMD_DCR_WRITE,
      CMD_DCR_READ,
      CMD_LAUNCH,
      CMD_FENCE,
      CMD_EVENT_SIGNAL,
      CMD_EVENT_WAIT,
      CMD_CACHE_FLUSH: return 1'b1;
      default:         return 1'b0;
    endcase
  endfunction

  // 根据操作码和 F_PROFILE 标志返回命令在内存中的字节大小。
  // 供 VX_cp_unpack 使用，以确定处理每条命令时应消耗多少缓存行数据。
  function automatic int unsigned cmd_size_bytes(cp_opcode_e op,
                                                 logic profiled);
    int unsigned base;
    case (op)
      CMD_NOP:          base = 4;   // 空操作：4 字节
      CMD_LAUNCH:       base = 12;  // 启动：12 字节（头 + 8 字节参数？实际根据定义）
      CMD_FENCE:        base = 8;   // 栅栏：8 字节
      CMD_CACHE_FLUSH:  base = 12;  // 缓存刷新：12 字节
      CMD_DCR_WRITE:    base = 20;  // DCR 写：20 字节
      CMD_DCR_READ:     base = 20;  // DCR 读：20 字节
      CMD_EVENT_SIGNAL: base = 20;  // 事件信号：20 字节
      CMD_EVENT_WAIT:   base = 28;  // 事件等待：28 字节
      CMD_MEM_WRITE:    base = 28;  // 内存写：28 字节
      CMD_MEM_READ:     base = 28;  // 内存读：28 字节
      CMD_MEM_COPY:     base = 28;  // 内存拷贝：28 字节
      default:          base = 4;   // 未知：4 字节（安全处理）
    endcase
    return base + (profiled ? 8 : 0); // 若有 profile，额外增加 8 字节
  endfunction

endpackage : VX_cp_pkg

`IGNORE_UNUSED_END

`endif // VX_CP_PKG_VH
