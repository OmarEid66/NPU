// ================================================================
//  acc_buffer — Accumulation Buffer
//
//  Stores the output of the Systolic Array (SA).
//  8 rows × 8 columns of INT32 = 8 entries × 256-bit wide.
//
//  Write: one full row (256 bits = 8×INT32) per cycle,
//         driven by the CU in sync with sa_valid_out.
//  Read:  one full row per cycle, addressed by Bias Adder Unit.
//
//  Parameters:
//    SA_SIZE    : number of rows/cols (default 8)
//    DATA_W_OUT : accumulator bit-width (default 32, INT32)
//
// ================================================================

module acc_buffer #(
    parameter SA_SIZE    = 8,
    parameter DATA_W_OUT = 32
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // ── Write Port (from SA via CU) ───────────────────────────
    input  logic                              wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]        wr_addr,          // row index 0-7
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0] wr_data, // one full row (8×INT32)
    // ── Read Port (to Bias Adder Unit) ────────────────────────
    input  logic [$clog2(SA_SIZE)-1:0]        rd_addr,           // row index 0-7
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0] rd_data  // one full row (8×INT32)
);

// ── Storage: 8 rows, each 8×32 = 256 bits ────────────────────
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
