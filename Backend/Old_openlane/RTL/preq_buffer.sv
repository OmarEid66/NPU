// ================================================================
//  preq_buffer — Post-Requantization Buffer
//
//  Stores INT8 results after requantization.
//  8 rows × 8 cols × INT8 = 64 bytes total.
//
//  Write: controlled entirely by req_unit (wr_en + wr_addr).
//  Read:  one full row per cycle → ReLU unit (or STORE engine).
//
//  Parameters:
//    SA_SIZE : rows and columns (default 8)
//
// ================================================================

module preq_buffer #(
    parameter SA_SIZE = 4
)(
    input  logic clk,
    input  logic rst_n,

    // ── Write Port (owned by req_unit) ────────────────────────
    input  logic                              wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]        wr_addr,
    input  logic [SA_SIZE-1:0][7:0] wr_data,

    // ── Read Port (to ReLU unit) ──────────────────────────────
    input  logic [$clog2(SA_SIZE)-1:0]        rd_addr,
    output logic [SA_SIZE-1:0][7:0] rd_data
);

// ── Storage: 8 rows × 8 cols × INT8 ──────────────────────────
logic [SA_SIZE-1:0][7:0] mem [SA_SIZE];

// ── Write ─────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
end

// ── Read (combinational) ──────────────────────────────────────
assign rd_data = mem[rd_addr];

endmodule