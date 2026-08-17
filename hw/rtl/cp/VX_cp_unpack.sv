// 版权 © 2019-2023
// 根据 Apache License, Version 2.0 授权许可。

`include "VX_define.vh"

// ============================================================================
// VX_cp_unpack — 单条命令解码器。
//
// 在 64 字节缓存行内的字节偏移 `offset` 处，精确解码一条打包好的 cmd_t 记录。
// 取指状态机（VX_cp_fetch）通过寄存 `offset`，并在每条命令发出后按 `cmd_size`
// 推进偏移量，逐条处理整行缓存行数据。每个周期解码一条命令；
// 偏移量累加只涉及一级寄存加法（约 4 级逻辑深度）。
//
// 每条命令在内存中的布局（小端序，字节对齐，不会跨缓存行边界）：
//   [hdr (4B)] [arg0 (8B)] [arg1 (8B)] [arg2 (8B)] [profile_slot (8B)]
//   其中 arg2 / profile_slot 仅对于需要它们的操作码才会存在
//   （具体见 VX_cp_pkg.sv 中的 cmd_size_bytes() 函数）。
//
// 当以下情况发生时，has_cmd 信号被拉低（表示行结束）：
//   - 剩余空间不足 4 字节头（offset + 4 > CL_BYTES），或
//   - 头全零（opcode==0 && flags==0）作为填充哨兵，或
//   - 操作码不是本 CP 能够识别的有效命令（无法判断其大小），或
//   - 命令会超出缓存行边界（offset + size > CL_BYTES）。
// ============================================================================

module VX_cp_unpack
  import VX_cp_pkg::*;
(
  input  wire  [CL_BITS-1:0]   cl_data,   // 输入的 64 字节缓存行数据
  input  wire  [OFF_W-1:0]     offset,    // 要解码的字节偏移量
  output logic                 has_cmd,   // 1 表示该偏移处有有效命令
  output cmd_t                 cmd,       // 解码出的命令结构体
  output logic [OFF_W-1:0]     cmd_size   // 该命令占用的字节数（用于推进偏移）
);

  // 偏移量/大小的位宽：范围 0 .. CL_BYTES（需要能表示 CL_BYTES 本身）。
  localparam int OFF_W = $clog2(CL_BYTES + 1);

  // 从紧凑的缓存行中按字节索引读取数据（通过动态位片选择实现）。
  // 在 sv2v/yosys 下综合干净，不会像动态索引的非打包数组那样产生问题。
  function automatic logic [7:0] cl_byte(input int idx);
    return cl_data[idx*8 +: 8];
  endfunction

  // 从偏移 `off` 处读取小端序的 64 位值。
  function automatic logic [63:0] read64(input int off);
    logic [63:0] v;
    v = '0;
    for (int i = 0; i < 8; ++i) begin
      if (off + i < CL_BYTES)
        v[i*8 +: 8] = cl_byte(off + i);
    end
    return v;
  endfunction

  // 从偏移 `off` 处读取 4 字节命令头。
  function automatic cmd_header_t read_hdr(input int off);
    cmd_header_t h;
    h = '0;
    if (off + 0 < CL_BYTES) h.opcode         = cl_byte(off + 0);
    if (off + 1 < CL_BYTES) h.flags          = cl_byte(off + 1);
    if (off + 2 < CL_BYTES) h.reserved[7:0]  = cl_byte(off + 2);
    if (off + 3 < CL_BYTES) h.reserved[15:8] = cl_byte(off + 3);
    return h;
  endfunction

  // ---- 组合逻辑解码 ----
  always_comb begin
    automatic int            off = int'(offset);
    automatic cmd_header_t   hdr;
    automatic cp_opcode_e    op;
    automatic logic          profiled;
    automatic int unsigned   sz;

    // 默认输出（无效状态）
    cmd      = '0;
    has_cmd  = 1'b0;
    cmd_size = '0;

    // 至少需要能容纳 4 字节的命令头
    if (off + 4 <= CL_BYTES) begin
      hdr      = read_hdr(off);
      op       = cp_opcode_e'(hdr.opcode);
      profiled = hdr.flags[F_PROFILE];

      // 如果头全零（填充字节）或操作码未知，则认为该行结束。
      // 未知操作码无法知道其大小，继续解析会把其负载字节误认为后续命令。
      if (!(hdr.opcode == 8'h00 && hdr.flags == 8'h00) && cmd_opcode_valid(op)) begin
        sz = cmd_size_bytes(op, profiled);
        // 如果命令会超出缓存行边界，则拒绝（属于格式错误的命令）
        if (off + int'(sz) <= CL_BYTES) begin
          cmd.hdr          = hdr;
          cmd.arg0         = read64(off + 4);
          cmd.arg1         = read64(off + 4 + 8);
          cmd.arg2         = read64(off + 4 + 16);
          cmd.profile_slot = profiled ? read64(off + int'(sz) - 8) : 64'd0;
          cmd_size         = OFF_W'(sz);
          has_cmd          = 1'b1;
        end
      end
    end
  end

endmodule : VX_cp_unpack
