// ================================================================
//  bias_buffer — Bias Buffer
//
//  Stores bias values pre-loaded by the CU (LOAD_BIAS instruction).
//  8 bias values × INT32 = one bias per output column.
//
//  Write: word-by-word from SRAM (4 bytes per SRAM read → 1 word).
//         CU writes all 8 entries during LOAD_BIAS execution.
//  Read:  full row (all 8 biases at once) → Bias Adder Unit.
//
//  Parameters:
//    SA_SIZE    : number of output channels (default 8)
//    DATA_W_OUT : bias bit-width (default 32, INT32)
//
// ================================================================

module bias_buffer #(
    parameter SA_SIZE    = 8,
    parameter DATA_W_OUT = 32
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // ── Write Port (from CU, LOAD_BIAS instruction) ───────────
    input  logic                              wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]        wr_addr,   // bias index 0-7
    input  logic [DATA_W_OUT-1:0]             wr_data,   // one INT32 bias value

    // ── Read Port (to Bias Adder Unit) ────────────────────────
    // All 8 biases read simultaneously (broadcast)
    output logic [DATA_W_OUT-1:0]             rd_data [SA_SIZE]
);

// ── Storage: 8 × INT32 ────────────────────────────────────────
logic [DATA_W_OUT-1:0] mem [SA_SIZE];

// ── Write ─────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (wr_en) begin
        mem[wr_addr] <= wr_data;
    end
end

// ── Read (combinational, full broadcast) ──────────────────────
genvar i;
generate
    for (i = 0; i < SA_SIZE; i++) begin : BIAS_RD
        assign rd_data[i] = mem[i];
    end
endgenerate

endmodule