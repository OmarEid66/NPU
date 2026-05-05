// ================================================================
//  store_engine — STORE Instruction Execution Unit
//
//  Reads one row at a time from the selected buffer
//  (preq_buffer or relu_buffer), packs 8×INT8 into two 32-bit
//  words, and writes them to SRAM port 0.
//
//  Buffer select (buf_sel[0]):
//    0 → preq_buffer  (post-REQ, INT8)
//    1 → relu_buffer  (post-ReLU, INT8)
//
//  Packing (little-endian columns):
//    word0 = { col[3], col[2], col[1], col[0] }  → SRAM[base + 2*row]
//    word1 = { col[7], col[6], col[5], col[4] }  → SRAM[base + 2*row + 1]
//
//  Total SRAM writes: 8 rows × 2 words = 16 cycles
//
//  FSM:
//    IDLE   → wait for start
//    RD_BUF → issue buffer read address (combinational read, 0 latency)
//    WR_LO  → write lower 4 bytes to SRAM
//    WR_HI  → write upper 4 bytes to SRAM, advance row
//    ST_DONE→ pulse done
//
//  Signals to SRAM port 0 (go through mux in npu_top):
//    st_sram_we0  : 4-bit byte enable (4'hF = all bytes)
//    st_sram_en0  : port enable
//    st_sram_a0   : 8-bit word address
//    st_sram_di0  : 32-bit write data
//
//  Parameters:
//    SA_SIZE    : buffer rows/cols     (default 8)
//    DATA_WIDTH : element width        (default 8)
//    SRAM_AW    : SRAM address width   (default 8)
//
// ================================================================

module store_engine #(
    parameter SA_SIZE    = 8,
    parameter DATA_WIDTH = 8,
    parameter SRAM_AW    = 8
)(
    input  logic clk,
    input  logic rst_n,

    // ── Handshake ─────────────────────────────────────────────
    input  logic start,
    output logic done,
    output logic busy,

    // ── From instruction decoder ──────────────────────────────
    input  logic              buf_sel,          // 0=preq 1=relu
    input  logic [SRAM_AW-1:0] base_addr,       // tile_addr_a from instruction

    // ── preq_buffer read port ─────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]   preq_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_WIDTH-1:0] preq_rd_data,

    // ── relu_buffer read port ─────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]   relu_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_WIDTH-1:0] relu_rd_data,

    // ── SRAM port 0 write signals (to mux in npu_top) ─────────
    output logic [3:0]        st_sram_we0,
    output logic              st_sram_en0,
    output logic [SRAM_AW-1:0] st_sram_a0,
    output logic [31:0]        st_sram_di0
);

// ── FSM ───────────────────────────────────────────────────────
typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_RD    = 3'd1,   // issue buffer read address
    ST_WR_LO = 3'd2,   // write col[3:0] → SRAM
    ST_WR_HI = 3'd3,   // write col[7:4] → SRAM
    ST_DONE  = 3'd4
} st_state_t;

st_state_t state, next_state;

// ── Counters ──────────────────────────────────────────────────
logic [$clog2(SA_SIZE)-1:0] row_cnt;
logic                        last_row;

assign last_row = (row_cnt == SA_SIZE - 1);

// ── State register ────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= ST_IDLE;
    else        state <= next_state;
end

// ── Next-state ────────────────────────────────────────────────
always_comb begin
    next_state = state;
    case (state)
        ST_IDLE:   if (start)  next_state = ST_RD;
        ST_RD:                 next_state = ST_WR_LO;
        ST_WR_LO:              next_state = ST_WR_HI;
        ST_WR_HI:  begin
            if (last_row)      next_state = ST_DONE;
            else               next_state = ST_RD;
        end
        ST_DONE:               next_state = ST_IDLE;
        default:               next_state = ST_IDLE;
    endcase
end

// ── Row counter ───────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_cnt <= '0;
    else if (state == ST_DONE)
        row_cnt <= '0;
    else if (state == ST_WR_HI && !last_row)
        row_cnt <= row_cnt + 1'b1;
end

// ── Buffer read address (both ports driven, mux by buf_sel) ───
assign preq_rd_addr = row_cnt;
assign relu_rd_addr = row_cnt;

// ── Selected row data ─────────────────────────────────────────
logic [SA_SIZE-1:0][DATA_WIDTH-1:0] sel_row;

always_comb begin
    if (buf_sel)
        sel_row = relu_rd_data;
    else
        sel_row = preq_rd_data;
end

// ── Latch row when read is issued ─────────────────────────────
logic [SA_SIZE-1:0][DATA_WIDTH-1:0] row_latch;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_latch <= 0;
    else if (state == ST_RD)
        row_latch <= sel_row;   // combinational read, latch immediately
end

// ── Pack INT8 columns into 32-bit words ───────────────────────
logic [31:0] word_lo, word_hi;

assign word_lo = { row_latch[3], row_latch[2], row_latch[1], row_latch[0] };
assign word_hi = { row_latch[7], row_latch[6], row_latch[5], row_latch[4] };

// ── SRAM write address ────────────────────────────────────────
// Each row → 2 words: base + row*2 (lo), base + row*2 + 1 (hi)
logic [SRAM_AW-1:0] sram_word_addr;

always_comb begin
    sram_word_addr = base_addr + {row_cnt, 1'b0};   // row * 2
    if (state == ST_WR_HI)
        sram_word_addr = sram_word_addr + 1'b1;      // +1 for hi word
end

// ── SRAM port 0 drive ─────────────────────────────────────────
always_comb begin
    st_sram_we0 = 4'h0;
    st_sram_en0 = 1'b0;
    st_sram_a0  = '0;
    st_sram_di0 = '0;

    if (state == ST_WR_LO) begin
        st_sram_en0 = 1'b1;
        st_sram_we0 = 4'hF;
        st_sram_a0  = sram_word_addr;
        st_sram_di0 = word_lo;
    end
    else if (state == ST_WR_HI) begin
        st_sram_en0 = 1'b1;
        st_sram_we0 = 4'hF;
        st_sram_a0  = sram_word_addr;
        st_sram_di0 = word_hi;
    end
end

// ── Handshake ─────────────────────────────────────────────────
assign done = (state == ST_DONE);
assign busy = (state != ST_IDLE);

endmodule
