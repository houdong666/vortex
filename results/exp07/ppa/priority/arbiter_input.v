module VX_cp_arbiter (
	clk,
	reset,
	bid_valid,
	bid_priority,
	bid_grant,
	rr_pointer_o,
	selected_queue_o
);
	reg _sv2v_0;
	parameter signed [31:0] N = 1;
	parameter [0:0] ENABLE_PRIORITY = 1;
	input wire clk;
	input wire reset;
	input wire [0:N - 1] bid_valid;
	input wire [(N * 2) - 1:0] bid_priority;
	output wire [0:N - 1] bid_grant;
	output wire [(N > 1 ? $clog2(N) : 1) - 1:0] rr_pointer_o;
	output wire [(N > 1 ? $clog2(N) : 1) - 1:0] selected_queue_o;
	localparam signed [31:0] PTR_W = (N > 1 ? $clog2(N) : 1);
	reg [PTR_W - 1:0] rr_pointer;
	reg [PTR_W - 1:0] selected_queue;
	reg selected_valid;
	reg [1:0] highest_priority;
	reg [N - 1:0] eligible;
	integer i;
	integer offset;
	integer scan_index;
	assign rr_pointer_o = rr_pointer;
	assign selected_queue_o = selected_queue;
	genvar _gv_g_1;
	function automatic signed [PTR_W - 1:0] sv2v_cast_E310E_signed;
		input reg signed [PTR_W - 1:0] inp;
		sv2v_cast_E310E_signed = inp;
	endfunction
	generate
		for (_gv_g_1 = 0; _gv_g_1 < N; _gv_g_1 = _gv_g_1 + 1) begin : g_ports
			localparam g = _gv_g_1;
			assign bid_grant[g] = selected_valid && (selected_queue == sv2v_cast_E310E_signed(g));
		end
	endgenerate
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		highest_priority = 1'sb0;
		for (i = 0; i < N; i = i + 1)
			if (bid_valid[i] && (bid_priority[((N - 1) - i) * 2+:2] > highest_priority))
				highest_priority = bid_priority[((N - 1) - i) * 2+:2];
		for (i = 0; i < N; i = i + 1)
			eligible[i] = bid_valid[i] && (!ENABLE_PRIORITY || (bid_priority[((N - 1) - i) * 2+:2] == highest_priority));
		selected_queue = rr_pointer;
		selected_valid = 1'b0;
		scan_index = sv2v_cast_32_signed(rr_pointer);
		for (offset = 0; offset < N; offset = offset + 1)
			begin
				scan_index = sv2v_cast_32_signed(rr_pointer) + offset;
				if (scan_index >= N)
					scan_index = scan_index - N;
				if (!selected_valid && eligible[scan_index]) begin
					selected_queue = sv2v_cast_E310E_signed(scan_index);
					selected_valid = 1'b1;
				end
			end
	end
	always @(posedge clk)
		if (reset)
			rr_pointer <= 1'sb0;
		else if (selected_valid) begin
			if (selected_queue == sv2v_cast_E310E_signed(N - 1))
				rr_pointer <= 1'sb0;
			else
				rr_pointer <= selected_queue + sv2v_cast_E310E_signed(1);
		end
	initial _sv2v_0 = 0;
endmodule
module VX_cp_arbiter_top (
	clk,
	reset,
	bid_valid,
	bid_priority,
	bid_grant,
	rr_pointer,
	selected_queue
);
	parameter signed [31:0] N = 4;
	parameter [0:0] ENABLE_PRIORITY = 1;
	input wire clk;
	input wire reset;
	input wire [N - 1:0] bid_valid;
	input wire [(2 * N) - 1:0] bid_priority;
	output wire [N - 1:0] bid_grant;
	output wire [$clog2(N) - 1:0] rr_pointer;
	output wire [$clog2(N) - 1:0] selected_queue;
	wire [0:N - 1] in_valid;
	wire [(N * 2) - 1:0] in_prio;
	wire [0:N - 1] out_grant;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_unpack
			localparam i = _gv_i_1;
			assign in_valid[i] = bid_valid[i];
			assign in_prio[((N - 1) - i) * 2+:2] = bid_priority[2 * i+:2];
			assign bid_grant[i] = out_grant[i];
		end
	endgenerate
	VX_cp_arbiter #(
		.N(N),
		.ENABLE_PRIORITY(ENABLE_PRIORITY)
	) u_arb(
		.clk(clk),
		.reset(reset),
		.bid_valid(in_valid),
		.bid_priority(in_prio),
		.bid_grant(out_grant),
		.rr_pointer_o(rr_pointer),
		.selected_queue_o(selected_queue)
	);
endmodule