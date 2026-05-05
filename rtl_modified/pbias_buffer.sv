// ================================================================
//  pbias_buffer — Post-Bias Buffer
//
//  Stores the result of acc + bias before requantization (REQ).
//  Same geometry as acc_buffer: 8 rows × 8 cols × INT32.
//
//  Write: one full row per cycle from bias_adder.
//  Read:  one full row per cycle to REQ unit.
//
//  Parameters:
//    SA_SIZE    : rows and columns (default 8)
//    DATA_W_OUT : data bit-width (default 32)
//
// ================================================================

module pbias_buffer #(
    parameter SA_SIZE    = 8,
    parameter DATA_W_OUT = 32
)(
    input  logic clk,
    input  logic rst_n,

    // ── Write Port (from bias_adder) ──────────────────────────
    input  logic                              wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]        wr_addr,
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0] wr_data,

    // ── Read Port (to REQ unit) ───────────────────────────────
    input  logic [$clog2(SA_SIZE)-1:0]        rd_addr,
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0] rd_data
);

// ── Storage ───────────────────────────────────────────────────
logic [SA_SIZE-1:0][DATA_W_OUT-1:0] mem [SA_SIZE];

// ── Write ─────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (wr_en) begin
        mem[wr_addr] <= wr_data;
    end
end

// ── Read (combinational) ──────────────────────────────────────
assign rd_data = mem[rd_addr];

endmodule
