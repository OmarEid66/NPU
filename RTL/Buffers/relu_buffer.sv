// ================================================================
//  relu_buffer — Post-ReLU Buffer
//
//  Stores INT8 results after ReLU activation.
//  8 rows × 8 cols × INT8 = 64 bytes total.
//
//  Write: controlled by relu_unit (wr_en + wr_addr).
//  Read:  one full row per cycle → Pooling unit or STORE engine.
//
//  Parameters:
//    SA_SIZE    : rows and columns (default 8)
//    DATA_WIDTH : element bit-width (default 8, INT8)
//
// ================================================================

module relu_buffer #(
    parameter SA_SIZE    = 8,
    parameter DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst_n,

    // ── Write Port (from relu_unit) ───────────────────────────
    input  logic                              wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]        wr_addr,
    input  var logic [DATA_WIDTH-1:0]  wr_data [SA_SIZE],

    // ── Read Port (to Pool unit or STORE engine) ───────────────
    input  logic [$clog2(SA_SIZE)-1:0]        rd_addr,
    output logic [DATA_WIDTH-1:0]      rd_data [SA_SIZE]
);

// ── Storage: 8 rows × 8 cols × INT8 ──────────────────────────
logic [DATA_WIDTH-1:0] mem [SA_SIZE][SA_SIZE];  // 2D: row × col

// ── Write ─────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
end

// ── Read (combinational) ──────────────────────────────────────
assign rd_data = mem[rd_addr];

endmodule