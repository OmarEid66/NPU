// ================================================================
//  req_unit — Requantization Unit
//
//  Reads one full row from pbias_buffer, applies per-tensor
//  requantization to all 8 elements in parallel (1 cycle/row),
//  and writes the INT8 results directly to preq_buffer.
//
//  Operation (per element):
//    mul    = qa[c] * M0          (INT32 × UINT32 → INT65)
//    shifted = mul >>> n_scale    (arithmetic right shift)
//    clipped = saturate(shifted)  (INT65 → INT8, [-128, 127])
//
//  Timing:
//    Cycle 0        : CU pulses start, row_addr latched
//    Cycle 1        : mul+shift+clip computed (combinational)
//                     registered output written to preq_buffer
//                     row counter increments
//    After 8 starts : done pulse asserted
//
//  REQ owns preq_buffer write port entirely.
//  CU only provides: start, pb_rd_addr, pb_rd_data, b, c.
//
//  Parameters:
//    SA_SIZE  : number of columns (default 8)
//    B_WIDTH  : M0 bit-width     (default 32)
//    C_WIDTH  : n_scale width    (default 5)
//
// ================================================================

module req_unit #(
    parameter SA_SIZE = 8,
    parameter B_WIDTH = 32,
    parameter C_WIDTH = 5
)(
    input  logic clk,
    input  logic rst_n,

    // ── Handshake ─────────────────────────────────────────────
    input  logic start,     // 1-cycle pulse per row from CU
    output logic done,      // 1-cycle pulse after all SA_SIZE rows
    output logic busy,      // HIGH while processing

    // ── Scale inputs (from scale register + instruction) ──────
    input  logic [B_WIDTH-1:0] b,       // M0 multiplier (per-tensor)
    input  logic [C_WIDTH-1:0] c,       // n_scale shift amount

    // ── pbias_buffer read port ────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]  pb_rd_addr,
    input  logic signed [31:0]          pb_rd_data [SA_SIZE],

    // ── preq_buffer write port (REQ owns this) ────────────────
    output logic                        preq_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]  preq_wr_addr,
    output logic signed [7:0]           preq_wr_data [SA_SIZE]
);

// ── Internal ──────────────────────────────────────────────────
localparam ROW_CNT_W = $clog2(SA_SIZE);

logic [ROW_CNT_W-1:0] row_cnt;       // which row we are writing next
logic                  running;       // HIGH from first start until done
logic                  last_row;

assign last_row = (row_cnt == SA_SIZE - 1);

// ── running flag ──────────────────────────────────────────────
// Set on first start, cleared after last row written
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        running <= 1'b0;
    else if (start && !running)
        running <= 1'b1;
    else if (done)
        running <= 1'b0;
end

// ── Row counter ───────────────────────────────────────────────
// Increments every time a start pulse arrives
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_cnt <= '0;
    else if (done)
        row_cnt <= '0;          // reset after full tile
    else if (start)
        row_cnt <= row_cnt + 1'b1;
end

// ── pbias_buffer read address = current row ───────────────────
// CU must hold pb_rd_data stable for 1 cycle after start
assign pb_rd_addr = row_cnt;

// ── 8 parallel Req datapaths ──────────────────────────────────
// All combinational; result registered one cycle after start
genvar col;
generate
    for (col = 0; col < SA_SIZE; col++) begin : REQ_COL

        logic signed [B_WIDTH+32:0] mul_result;
        logic signed [B_WIDTH+32:0] shifted;
        logic signed [7:0]          clipped;

        // Multiply: INT32 × UINT32
        assign mul_result = pb_rd_data[col] * $signed({1'b0, b});

        // Arithmetic right shift by n_scale
        assign shifted = mul_result >>> c;

        // Saturate to INT8
        always_comb begin
            if      (shifted > 64'sh000000000000007F)
                clipped = 8'sh7F;
            else if (shifted < 64'shFFFFFFFFFFFFFF80)
                clipped = 8'sh80;
            else
                clipped = shifted[7:0];
        end

        // Register output — aligns with preq_wr_en below
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) preq_wr_data[col] <= 8'sh00;
            else        preq_wr_data[col] <= clipped;
        end

    end
endgenerate

// ── preq_buffer write control ─────────────────────────────────
// wr_en is start delayed by 1 cycle (data registered same cycle)
// wr_addr is row_cnt before increment (the row just processed)

logic                  wr_en_r;
logic [ROW_CNT_W-1:0]  wr_addr_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_en_r   <= 1'b0;
        wr_addr_r <= '0;
    end else begin
        wr_en_r   <= start;          // delayed 1 cycle
        wr_addr_r <= row_cnt;        // row being written (pre-increment)
    end
end

assign preq_wr_en   = wr_en_r;
assign preq_wr_addr = wr_addr_r;

// ── done: pulses when last row write completes ─────────────────
assign done = wr_en_r && (wr_addr_r == SA_SIZE - 1);

// ── busy ──────────────────────────────────────────────────────
assign busy = running || start;

endmodule