// removed package "VX_gpu_pkg"
// removed package "VX_trace_pkg"
// removed interface: VX_mem_axi_if
// removed package "VX_cp_pkg"
module VX_cp_unpack (
	cl_data,
	offset,
	has_cmd,
	cmd,
	cmd_size
);
	reg _sv2v_0;
	// removed import VX_cp_pkg::*;
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:29:3
	localparam signed [31:0] VX_cp_pkg_CL_BYTES = 64;
	localparam signed [31:0] VX_cp_pkg_CL_BITS = 512;
	input wire [511:0] cl_data;
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:30:3
	localparam signed [31:0] OFF_W = 7;
	input wire [6:0] offset;
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:31:3
	output reg has_cmd;
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:32:3
	// removed localparam type VX_cp_pkg_cmd_header_t
	// removed localparam type VX_cp_pkg_cmd_t
	output reg [287:0] cmd;
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:33:3
	output reg [6:0] cmd_size;
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:37:3
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:41:3
	function automatic [7:0] cl_byte;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:41:42
		input reg signed [31:0] idx;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:42:5
		cl_byte = cl_data[idx * 8+:8];
	endfunction
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:46:3
	function automatic [63:0] read64;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:46:42
		input reg signed [31:0] off;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:47:5
		reg [63:0] v;
		begin
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:48:5
			v = 1'sb0;
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:49:5
			begin : sv2v_autoblock_1
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:49:10
				reg signed [31:0] i;
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:49:10
				for (i = 0; i < 8; i = i + 1)
					begin
						// Trace: hw/rtl/cp/VX_cp_unpack.sv:50:7
						if ((off + i) < VX_cp_pkg_CL_BYTES)
							// Trace: hw/rtl/cp/VX_cp_unpack.sv:51:9
							v[i * 8+:8] = cl_byte(off + i);
					end
			end
			read64 = v;
		end
	endfunction
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:57:3
	function automatic [31:0] read_hdr;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:57:44
		input reg signed [31:0] off;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:58:5
		reg [31:0] h;
		begin
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:59:5
			h = 1'sb0;
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:60:5
			if ((off + 0) < VX_cp_pkg_CL_BYTES)
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:60:29
				h[7-:8] = cl_byte(off + 0);
			if ((off + 1) < VX_cp_pkg_CL_BYTES)
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:61:29
				h[15-:8] = cl_byte(off + 1);
			if ((off + 2) < VX_cp_pkg_CL_BYTES)
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:62:29
				h[23:16] = cl_byte(off + 2);
			if ((off + 3) < VX_cp_pkg_CL_BYTES)
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:63:29
				h[31:24] = cl_byte(off + 3);
			read_hdr = h;
		end
	endfunction
	// Trace: hw/rtl/cp/VX_cp_unpack.sv:68:3
	localparam signed [31:0] VX_cp_pkg_F_PROFILE = 0;
	// removed localparam type VX_cp_pkg_cp_opcode_e
	function automatic VX_cp_pkg_cmd_opcode_valid;
		// Trace: hw/rtl/cp/VX_cp_pkg.sv:176:45
		input reg [7:0] op;
		// Trace: hw/rtl/cp/VX_cp_pkg.sv:177:5
		case (op)
			8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07, 8'h08, 8'h09, 8'h0a: VX_cp_pkg_cmd_opcode_valid = 1'b1;
			default: VX_cp_pkg_cmd_opcode_valid = 1'b0;
		endcase
	endfunction
	function automatic [31:0] VX_cp_pkg_cmd_size_bytes;
		// Trace: hw/rtl/cp/VX_cp_pkg.sv:195:50
		input reg [7:0] op;
		// Trace: hw/rtl/cp/VX_cp_pkg.sv:196:50
		input reg profiled;
		// Trace: hw/rtl/cp/VX_cp_pkg.sv:197:5
		reg [31:0] base;
		begin
			// Trace: hw/rtl/cp/VX_cp_pkg.sv:198:5
			case (op)
				8'h00:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:199:25
					base = 4;
				8'h06:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:200:25
					base = 12;
				8'h07:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:201:25
					base = 8;
				8'h0a:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:202:25
					base = 12;
				8'h04:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:203:25
					base = 20;
				8'h05:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:204:25
					base = 20;
				8'h08:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:205:25
					base = 20;
				8'h09:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:206:25
					base = 28;
				8'h01:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:207:25
					base = 28;
				8'h02:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:208:25
					base = 28;
				8'h03:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:209:25
					base = 28;
				default:
					// Trace: hw/rtl/cp/VX_cp_pkg.sv:210:25
					base = 4;
			endcase
			VX_cp_pkg_cmd_size_bytes = base + (profiled ? 8 : 0);
		end
	endfunction
	function automatic [7:0] sv2v_cast_8;
		input reg [7:0] inp;
		sv2v_cast_8 = inp;
	endfunction
	function automatic [6:0] sv2v_cast_06687;
		input reg [6:0] inp;
		sv2v_cast_06687 = inp;
	endfunction
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(cl_data or cl_data or cl_data or cl_data or cl_data or cl_data or cl_data or cl_data or _sv2v_0 or offset) begin : sv2v_autoblock_2
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:69:5
		reg signed [31:0] off;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:70:5
		reg [31:0] hdr;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:71:5
		reg [7:0] op;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:72:5
		reg profiled;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:73:5
		reg [31:0] sz;
		off = sv2v_cast_32_signed(offset);
		if (_sv2v_0)
			;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:76:5
		cmd = 1'sb0;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:77:5
		has_cmd = 1'b0;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:78:5
		cmd_size = 1'sb0;
		// Trace: hw/rtl/cp/VX_cp_unpack.sv:81:5
		if ((off + 4) <= VX_cp_pkg_CL_BYTES) begin
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:82:7
			hdr = read_hdr(off);
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:83:7
			op = sv2v_cast_8(hdr[7-:8]);
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:84:7
			profiled = hdr[8];
			// Trace: hw/rtl/cp/VX_cp_unpack.sv:88:7
			if (!((hdr[7-:8] == 8'h00) && (hdr[15-:8] == 8'h00)) && VX_cp_pkg_cmd_opcode_valid(op)) begin
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:89:9
				sz = VX_cp_pkg_cmd_size_bytes(op, profiled);
				// Trace: hw/rtl/cp/VX_cp_unpack.sv:91:9
				if ((off + sv2v_cast_32_signed(sz)) <= VX_cp_pkg_CL_BYTES) begin
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:92:11
					cmd[287-:32] = hdr;
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:93:11
					cmd[255-:64] = read64(off + 4);
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:94:11
					cmd[191-:64] = read64(off + 12);
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:95:11
					cmd[127-:64] = read64(off + 20);
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:96:11
					cmd[63-:64] = (profiled ? read64((off + sv2v_cast_32_signed(sz)) - 8) : 64'd0);
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:97:11
					cmd_size = sv2v_cast_06687(sz);
					// Trace: hw/rtl/cp/VX_cp_unpack.sv:98:11
					has_cmd = 1'b1;
				end
			end
		end
	end
	initial _sv2v_0 = 0;
endmodule
// removed module with interface ports: VX_cp_fetch
module VX_cp_fetch_top (
	clk,
	reset,
	state_in_packed,
	head_out,
	cmd_out_valid,
	cmd_out_packed,
	cmd_out_ready,
	m_arvalid,
	m_arready,
	m_araddr,
	m_arid,
	m_arlen,
	m_arsize,
	m_arburst,
	m_rvalid,
	m_rready,
	m_rdata,
	m_rid,
	m_rlast,
	m_rresp
);
	// removed import VX_cp_pkg::*;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:10:13
	parameter signed [31:0] ADDR_W = 64;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:11:13
	parameter signed [31:0] DATA_W = 512;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:12:13
	localparam signed [31:0] VX_cp_pkg_VX_CP_AXI_TID_WIDTH_C = 6;
	parameter signed [31:0] ID_W = VX_cp_pkg_VX_CP_AXI_TID_WIDTH_C;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:13:13
	parameter signed [31:0] PREFETCH_DEPTH = 2;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:15:3
	input wire clk;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:16:3
	input wire reset;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:17:3
	localparam signed [31:0] VX_cp_pkg_VX_CP_RING_SIZE_LOG2_C = 16;
	// removed localparam type VX_cp_pkg_cpe_state_t
	input wire [403:0] state_in_packed;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:18:3
	output wire [63:0] head_out;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:19:3
	output wire cmd_out_valid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:20:3
	// removed localparam type VX_cp_pkg_cmd_header_t
	// removed localparam type VX_cp_pkg_cmd_t
	output wire [287:0] cmd_out_packed;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:21:3
	input wire cmd_out_ready;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:22:3
	output wire m_arvalid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:23:3
	input wire m_arready;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:24:3
	output wire [ADDR_W - 1:0] m_araddr;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:25:3
	output wire [ID_W - 1:0] m_arid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:26:3
	output wire [7:0] m_arlen;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:27:3
	output wire [2:0] m_arsize;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:28:3
	output wire [1:0] m_arburst;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:29:3
	input wire m_rvalid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:30:3
	output wire m_rready;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:31:3
	input wire [DATA_W - 1:0] m_rdata;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:32:3
	input wire [ID_W - 1:0] m_rid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:33:3
	input wire m_rlast;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:34:3
	input wire [1:0] m_rresp;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:37:3
	// expanded interface instance: axi_if
	localparam _param_923E6_ADDR_W = ADDR_W;
	localparam _param_923E6_DATA_W = DATA_W;
	localparam _param_923E6_ID_W = ID_W;
	generate
		if (1) begin : axi_if
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:22:13
			localparam signed [31:0] ADDR_W = _param_923E6_ADDR_W;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:23:13
			localparam signed [31:0] DATA_W = _param_923E6_DATA_W;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:24:13
			localparam signed [31:0] ID_W = _param_923E6_ID_W;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:28:3
			reg awvalid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:29:3
			wire awready;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:30:3
			reg [ADDR_W - 1:0] awaddr;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:31:3
			reg [ID_W - 1:0] awid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:32:3
			reg [7:0] awlen;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:33:3
			reg [2:0] awsize;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:34:3
			reg [1:0] awburst;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:37:3
			reg wvalid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:38:3
			wire wready;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:39:3
			reg [DATA_W - 1:0] wdata;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:40:3
			reg [(DATA_W / 8) - 1:0] wstrb;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:41:3
			reg wlast;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:44:3
			wire bvalid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:45:3
			reg bready;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:46:3
			wire [ID_W - 1:0] bid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:47:3
			wire [1:0] bresp;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:50:3
			reg arvalid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:51:3
			wire arready;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:52:3
			reg [ADDR_W - 1:0] araddr;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:53:3
			reg [ID_W - 1:0] arid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:54:3
			reg [7:0] arlen;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:55:3
			reg [2:0] arsize;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:56:3
			reg [1:0] arburst;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:59:3
			wire rvalid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:60:3
			reg rready;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:61:3
			wire [DATA_W - 1:0] rdata;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:62:3
			wire [ID_W - 1:0] rid;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:63:3
			wire rlast;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:64:3
			wire [1:0] rresp;
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:67:3
			// Trace: hw/rtl/mem/VX_mem_axi_if.sv:85:3
		end
	endgenerate
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:38:3
	wire [403:0] state_typed;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:39:3
	wire [287:0] cmd_typed;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:41:3
	function automatic [403:0] sv2v_cast_842CE;
		input reg [403:0] inp;
		sv2v_cast_842CE = inp;
	endfunction
	assign state_typed = sv2v_cast_842CE(state_in_packed);
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:42:3
	assign cmd_out_packed = cmd_typed;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:43:3
	assign m_arvalid = axi_if.arvalid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:44:3
	assign axi_if.arready = m_arready;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:45:3
	assign m_araddr = axi_if.araddr;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:46:3
	assign m_arid = axi_if.arid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:47:3
	assign m_arlen = axi_if.arlen;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:48:3
	assign m_arsize = axi_if.arsize;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:49:3
	assign m_arburst = axi_if.arburst;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:50:3
	assign axi_if.rvalid = m_rvalid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:51:3
	assign m_rready = axi_if.rready;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:52:3
	assign axi_if.rdata = m_rdata;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:53:3
	assign axi_if.rid = m_rid;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:54:3
	assign axi_if.rlast = m_rlast;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:55:3
	assign axi_if.rresp = m_rresp;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:57:3
	assign axi_if.awready = 1'b0;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:58:3
	assign axi_if.wready = 1'b0;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:59:3
	assign axi_if.bvalid = 1'b0;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:60:3
	assign axi_if.bid = 1'sb0;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:61:3
	assign axi_if.bresp = 1'sb0;
	// Trace: hw/unittest/cp_axi_path/VX_cp_fetch_top.sv:63:3
	// expanded module instance: u_fetch
	localparam _param_573CD_QID = 0;
	localparam _param_573CD_PREFETCH_DEPTH = PREFETCH_DEPTH;
	generate
		if (1) begin : u_fetch
			reg _sv2v_0;
			// removed import VX_cp_pkg::*;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:28:13
			localparam signed [31:0] QID = _param_573CD_QID;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:29:13
			localparam signed [31:0] VX_cp_pkg_VX_CP_AXI_TID_WIDTH_C = 6;
			localparam signed [31:0] ID_W = VX_cp_pkg_VX_CP_AXI_TID_WIDTH_C;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:30:13
			localparam signed [31:0] PREFETCH_DEPTH = _param_573CD_PREFETCH_DEPTH;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:33:13
			localparam [5:0] TID_PREFIX = 1'sb0;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:35:3
			wire clk;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:36:3
			wire reset;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:39:3
			localparam signed [31:0] VX_cp_pkg_VX_CP_RING_SIZE_LOG2_C = 16;
			// removed localparam type VX_cp_pkg_cpe_state_t
			wire [403:0] state_in;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:42:3
			wire [63:0] head_out;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:45:3
			reg cmd_out_valid;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:46:3
			// removed localparam type VX_cp_pkg_cmd_header_t
			// removed localparam type VX_cp_pkg_cmd_t
			reg [287:0] cmd_out;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:47:3
			wire cmd_out_ready;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:50:3
			// removed modport instance axi_m
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:54:3
			reg [63:0] head_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:55:3
			reg [63:0] fetch_head_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:56:3
			assign head_out = head_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:60:3
			localparam signed [31:0] FIFO_PTR_W = (PREFETCH_DEPTH > 1 ? $clog2(PREFETCH_DEPTH) : 1);
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:61:3
			localparam signed [31:0] FIFO_CNT_W = $clog2(PREFETCH_DEPTH + 1);
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:64:3
			localparam [FIFO_PTR_W - 1:0] FIFO_LAST_PTR = PREFETCH_DEPTH - 1;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:66:3
			localparam [FIFO_CNT_W - 1:0] FIFO_DEPTH_COUNT = PREFETCH_DEPTH;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:68:3
			localparam [FIFO_CNT_W:0] FIFO_DEPTH_ALLOC = PREFETCH_DEPTH;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:71:3
			localparam signed [31:0] VX_cp_pkg_CL_BYTES = 64;
			localparam signed [31:0] VX_cp_pkg_CL_BITS = 512;
			reg [511:0] cl_fifo [0:PREFETCH_DEPTH - 1];
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:72:3
			reg [FIFO_PTR_W - 1:0] read_ptr_r;
			reg [FIFO_PTR_W - 1:0] write_ptr_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:73:3
			reg [FIFO_CNT_W - 1:0] fifo_count_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:74:3
			reg [FIFO_CNT_W - 1:0] request_count_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:76:3
			wire fifo_empty = fifo_count_r == 0;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:77:3
			wire fifo_full = fifo_count_r == FIFO_DEPTH_COUNT;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:78:3
			wire [511:0] cl_data_r = cl_fifo[read_ptr_r];
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:81:3
			localparam signed [31:0] OFF_W = 7;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:82:3
			reg [6:0] offset_r;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:83:3
			wire [287:0] cmd_w;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:84:3
			wire has_cmd_w;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:85:3
			wire [6:0] cmd_size_w;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:89:3
			VX_cp_unpack u_unpack(
				.cl_data(cl_data_r),
				.offset(offset_r),
				.has_cmd(has_cmd_w),
				.cmd(cmd_w),
				.cmd_size(cmd_size_w)
			);
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:97:3
			// removed localparam type state_e
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:98:3
			reg [1:0] state;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:100:3
			wire [63:0] fetch_ring_offset = fetch_head_r & {48'd0, state_in[339-:16]};
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:102:3
			wire [FIFO_CNT_W:0] allocated_lines = {1'b0, fifo_count_r} + {1'b0, request_count_r};
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:104:3
			wire can_issue = (state_in[1] && (fetch_head_r < state_in[195-:64])) && (allocated_lines < FIFO_DEPTH_ALLOC);
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:107:3
			wire push_line = axi_if.rvalid && axi_if.rready;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:108:3
			wire pop_line = !fifo_empty && !has_cmd_w;
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:111:3
			always @(*) begin
				if (_sv2v_0)
					;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:112:5
				if (!fifo_empty)
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:113:7
					state = 2'd3;
				else if (request_count_r != 0)
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:115:7
					state = 2'd2;
				else if (can_issue)
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:117:7
					state = 2'd1;
				else
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:119:7
					state = 2'd0;
			end
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:122:3
			always @(posedge clk)
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:123:5
				if (reset) begin
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:124:7
					head_r <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:125:7
					fetch_head_r <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:126:7
					read_ptr_r <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:127:7
					write_ptr_r <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:128:7
					fifo_count_r <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:129:7
					request_count_r <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:130:7
					offset_r <= 1'sb0;
				end
				else begin
					// Trace: hw/rtl/cp/VX_cp_fetch.sv:132:7
					if (axi_if.arvalid && axi_if.arready)
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:133:9
						fetch_head_r <= fetch_head_r + 64'd64;
					if (push_line) begin
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:137:9
						cl_fifo[write_ptr_r] <= axi_if.rdata;
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:138:9
						write_ptr_r <= (write_ptr_r == FIFO_LAST_PTR ? {FIFO_PTR_W {1'sb0}} : write_ptr_r + 1'b1);
					end
					case ({axi_if.arvalid && axi_if.arready, push_line})
						2'b10:
							// Trace: hw/rtl/cp/VX_cp_fetch.sv:143:16
							request_count_r <= request_count_r + 1'b1;
						2'b01:
							// Trace: hw/rtl/cp/VX_cp_fetch.sv:144:16
							request_count_r <= request_count_r - 1'b1;
						default:
							// Trace: hw/rtl/cp/VX_cp_fetch.sv:145:18
							request_count_r <= request_count_r;
					endcase
					if (pop_line) begin
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:149:9
						read_ptr_r <= (read_ptr_r == FIFO_LAST_PTR ? {FIFO_PTR_W {1'sb0}} : read_ptr_r + 1'b1);
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:151:9
						head_r <= head_r + 64'd64;
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:152:9
						offset_r <= 1'sb0;
					end
					else if (!fifo_empty && cmd_out_ready)
						// Trace: hw/rtl/cp/VX_cp_fetch.sv:154:9
						offset_r <= offset_r + cmd_size_w;
					case ({push_line, pop_line})
						2'b10:
							// Trace: hw/rtl/cp/VX_cp_fetch.sv:158:16
							fifo_count_r <= fifo_count_r + 1'b1;
						2'b01:
							// Trace: hw/rtl/cp/VX_cp_fetch.sv:159:16
							fifo_count_r <= fifo_count_r - 1'b1;
						default:
							// Trace: hw/rtl/cp/VX_cp_fetch.sv:160:18
							fifo_count_r <= fifo_count_r;
					endcase
				end
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:166:3
			always @(*) begin
				if (_sv2v_0)
					;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:168:5
				axi_if.awvalid = 1'b0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:169:5
				axi_if.awaddr = 1'sb0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:170:5
				axi_if.awid = 1'sb0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:171:5
				axi_if.awlen = 1'sb0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:172:5
				axi_if.awsize = 1'sb0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:173:5
				axi_if.awburst = 2'b01;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:174:5
				axi_if.wvalid = 1'b0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:175:5
				axi_if.wdata = 1'sb0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:176:5
				axi_if.wstrb = 1'sb0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:177:5
				axi_if.wlast = 1'b0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:178:5
				axi_if.bready = 1'b1;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:179:5
				axi_if.rready = (request_count_r != 0) && !fifo_full;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:182:5
				axi_if.arvalid = can_issue;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:183:5
				axi_if.araddr = state_in[403-:64] + fetch_ring_offset;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:184:5
				axi_if.arid = TID_PREFIX;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:185:5
				axi_if.arlen = 8'd0;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:186:5
				axi_if.arsize = 3'd6;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:187:5
				axi_if.arburst = 2'b01;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:190:5
				cmd_out_valid = !fifo_empty && has_cmd_w;
				// Trace: hw/rtl/cp/VX_cp_fetch.sv:191:5
				cmd_out = cmd_w;
			end
			// Trace: hw/rtl/cp/VX_cp_fetch.sv:211:3
			initial _sv2v_0 = 0;
		end
	endgenerate
	assign u_fetch.clk = clk;
	assign u_fetch.reset = reset;
	assign u_fetch.state_in = state_typed;
	assign head_out = u_fetch.head_out;
	assign cmd_out_valid = u_fetch.cmd_out_valid;
	assign cmd_typed = u_fetch.cmd_out;
	assign u_fetch.cmd_out_ready = cmd_out_ready;
endmodule
