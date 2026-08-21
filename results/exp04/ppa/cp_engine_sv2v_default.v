// removed package "VX_cp_pkg"
// removed interface: VX_cp_engine_bid_if
// removed module with interface ports: VX_cp_engine
module VX_cp_engine_top (
	clk,
	reset,
	state_prio,
	cmd_in_valid,
	cmd_in_packed,
	cmd_in_ready,
	bid_kmu_valid,
	bid_kmu_prio,
	bid_kmu_cmd,
	bid_kmu_grant,
	bid_dma_valid,
	bid_dma_prio,
	bid_dma_cmd,
	bid_dma_grant,
	bid_dcr_valid,
	bid_dcr_prio,
	bid_dcr_cmd,
	bid_dcr_grant,
	bid_event_valid,
	bid_event_prio,
	bid_event_cmd,
	bid_event_grant,
	kmu_done_i,
	dma_done_i,
	dcr_done_i,
	event_done_i,
	retire_evt,
	retire_seqnum,
	seqnum_out,
	engine_fsm,
	nop_fast_path,
	submit_evt,
	start_evt,
	end_evt,
	profile_slot
);
	// removed import VX_cp_pkg::*;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:23:13
	parameter [0:0] ENABLE_NOP_FAST_PATH = 1'b1;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:26:3
	input wire clk;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:27:3
	input wire reset;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:30:3
	input wire [1:0] state_prio;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:33:3
	input wire cmd_in_valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:34:3
	// removed localparam type VX_cp_pkg_cmd_header_t
	// removed localparam type VX_cp_pkg_cmd_t
	input wire [287:0] cmd_in_packed;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:35:3
	output wire cmd_in_ready;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:38:3
	output wire bid_kmu_valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:39:3
	output wire [1:0] bid_kmu_prio;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:40:3
	output wire [287:0] bid_kmu_cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:41:3
	input wire bid_kmu_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:43:3
	output wire bid_dma_valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:44:3
	output wire [1:0] bid_dma_prio;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:45:3
	output wire [287:0] bid_dma_cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:46:3
	input wire bid_dma_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:48:3
	output wire bid_dcr_valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:49:3
	output wire [1:0] bid_dcr_prio;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:50:3
	output wire [287:0] bid_dcr_cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:51:3
	input wire bid_dcr_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:53:3
	output wire bid_event_valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:54:3
	output wire [1:0] bid_event_prio;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:55:3
	output wire [287:0] bid_event_cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:56:3
	input wire bid_event_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:62:3
	input wire kmu_done_i;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:63:3
	input wire dma_done_i;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:64:3
	input wire dcr_done_i;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:65:3
	input wire event_done_i;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:68:3
	output wire retire_evt;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:69:3
	output wire [63:0] retire_seqnum;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:70:3
	output wire [63:0] seqnum_out;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:71:3
	output wire [2:0] engine_fsm;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:72:3
	output wire nop_fast_path;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:75:3
	output wire submit_evt;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:76:3
	output wire start_evt;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:77:3
	output wire end_evt;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:78:3
	output wire [63:0] profile_slot;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:82:3
	wire [287:0] cmd_in_typed;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:83:3
	assign cmd_in_typed = cmd_in_packed;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:86:3
	wire [63:0] seqnum_out_w;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:89:3
	// expanded interface instance: bid_kmu_if
	generate
		if (1) begin : bid_kmu_if
			// removed import VX_cp_pkg::*;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:26:3
			reg valid;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:27:3
			reg [1:0] priority_;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:28:3
			// removed localparam type VX_cp_pkg_cmd_header_t
			// removed localparam type VX_cp_pkg_cmd_t
			reg [287:0] cmd;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:29:3
			wire grant;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:31:3
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:36:3
		end
	endgenerate
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:90:3
	// expanded interface instance: bid_dma_if
	generate
		if (1) begin : bid_dma_if
			// removed import VX_cp_pkg::*;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:26:3
			reg valid;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:27:3
			reg [1:0] priority_;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:28:3
			// removed localparam type VX_cp_pkg_cmd_header_t
			// removed localparam type VX_cp_pkg_cmd_t
			reg [287:0] cmd;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:29:3
			wire grant;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:31:3
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:36:3
		end
	endgenerate
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:91:3
	// expanded interface instance: bid_dcr_if
	generate
		if (1) begin : bid_dcr_if
			// removed import VX_cp_pkg::*;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:26:3
			reg valid;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:27:3
			reg [1:0] priority_;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:28:3
			// removed localparam type VX_cp_pkg_cmd_header_t
			// removed localparam type VX_cp_pkg_cmd_t
			reg [287:0] cmd;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:29:3
			wire grant;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:31:3
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:36:3
		end
	endgenerate
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:92:3
	// expanded interface instance: bid_event_if
	generate
		if (1) begin : bid_event_if
			// removed import VX_cp_pkg::*;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:26:3
			reg valid;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:27:3
			reg [1:0] priority_;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:28:3
			// removed localparam type VX_cp_pkg_cmd_header_t
			// removed localparam type VX_cp_pkg_cmd_t
			reg [287:0] cmd;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:29:3
			wire grant;
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:31:3
			// Trace: hw/rtl/cp/VX_cp_engine_bid_if.sv:36:3
		end
	endgenerate
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:95:3
	assign bid_kmu_if.grant = bid_kmu_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:96:3
	assign bid_dma_if.grant = bid_dma_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:97:3
	assign bid_dcr_if.grant = bid_dcr_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:98:3
	assign bid_event_if.grant = bid_event_grant;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:100:3
	assign bid_kmu_valid = bid_kmu_if.valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:101:3
	assign bid_kmu_prio = bid_kmu_if.priority_;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:102:3
	assign bid_kmu_cmd = bid_kmu_if.cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:104:3
	assign bid_dma_valid = bid_dma_if.valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:105:3
	assign bid_dma_prio = bid_dma_if.priority_;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:106:3
	assign bid_dma_cmd = bid_dma_if.cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:108:3
	assign bid_dcr_valid = bid_dcr_if.valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:109:3
	assign bid_dcr_prio = bid_dcr_if.priority_;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:110:3
	assign bid_dcr_cmd = bid_dcr_if.cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:112:3
	assign bid_event_valid = bid_event_if.valid;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:113:3
	assign bid_event_prio = bid_event_if.priority_;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:114:3
	assign bid_event_cmd = bid_event_if.cmd;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:117:3
	wire cmd_in_ready_w;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:118:3
	assign cmd_in_ready = cmd_in_ready_w;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:120:3
	// expanded module instance: u_engine
	localparam _param_012F3_QID = 0;
	localparam _param_012F3_ENABLE_NOP_FAST_PATH = ENABLE_NOP_FAST_PATH;
	function automatic [7:0] sv2v_cast_8;
		input reg [7:0] inp;
		sv2v_cast_8 = inp;
	endfunction
	generate
		if (1) begin : u_engine
			reg _sv2v_0;
			// removed import VX_cp_pkg::*;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:32:13
			localparam signed [31:0] QID = _param_012F3_QID;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:33:13
			localparam [0:0] ENABLE_NOP_FAST_PATH = _param_012F3_ENABLE_NOP_FAST_PATH;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:35:3
			wire clk;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:36:3
			wire reset;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:40:3
			wire [1:0] prio_in;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:43:3
			wire [63:0] seqnum_out;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:46:3
			wire cmd_in_valid;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:47:3
			// removed localparam type VX_cp_pkg_cmd_header_t
			// removed localparam type VX_cp_pkg_cmd_t
			wire [287:0] cmd_in;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:48:3
			reg cmd_in_ready;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:51:3
			// removed modport instance bid_kmu
			// Trace: hw/rtl/cp/VX_cp_engine.sv:52:3
			// removed modport instance bid_dma
			// Trace: hw/rtl/cp/VX_cp_engine.sv:53:3
			// removed modport instance bid_dcr
			// Trace: hw/rtl/cp/VX_cp_engine.sv:54:3
			// removed modport instance bid_event
			// Trace: hw/rtl/cp/VX_cp_engine.sv:59:3
			wire kmu_done_i;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:60:3
			wire dma_done_i;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:61:3
			wire dcr_done_i;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:62:3
			wire event_done_i;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:67:3
			reg retire_evt;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:68:3
			reg [63:0] retire_seqnum;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:69:3
			wire retire_ready_i;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:72:3
			reg submit_evt;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:73:3
			wire start_evt;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:74:3
			reg end_evt;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:75:3
			reg [63:0] profile_slot;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:78:3
			// removed localparam type state_e
			// Trace: hw/rtl/cp/VX_cp_engine.sv:86:3
			reg [2:0] fsm;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:87:3
			reg [287:0] cur_cmd;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:88:3
			// removed localparam type VX_cp_pkg_cp_resource_e
			reg [1:0] cur_res;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:89:3
			reg no_resource;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:90:3
			reg [63:0] seqnum_r;
			// Trace: hw/rtl/cp/VX_cp_engine.sv:95:3
			// removed localparam type VX_cp_pkg_cp_opcode_e
			function automatic [1:0] classify;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:95:45
				input reg [7:0] op;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:96:45
				output reg skip;
				begin
					// Trace: hw/rtl/cp/VX_cp_engine.sv:97:5
					skip = 1'b0;
					// Trace: hw/rtl/cp/VX_cp_engine.sv:98:5
					case (op)
						8'h06: classify = 2'd0;
						8'h04, 8'h05, 8'h0a: classify = 2'd2;
						8'h01, 8'h02, 8'h03: classify = 2'd1;
						8'h08, 8'h09: classify = 2'd3;
						default: begin
							// Trace: hw/rtl/cp/VX_cp_engine.sv:108:9
							skip = 1'b1;
							// Trace: hw/rtl/cp/VX_cp_engine.sv:109:9
							classify = 2'd0;
						end
					endcase
				end
			endfunction
			// Trace: hw/rtl/cp/VX_cp_engine.sv:123:3
			always @(posedge clk) begin : sv2v_autoblock_1
				// Trace: hw/rtl/cp/VX_cp_engine.sv:124:5
				reg [1:0] res;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:125:5
				reg skip_flag;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:126:5
				if (reset) begin
					// Trace: hw/rtl/cp/VX_cp_engine.sv:127:7
					fsm <= 3'd0;
					// Trace: hw/rtl/cp/VX_cp_engine.sv:128:7
					cur_cmd <= 1'sb0;
					// Trace: hw/rtl/cp/VX_cp_engine.sv:129:7
					cur_res <= 2'd0;
					// Trace: hw/rtl/cp/VX_cp_engine.sv:130:7
					no_resource <= 1'b0;
					// Trace: hw/rtl/cp/VX_cp_engine.sv:131:7
					seqnum_r <= 1'sb0;
				end
				else
					// Trace: hw/rtl/cp/VX_cp_engine.sv:133:7
					case (fsm)
						3'd0:
							// Trace: hw/rtl/cp/VX_cp_engine.sv:135:11
							if (cmd_in_valid) begin
								// Trace: hw/rtl/cp/VX_cp_engine.sv:136:13
								cur_cmd <= cmd_in;
								// Trace: hw/rtl/cp/VX_cp_engine.sv:137:13
								if (ENABLE_NOP_FAST_PATH && (cmd_in[263-:8] == 8'h00))
									// Trace: hw/rtl/cp/VX_cp_engine.sv:139:15
									fsm <= 3'd4;
								else
									// Trace: hw/rtl/cp/VX_cp_engine.sv:141:15
									fsm <= 3'd1;
							end
						3'd1: begin
							// Trace: hw/rtl/cp/VX_cp_engine.sv:146:11
							res = classify(sv2v_cast_8(cur_cmd[263-:8]), skip_flag);
							// Trace: hw/rtl/cp/VX_cp_engine.sv:147:11
							cur_res <= res;
							// Trace: hw/rtl/cp/VX_cp_engine.sv:148:11
							no_resource <= skip_flag;
							// Trace: hw/rtl/cp/VX_cp_engine.sv:149:11
							if (skip_flag)
								// Trace: hw/rtl/cp/VX_cp_engine.sv:150:13
								fsm <= 3'd4;
							else
								// Trace: hw/rtl/cp/VX_cp_engine.sv:152:13
								fsm <= 3'd2;
						end
						3'd2:
							// Trace: hw/rtl/cp/VX_cp_engine.sv:157:11
							case (cur_res)
								2'd0:
									if (VX_cp_engine_top.bid_kmu_if.grant)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:158:45
										fsm <= 3'd3;
								2'd1:
									if (VX_cp_engine_top.bid_dma_if.grant)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:159:45
										fsm <= 3'd3;
								2'd2:
									if (VX_cp_engine_top.bid_dcr_if.grant)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:160:45
										fsm <= 3'd3;
								2'd3:
									if (VX_cp_engine_top.bid_event_if.grant)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:161:43
										fsm <= 3'd3;
								default:
									// Trace: hw/rtl/cp/VX_cp_engine.sv:162:45
									fsm <= 3'd4;
							endcase
						3'd3:
							// Trace: hw/rtl/cp/VX_cp_engine.sv:167:11
							case (cur_res)
								2'd0:
									if (kmu_done_i)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:168:42
										fsm <= 3'd4;
								2'd1:
									if (dma_done_i)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:169:42
										fsm <= 3'd4;
								2'd2:
									if (dcr_done_i)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:170:42
										fsm <= 3'd4;
								2'd3:
									if (event_done_i)
										// Trace: hw/rtl/cp/VX_cp_engine.sv:171:40
										fsm <= 3'd4;
								default:
									// Trace: hw/rtl/cp/VX_cp_engine.sv:172:42
									fsm <= 3'd4;
							endcase
						3'd4:
							// Trace: hw/rtl/cp/VX_cp_engine.sv:179:11
							if (retire_ready_i) begin
								// Trace: hw/rtl/cp/VX_cp_engine.sv:180:13
								seqnum_r <= seqnum_r + 64'd1;
								// Trace: hw/rtl/cp/VX_cp_engine.sv:181:13
								fsm <= 3'd0;
							end
						default:
							// Trace: hw/rtl/cp/VX_cp_engine.sv:184:18
							fsm <= 3'd0;
					endcase
			end
			// Trace: hw/rtl/cp/VX_cp_engine.sv:193:3
			localparam signed [31:0] VX_cp_pkg_F_PROFILE = 0;
			always @(*) begin
				if (_sv2v_0)
					;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:194:5
				cmd_in_ready = fsm == 3'd0;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:197:5
				VX_cp_engine_top.bid_kmu_if.valid = (fsm == 3'd2) && (cur_res == 2'd0);
				// Trace: hw/rtl/cp/VX_cp_engine.sv:198:5
				VX_cp_engine_top.bid_kmu_if.priority_ = prio_in;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:199:5
				VX_cp_engine_top.bid_kmu_if.cmd = cur_cmd;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:201:5
				VX_cp_engine_top.bid_dma_if.valid = (fsm == 3'd2) && (cur_res == 2'd1);
				// Trace: hw/rtl/cp/VX_cp_engine.sv:202:5
				VX_cp_engine_top.bid_dma_if.priority_ = prio_in;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:203:5
				VX_cp_engine_top.bid_dma_if.cmd = cur_cmd;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:205:5
				VX_cp_engine_top.bid_dcr_if.valid = (fsm == 3'd2) && (cur_res == 2'd2);
				// Trace: hw/rtl/cp/VX_cp_engine.sv:206:5
				VX_cp_engine_top.bid_dcr_if.priority_ = prio_in;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:207:5
				VX_cp_engine_top.bid_dcr_if.cmd = cur_cmd;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:209:5
				VX_cp_engine_top.bid_event_if.valid = (fsm == 3'd2) && (cur_res == 2'd3);
				// Trace: hw/rtl/cp/VX_cp_engine.sv:210:5
				VX_cp_engine_top.bid_event_if.priority_ = prio_in;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:211:5
				VX_cp_engine_top.bid_event_if.cmd = cur_cmd;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:213:5
				retire_evt = fsm == 3'd4;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:214:5
				retire_seqnum = seqnum_r;
				// Trace: hw/rtl/cp/VX_cp_engine.sv:216:5
				submit_evt = ((fsm == 3'd1) && cur_cmd[264]) || (((((fsm == 3'd0) && cmd_in_valid) && ENABLE_NOP_FAST_PATH) && (cmd_in[263-:8] == 8'h00)) && cmd_in[264]);
				// Trace: hw/rtl/cp/VX_cp_engine.sv:224:5
				end_evt = ((fsm == 3'd4) && retire_ready_i) && cur_cmd[264];
				// Trace: hw/rtl/cp/VX_cp_engine.sv:226:5
				profile_slot = cur_cmd[63-:64];
			end
			// Trace: hw/rtl/cp/VX_cp_engine.sv:234:3
			assign start_evt = ((fsm == 3'd2) && cur_cmd[264]) && (((((cur_res == 2'd0) && VX_cp_engine_top.bid_kmu_if.grant) || ((cur_res == 2'd1) && VX_cp_engine_top.bid_dma_if.grant)) || ((cur_res == 2'd2) && VX_cp_engine_top.bid_dcr_if.grant)) || ((cur_res == 2'd3) && VX_cp_engine_top.bid_event_if.grant));
			// Trace: hw/rtl/cp/VX_cp_engine.sv:246:3
			assign seqnum_out = seqnum_r;
			initial _sv2v_0 = 0;
		end
	endgenerate
	assign u_engine.clk = clk;
	assign u_engine.reset = reset;
	assign u_engine.prio_in = state_prio;
	assign seqnum_out_w = u_engine.seqnum_out;
	assign u_engine.cmd_in_valid = cmd_in_valid;
	assign u_engine.cmd_in = cmd_in_typed;
	assign cmd_in_ready_w = u_engine.cmd_in_ready;
	assign u_engine.kmu_done_i = kmu_done_i;
	assign u_engine.dma_done_i = dma_done_i;
	assign u_engine.dcr_done_i = dcr_done_i;
	assign u_engine.event_done_i = event_done_i;
	assign retire_evt = u_engine.retire_evt;
	assign retire_seqnum = u_engine.retire_seqnum;
	assign u_engine.retire_ready_i = 1'b1;
	assign submit_evt = u_engine.submit_evt;
	assign start_evt = u_engine.start_evt;
	assign end_evt = u_engine.end_evt;
	assign profile_slot = u_engine.profile_slot;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:148:3
	assign seqnum_out = seqnum_out_w;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:149:3
	assign engine_fsm = u_engine.fsm;
	// Trace: hw/unittest/cp_engine/VX_cp_engine_top.sv:150:3
	assign nop_fast_path = ENABLE_NOP_FAST_PATH;
endmodule