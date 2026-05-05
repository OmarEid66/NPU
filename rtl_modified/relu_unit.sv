// ================================================================
//  relu_unit — ReLU Unit with Handshake
//
//  Reads one full row per cycle from preq_buffer,
//  passes through combinational ReLU,
//  registers the result (1-cycle latency here, not in ReLU),
//  and writes to relu_buffer.
//
//  Timing per row:
//    Cycle 0 : start pulse → rd_addr issued, ReLU computes combinationally
//    Cycle 1 : registered ReLU output written to relu_buffer
//
//  Total for full tile: SA_SIZE + 1 cycles
//    (SA_SIZE start pulses + 1 flush cycle)
//
//  done : 1-cycle pulse after last row written.
//  busy : HIGH from first start until done.
//
//  Parameters:
//    SA_SIZE    : rows and columns (default 8)
//    DATA_WIDTH : element bit-width (default 8, INT8)
//
// ================================================================

module relu_unit #(
    parameter SA_SIZE    = 8,
    parameter DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst_n,

    // ── Handshake ─────────────────────────────────────────────
    input  logic start,
    output logic done,
    output logic busy,

    // ── preq_buffer read port ─────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]   preq_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_WIDTH-1:0] preq_rd_data,

    // ── relu_buffer write port ────────────────────────────────
    output logic                         relu_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]   relu_wr_addr,
    output logic [SA_SIZE-1:0][DATA_WIDTH-1:0] relu_wr_data
);

localparam ROW_CNT_W = $clog2(SA_SIZE);

// ── Row counter (read side) ───────────────────────────────────
logic [ROW_CNT_W-1:0] rd_row_cnt;
logic                  running;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        running <= 1'b0;
    else if (start && !running)
        running <= 1'b1;
    else if (done)
        running <= 1'b0;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rd_row_cnt <= '0;
    else if (done)
        rd_row_cnt <= '0;
    else if (start)
        rd_row_cnt <= rd_row_cnt + 1'b1;
end

assign preq_rd_addr = rd_row_cnt;

// ── Combinational ReLU ────────────────────────────────────────
logic [SA_SIZE-1:0][DATA_WIDTH-1:0] relu_comb;

ReLU #(
    .DATA_WIDTH (DATA_WIDTH),
    .ARRAY_SIZE (SA_SIZE)
) u_relu (
    .in_data  (preq_rd_data),
    .out_data (relu_comb)
);

// ── Output register (relu_unit owns the single FF stage) ──────
logic                  wr_en_r;
logic [ROW_CNT_W-1:0]  wr_addr_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_en_r      <= 1'b0;
        wr_addr_r    <= '0;
        relu_wr_data <= '0;
    end else begin
        wr_en_r      <= start;
        wr_addr_r    <= rd_row_cnt;
        relu_wr_data <= relu_comb;
    end
end

assign relu_wr_en   = wr_en_r;
assign relu_wr_addr = wr_addr_r;

// ── done / busy ───────────────────────────────────────────────
assign done = wr_en_r && (wr_addr_r == SA_SIZE - 1);
assign busy = running || start;

endmodule
