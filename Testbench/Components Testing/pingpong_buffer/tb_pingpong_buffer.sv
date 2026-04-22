// ============================================================
// tb_pingpong_buffer.sv
//
// Tests for pingpong_buffer.sv
//
// TEST PLAN:
//   Test 1 – Fill Bank A (active=0), verify rd_data unchanged
//   Test 2 – Swap, verify active_bank toggles to 1
//   Test 3 – Read every row of (now active) Bank B, check data
//   Test 4 – Fill Bank A while reading Bank B (true ping-pong)
//   Test 5 – Swap again, read Bank A, check new data
// ============================================================

`timescale 1ns/1ps

module tb_pingpong_buffer;

    // ── DUT parameters ────────────────────────────────────────
    localparam int ROWS  = 8;
    localparam int COLS  = 8;
    localparam int WIDTH = 8;

    // ── DUT signals ───────────────────────────────────────────
    logic                    clk;
    logic                    rst_n;

    logic                    wr_en;
    logic [3:0]              wr_byte_addr;
    logic [31:0]             wr_data;

    logic [2:0]              rd_row;
    logic [COLS*WIDTH-1:0]   rd_data;   // 64-bit

    logic                    swap;
    logic                    fill_done;
    logic                    active_bank;

    // ── DUT instantiation ─────────────────────────────────────
    pingpong_buffer #(
        .ROWS  (ROWS),
        .COLS  (COLS),
        .WIDTH (WIDTH)
    ) dut (.*);

    // ── Clock generation (10 ns period) ───────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Helper tasks ──────────────────────────────────────────

    // Write one 32-bit word to the inactive bank
    task automatic write_word(input [3:0] addr, input [31:0] data);
        @(posedge clk);
        #1;
        wr_en        = 1'b1;
        wr_byte_addr = addr;
        wr_data      = data;
        @(posedge clk);
        #1;
        wr_en        = 1'b0;
    endtask

    // Fill the entire inactive bank with a pattern.
    // pattern[row][col_grp] = base + row*2 + col_grp packed as 4×byte
    task automatic fill_bank(input [7:0] base);
        logic [7:0] b;
        logic [31:0] word;
        for (int row = 0; row < ROWS; row++) begin
            for (int cg = 0; cg < 2; cg++) begin   // 2 col-groups per row
                // Pack 4 bytes: each byte = base + row*16 + cg*4 + byte_index
                for (int k = 0; k < 4; k++) begin
                    b = base + (row * 8) + (cg * 4) + k;
                    word[k*8 +: 8] = b;
                end
                write_word(row * 2 + cg, word);
            end
        end
    endtask

    // Issue a swap pulse
    task automatic do_swap();
        @(posedge clk);
        #1;
        swap = 1'b1;
        @(posedge clk);
        #1;
        swap = 1'b0;
    endtask

    // Read one row and return the 64-bit result
    task automatic read_row(input [2:0] row, output [63:0] result);
        @(posedge clk);
        #1;
        rd_row = row;
        @(posedge clk);          // combinational read, valid same cycle
        #1;
        result = rd_data;
    endtask

    // ── Error counter ─────────────────────────────────────────
    int error_count = 0;

    task automatic check(
        input string   label,
        input [63:0]   got,
        input [63:0]   expected
    );
        if (got !== expected) begin
            $display("FAIL [%0t] %s : got=%0h expected=%0h", $time, label, got, expected);
            error_count++;
        end else begin
            $display("PASS [%0t] %s : 0x%016h", $time, label, got);
        end
    endtask

    // ── Main test sequence ────────────────────────────────────
    initial begin
        // Initialise
        rst_n        = 1'b0;
        wr_en        = 1'b0;
        wr_byte_addr = '0;
        wr_data      = '0;
        rd_row       = '0;
        swap         = 1'b0;

        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("\n=== TEST 1: Fill inactive bank (Bank B, base=0x10) ===");
        // active_bank=0 after reset → SA reads BankA, loader fills BankB
        fill_bank(8'h10);

        $display("fill_done expected 1, got %b", fill_done);
        if (fill_done !== 1'b1) begin
            $display("FAIL: fill_done not asserted after 16 writes");
            error_count++;
        end

        $display("\n=== TEST 2: Swap banks (active_bank should become 1) ===");
        do_swap();
        @(posedge clk); #1;
        $display("active_bank expected 1, got %b", active_bank);
        if (active_bank !== 1'b1) begin
            $display("FAIL: active_bank did not toggle");
            error_count++;
        end

        $display("\n=== TEST 3: Read all rows of active bank (Bank B) ===");
        // Expected content: base=0x10, pattern = 0x10 + row*8 + col
        for (int r = 0; r < ROWS; r++) begin
            logic [63:0] expected_row;
            logic [63:0] got;
            for (int c = 0; c < COLS; c++) begin
                expected_row[c*8 +: 8] = 8'h10 + (r * 8) + c;
            end
            rd_row = r[2:0];
            @(posedge clk); #1;         // combinational read
            got = rd_data;
            check($sformatf("Row %0d", r), got, expected_row);
        end

        $display("\n=== TEST 4: Fill Bank A (new data, base=0x20) while reading Bank B ===");
        // active_bank=1 → SA reads BankB, loader fills BankA
        // We simultaneously read row 0 of Bank B and write to Bank A
        fork
            // Writer: fill Bank A with base=0x20
            begin
                fill_bank(8'h20);
            end
            // Reader: continuously read row 0 of Bank B, should stay = 0x10..0x17
            begin
                logic [63:0] expected_row0;
                logic [63:0] got;
                for (int c = 0; c < COLS; c++)
                    expected_row0[c*8 +: 8] = 8'h10 + c;  // row 0, base=0x10
                repeat(16) begin
                    rd_row = 3'd0;
                    @(posedge clk); #1;
                    got = rd_data;
                    check("BankB row0 stable during BankA fill", got, expected_row0);
                end
            end
        join

        $display("\n=== TEST 5: Swap again, read Bank A ===");
        do_swap();
        @(posedge clk); #1;
        $display("active_bank expected 0, got %b", active_bank);
        if (active_bank !== 1'b0) begin
            $display("FAIL: active_bank did not toggle back");
            error_count++;
        end

        for (int r = 0; r < ROWS; r++) begin
            logic [63:0] expected_row;
            logic [63:0] got;
            for (int c = 0; c < COLS; c++) begin
                expected_row[c*8 +: 8] = 8'h20 + (r * 8) + c;
            end
            rd_row = r[2:0];
            @(posedge clk); #1;
            got = rd_data;
            check($sformatf("BankA Row %0d after swap", r), got, expected_row);
        end

        $display("\n=== TEST 6: fill_done timing — exactly on 16th write ===");
        // Reset to known state
        do_swap();   // active=1 again
        @(posedge clk); #1;

        // Write 15 words — fill_done must stay 0
        for (int i = 0; i < 15; i++) begin
            write_word(i[3:0], 32'hDEADBEEF);
            if (fill_done !== 1'b0) begin
                $display("FAIL: fill_done asserted early at word %0d", i);
                error_count++;
            end
        end
        // 16th write — fill_done must assert
        write_word(4'd15, 32'hDEADBEEF);
        if (fill_done !== 1'b1) begin
            $display("FAIL: fill_done not asserted on 16th write");
            error_count++;
        end else begin
            $display("PASS: fill_done asserts exactly on 16th write");
        end
        // Next cycle — fill_done must de-assert
        @(posedge clk); #1;
        if (fill_done !== 1'b0) begin
            $display("FAIL: fill_done did not de-assert after 1 cycle");
            error_count++;
        end else begin
            $display("PASS: fill_done is a one-cycle pulse");
        end

        // ── Summary ───────────────────────────────────────────
        repeat(4) @(posedge clk);
        $display("\n=========================================");
        if (error_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d TEST(S) FAILED", error_count);
        $display("=========================================\n");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #100_000;
        $display("TIMEOUT: simulation exceeded 100 us");
        $finish;
    end

    // ── Waveform dump ─────────────────────────────────────────
    initial begin
        $dumpfile("tb_pingpong_buffer.vcd");
        $dumpvars(0, tb_pingpong_buffer);
    end

endmodule