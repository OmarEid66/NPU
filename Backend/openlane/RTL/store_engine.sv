module store_engine #(
    parameter SA_SIZE    = 4,
    parameter DATA_WIDTH = 8,
    parameter SRAM_AW    = 7     
)(
    input  logic clk,
    input  logic rst_n,

    // ── Handshake ─────────────────────────────────────────────
    input  logic start,
    output logic done,
    output logic busy,

    // ── From instruction decoder ──────────────────────────────
    input  logic               buf_sel,
    input  logic [SRAM_AW-1:0] base_addr,

    // ── preq_buffer read port ─────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]         preq_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_WIDTH-1:0] preq_rd_data, 

    // ── relu_buffer read port ─────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]         relu_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_WIDTH-1:0] relu_rd_data,  

    // ── SRAM port 0 write signals ─────────────────────────────
    output logic [3:0]         st_sram_we0,
    output logic               st_sram_en0,
    output logic [SRAM_AW-1:0] st_sram_a0,
    output logic [31:0]        st_sram_di0
);

// ── FSM ───────────────────────────────────────────────────────
typedef enum logic [1:0] {
    ST_IDLE    = 2'd0,
    ST_RD      = 2'd1,   
    ST_WR_WORD = 2'd2,   
    ST_DONE    = 2'd3
} st_state_t;

st_state_t state, next_state;

// ── Row counter ───────────────────────────────────────────────
logic [$clog2(SA_SIZE)-1:0] row_cnt;
logic                        last_row;

assign last_row = (row_cnt == SA_SIZE - 1);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= ST_IDLE;
    else        state <= next_state;
end

always_comb begin
    next_state = state;
    case (state)
        ST_IDLE:    if (start)   next_state = ST_RD;
        ST_RD:                   next_state = ST_WR_WORD;
        ST_WR_WORD: begin
            if (last_row)        next_state = ST_DONE;
            else                 next_state = ST_RD;
        end
        ST_DONE:                 next_state = ST_IDLE;
        default:                 next_state = ST_IDLE;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_cnt <= '0;
    else if (state == ST_DONE)
        row_cnt <= '0;
    else if (state == ST_WR_WORD && !last_row)
        row_cnt <= row_cnt + 1'b1;
end

assign preq_rd_addr = row_cnt;
assign relu_rd_addr = row_cnt;

logic [SA_SIZE-1:0][DATA_WIDTH-1:0] sel_row;

always_comb begin
    if (buf_sel)
        sel_row = relu_rd_data;
    else
        sel_row = preq_rd_data;
end

logic [SA_SIZE-1:0][DATA_WIDTH-1:0] row_latch;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_latch <= 0;          // YOSYS FIX: Safely hardcoded to 0
    else if (state == ST_RD)
        row_latch <= sel_row;
end

logic [31:0] word_packed;
assign word_packed = { row_latch[3], row_latch[2],
                       row_latch[1], row_latch[0] };

logic [SRAM_AW-1:0] sram_word_addr;
assign sram_word_addr = base_addr +
                        {{(SRAM_AW-$clog2(SA_SIZE)){1'b0}}, row_cnt};

always_comb begin
    st_sram_we0 = 4'h0;
    st_sram_en0 = 1'b0;
    st_sram_a0  = '0;
    st_sram_di0 = '0;

    if (state == ST_WR_WORD) begin
        st_sram_en0 = 1'b1;
        st_sram_we0 = 4'hF;
        st_sram_a0  = sram_word_addr;
        st_sram_di0 = word_packed;
    end
end

assign done = (state == ST_DONE);
assign busy = (state != ST_IDLE);

endmodule
