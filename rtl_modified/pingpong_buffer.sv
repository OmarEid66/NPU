// ============================================================
// pingpong_buffer.sv
//
// Ping-Pong Buffer for Weight-Stationary 8×8 Systolic Array
//
// STRUCTURE:
//   Two banks (A and B), each holding 64 × 8-bit = 8 rows × 8 cols
//
// WRITE PORT  (from SRAM, 32-bit per cycle):
//   SRAM gives 4 bytes per read → need 16 reads to fill one bank
//   wr_byte_addr[3:1] = row  index (0-7)
//   wr_byte_addr[0]   = col-group (0→cols 0-3, 1→cols 4-7)
//
// READ PORT   (to SA, 64-bit = full row per cycle):
//   SA is weight-stationary → requests one full row per cycle
//   rd_row selects which of the 8 rows to output
//
// PING-PONG:
//   active_bank = 0 → SA reads Bank A, SRAM fills Bank B
//   active_bank = 1 → SA reads Bank B, SRAM fills Bank A
//   swap pulse → toggles active_bank
// ============================================================

module pingpong_buffer #(
    parameter int ROWS  = 8,
    parameter int COLS  = 8,
    parameter int WIDTH = 8     // INT8
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // ── Write port (from SRAM loader, 32-bit = 4 bytes) ─────
    input  logic                     wr_en,
    input  logic [3:0]               wr_byte_addr,  // 0-15 (16 words cover 64 bytes)
    input  logic [31:0]              wr_data,       // 4 × INT8 packed little-endian

    // ── Read port (to SA, 64-bit = one full row) ─────────────
    input  logic [$clog2(ROWS)-1:0]  rd_row,        // which row the SA wants (0-7)
    output logic [COLS*WIDTH-1:0]    rd_data,        // 64-bit output: col0 in [7:0]

    // ── Control ──────────────────────────────────────────────
    input  logic                     swap,           // pulse: swap active/fill bank
    output logic                     fill_done,      // inactive bank fully written
    output logic                     active_bank     // 0=BankA active, 1=BankB active
);

    // ── Storage: 2 banks, each [ROWS][COLS] bytes ────────────
    logic [WIDTH-1:0] bank_a [ROWS][COLS];
    logic [WIDTH-1:0] bank_b [ROWS][COLS];

    // ── Fill counter ─────────────────────────────────────────
    // 16 writes (each 32-bit = 4 bytes) fill one 64-byte bank
    logic [3:0] fill_count;

    // ── Address decode ────────────────────────────────────────
    // wr_byte_addr[3:1] → row (0-7)
    // wr_byte_addr[0]   → col-group: 0 = cols[0:3], 1 = cols[4:7]
    logic [2:0] wr_row;
    logic       wr_col_grp;
    assign wr_row     = wr_byte_addr[3:1];
    assign wr_col_grp = wr_byte_addr[0];

    // ── Fill counter + fill_done ──────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_count <= '0;
            fill_done  <= 1'b0;
        end else begin
            fill_done <= 1'b0;          // default: pulse for one cycle only
            if (wr_en) begin
                if (fill_count == 4'd15) begin
                    fill_count <= '0;
                    fill_done  <= 1'b1; // bank fully loaded
                end else begin
                    fill_count <= fill_count + 4'd1;
                end
            end
        end
    end

    // ── Bank swap ─────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_bank <= 1'b0;
        else if (swap)
            active_bank <= ~active_bank;
    end

    // ── Write to INACTIVE bank ────────────────────────────────
    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (active_bank == 1'b0) begin
                // SA uses Bank A → fill Bank B
                bank_b[wr_row][wr_col_grp ? 4 : 0] <= wr_data[ 7: 0];
                bank_b[wr_row][wr_col_grp ? 5 : 1] <= wr_data[15: 8];
                bank_b[wr_row][wr_col_grp ? 6 : 2] <= wr_data[23:16];
                bank_b[wr_row][wr_col_grp ? 7 : 3] <= wr_data[31:24];
            end else begin
                // SA uses Bank B → fill Bank A
                bank_a[wr_row][wr_col_grp ? 4 : 0] <= wr_data[ 7: 0];
                bank_a[wr_row][wr_col_grp ? 5 : 1] <= wr_data[15: 8];
                bank_a[wr_row][wr_col_grp ? 6 : 2] <= wr_data[23:16];
                bank_a[wr_row][wr_col_grp ? 7 : 3] <= wr_data[31:24];
            end
        end
    end

    // ── Read from ACTIVE bank (combinational, full row) ───────
    // SA gets all 8 bytes of the selected row in one cycle
    always_comb begin
        for (int c = 0; c < COLS; c++) begin
            if (active_bank == 1'b0)
                rd_data[c*WIDTH +: WIDTH] = bank_a[rd_row][c];
            else
                rd_data[c*WIDTH +: WIDTH] = bank_b[rd_row][c];
        end
    end

endmodule