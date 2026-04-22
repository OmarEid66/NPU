`timescale 1ns/1ps

module tb_Req;

    // ── Parameters ────────────────────────────────────
    parameter B_WIDTH = 32;
    parameter C_WIDTH = 5;

    // ── DUT signals ───────────────────────────────────
    logic                  clk;
    logic                  rst_n;
    logic signed [31:0]    qa;
    logic        [31:0]    b;
    logic        [4:0]     c;
    logic signed [7:0]     qo;

    // ── DUT instantiation ─────────────────────────────
    Req #(
        .B_WIDTH(B_WIDTH),
        .C_WIDTH(C_WIDTH)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .qa    (qa),
        .b     (b),
        .c     (c),
        .qo    (qo)
    );

    // ── Clock generation ──────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // ── Task: apply inputs and check ──────────────────
    task apply_and_check(
        input signed [31:0] qa_in,
        input        [31:0] b_in,
        input        [4:0]  c_in,
        input signed [7:0]  expected,
        input string        test_name
    );
        // Apply inputs
        qa = qa_in;
        b  = b_in;
        c  = c_in;

        // Wait one clock for registered output
        @(posedge clk);
        #1; // small delay to let output settle

        // Check
        if (qo === expected) begin
            $display("PASS | %-30s | qa=%0d b=%0d c=%0d | got=%0d expected=%0d",
                      test_name, qa_in, b_in, c_in, qo, expected);
        end else begin
            $display("FAIL | %-30s | qa=%0d b=%0d c=%0d | got=%0d expected=%0d",
                      test_name, qa_in, b_in, c_in, qo, expected);
        end
    endtask

    // ── Helper function: compute expected ─────────────
    // expected = clip(qa * b >>> c, -128, 127)
    function automatic signed [7:0] compute_expected(
        input signed [31:0] qa_in,
        input        [31:0] b_in,
        input        [4:0]  c_in
    );
        logic signed [63:0] product;
        logic signed [63:0] shifted;

        product = qa_in * $signed({1'b0, b_in});
        shifted = product >>> c_in;

        if      (shifted > 64'sh7F)           return 8'sh7F;
        else if (shifted < 64'shFFFFFFFFFFFFFF80) return 8'sh80;
        else                                   return shifted[7:0];
    endfunction

    // ── Test stimulus ─────────────────────────────────
    initial begin
        // Dump waveforms
        $dumpfile("tb_requantization.vcd");
        $dumpvars(0, tb_Req);

        // ── Reset ─────────────────────────────────────
        rst_n = 0;
        qa    = 0;
        b     = 0;
        c     = 0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("─────────────────────────────────────────────────────────────");
        $display("              Requantization Testbench                       ");
        $display("─────────────────────────────────────────────────────────────");

        // ─────────────────────────────────────────────
        // Test 1: Basic positive value
        // qa=100, b=2, c=1
        // expected = 100 * 2 >>> 1 = 200 >>> 1 = 100
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sd100,
            32'd2,
            5'd1,
            8'sd100,
            "Basic positive"
        );

        // ─────────────────────────────────────────────
        // Test 2: Basic negative value
        // qa=-100, b=2, c=1
        // expected = -100 * 2 >>> 1 = -200 >>> 1 = -100
        // ─────────────────────────────────────────────
        apply_and_check(
            -32'sd100,
            32'd2,
            5'd1,
            -8'sd100,
            "Basic negative"
        );

        // ─────────────────────────────────────────────
        // Test 3: Typical CNN scale
        // qa=16256, b=2, c=6
        // expected = 16256 * 2 >>> 6 = 32512 >>> 6 = 508
        // clips to +127
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sd16256,
            32'd2,
            5'd6,
            8'sh7F,
            "Positive overflow → +127"
        );

        // ─────────────────────────────────────────────
        // Test 4: Negative overflow → -128
        // qa=-20000, b=100, c=6
        // expected = -20000 * 100 >>> 6 = -2000000 >>> 6 = -31250
        // clips to -128
        // ─────────────────────────────────────────────
        apply_and_check(
            -32'sd20000,
            32'd100,
            5'd6,
            8'sh80,
            "Negative overflow → -128"
        );

        // ─────────────────────────────────────────────
        // Test 5: Zero input
        // qa=0, b=anything, c=anything
        // expected = 0
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sd0,
            32'd12345,
            5'd10,
            8'sd0,
            "Zero input"
        );

        // ─────────────────────────────────────────────
        // Test 6: Exact +127 boundary
        // qa=127*64=8128, b=1, c=6
        // expected = 8128 * 1 >>> 6 = 127
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sd8128,
            32'd1,
            5'd6,
            8'sd127,
            "Exact +127 boundary"
        );

        // ─────────────────────────────────────────────
        // Test 7: Exact -128 boundary
        // qa=-8192, b=1, c=6
        // expected = -8192 * 1 >>> 6 = -128
        // ─────────────────────────────────────────────
        apply_and_check(
            -32'sd8192,
            32'd1,
            5'd6,
            -8'sd128,
            "Exact -128 boundary"
        );

        // ─────────────────────────────────────────────
        // Test 8: Large shift (c=31)
        // qa=2147483647, b=1, c=31
        // expected = 2147483647 >>> 31 = 0
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sh7FFFFFFF,
            32'd1,
            5'd31,
            8'sd0,
            "Large shift c=31"
        );

        // ─────────────────────────────────────────────
        // Test 9: Typical PyTorch scale factor
        // M = 0.0312 ≈ 2 / 2^6
        // qa=2048, b=2, c=6
        // expected = 2048 * 2 >>> 6 = 4096 >>> 6 = 64
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sd2048,
            32'd2,
            5'd6,
            8'sd64,
            "Typical PyTorch scale"
        );

        // ─────────────────────────────────────────────
        // Test 10: Reset check
        // Apply inputs, assert reset, output should be 0
        // ─────────────────────────────────────────────
        qa    = 32'sd5000;
        b     = 32'd10;
        c     = 5'd4;
        rst_n = 0;
        @(posedge clk);
        #1;
        if (qo === 8'sh00)
            $display("PASS | %-30s | qo=%0d after reset", "Reset clears output", qo);
        else
            $display("FAIL | %-30s | qo=%0d (expected 0)", "Reset clears output", qo);
        rst_n = 1;

        // ─────────────────────────────────────────────
        // Test 11: b=0 (zero multiplier)
        // any qa * 0 = 0
        // ─────────────────────────────────────────────
        apply_and_check(
            32'sd99999,
            32'd0,
            5'd0,
            8'sd0,
            "b=0 zero multiplier"
        );

        // ─────────────────────────────────────────────
        // Test 12: Negative qa, positive result
        // qa=-64, b=2, c=1
        // expected = -64 * 2 >>> 1 = -128 >>> 1 = -64
        // ─────────────────────────────────────────────
        apply_and_check(
            -32'sd64,
            32'd2,
            5'd1,
            -8'sd64,
            "Negative qa within range"
        );

        $display("─────────────────────────────────────────────────────────────");
        $display("                    Tests Complete                           ");
        $display("─────────────────────────────────────────────────────────────");

        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────
    initial begin
        #10000;
        $display("TIMEOUT — simulation took too long");
        $finish;
    end

endmodule