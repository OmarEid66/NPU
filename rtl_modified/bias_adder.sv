// ================================================================
//  bias_adder — Bias Adder Unit
//
//  Reads acc_buffer row by row, adds the corresponding bias
//  (broadcast from bias_buffer), and writes results to pbias_buffer.
//
//  Operation:
//    For each row r in 0..SA_SIZE-1:
//      pbias[r][c] = acc[r][c] + bias[c]   for c in 0..SA_SIZE-1
//
//  Processes one full row per cycle → takes SA_SIZE cycles total.
//  start/done handshake matches SA convention.
//
//  Assumptions:
//    - acc_buffer read is combinational (1-cycle latency absorbed
//      by registering rd_addr one cycle before reading data).
//    - bias_buffer read is combinational (broadcast, always valid).
//    - No overflow guard: INT32 + INT32 = INT32 (upper bits drop).
//      For a real design add saturation if needed.
//
//  Parameters:
//    SA_SIZE    : rows and columns (default 8)
//    DATA_W_OUT : data bit-width (default 32)
//
// ================================================================

module bias_adder #(
    parameter SA_SIZE    = 8,
    parameter DATA_W_OUT = 32
)(
    input  logic clk,
    input  logic rst_n,

    // ── Handshake ─────────────────────────────────────────────
    input  logic start,       // 1-cycle pulse from CU (ADD_BIAS instr)
    output logic done,        // 1-cycle pulse when all rows processed
    output logic busy,        // HIGH while running

    // ── acc_buffer read port ──────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0]  acc_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0] acc_rd_data,

    // ── bias_buffer read port (broadcast) ────────────────────
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0] bias_rd_data,

    // ── pbias_buffer write port ───────────────────────────────
    output logic                        pb_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]  pb_wr_addr,
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0] pb_wr_data
);

// ── FSM ───────────────────────────────────────────────────────
typedef enum logic [1:0] {
    BA_IDLE = 2'd0,
    BA_READ = 2'd1,   // issue read address, wait 1 cycle for data
    BA_ADD  = 2'd2,   // data valid: add + write to pbias_buffer
    BA_DONE = 2'd3    // pulse done, back to IDLE
} ba_state_t;

ba_state_t state, next_state;

logic [$clog2(SA_SIZE)-1:0] row_cnt;      // current row being processed
logic [$clog2(SA_SIZE)-1:0] row_cnt_r;    // registered (for write-back alignment)
logic                        last_row;

assign last_row = (row_cnt == SA_SIZE - 1);

// ── State register ────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= BA_IDLE;
    else        state <= next_state;
end

// ── Next-state logic ──────────────────────────────────────────
always_comb begin
    next_state = state;
    case (state)
        BA_IDLE: if (start)   next_state = BA_READ;
        BA_READ:              next_state = BA_ADD;
        BA_ADD:  begin
            if (last_row)     next_state = BA_DONE;
            else              next_state = BA_READ;
        end
        BA_DONE:              next_state = BA_IDLE;
        default:              next_state = BA_IDLE;
    endcase
end

// ── Row counter ───────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_cnt <= '0;
    else if (state == BA_IDLE)
        row_cnt <= '0;
    else if (state == BA_READ)
        row_cnt <= row_cnt;          // hold during read latency
    else if (state == BA_ADD && !last_row)
        row_cnt <= row_cnt + 1'b1;
end

// Pipeline register: capture row index when read is issued
// so write-back address is aligned with returned data
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) row_cnt_r <= '0;
    else if (state == BA_READ) row_cnt_r <= row_cnt;
end

// ── acc_buffer address ────────────────────────────────────────
assign acc_rd_addr = row_cnt;

// ── Addition + pbias_buffer write ────────────────────────────
genvar c;
generate
    for (c = 0; c < SA_SIZE; c++) begin : ADD_COL
        assign pb_wr_data[c] = acc_rd_data[c] + bias_rd_data[c];
    end
endgenerate

assign pb_wr_en   = (state == BA_ADD);
assign pb_wr_addr = row_cnt_r;

// ── Handshake outputs ─────────────────────────────────────────
assign busy = (state != BA_IDLE);
assign done = (state == BA_DONE);

endmodule
