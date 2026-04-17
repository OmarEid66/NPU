// ============================================================
//  relu_int8_tb.sv
//  Testbench for ReLU (Vector INT8)
//
//  Features:
//    - Directed tests (basic + edge cases)
//    - 5000 randomized tests
//    - Self-checking (golden model)
//    - Full array verification
// ============================================================

`timescale 1ns/1ps

module relu_int8_tb();

    // -------------------------------------------------------
    //  Parameters & DUT signals
    // -------------------------------------------------------
    localparam int DATA_WIDTH = 8;
    localparam int ARRAY_SIZE = 8;
    localparam int CLK_PERIOD = 10; // 100 MHz

    logic clk_tb;
    logic rst_n_tb;

    logic signed [DATA_WIDTH-1:0] in_data_tb  [0:ARRAY_SIZE-1];
    logic signed [DATA_WIDTH-1:0] out_data_tb [0:ARRAY_SIZE-1];

    int pass_count = 0;
    int fail_count = 0;

    // -------------------------------------------------------
    //  DUT instantiation
    // -------------------------------------------------------
    ReLU #(
        .DATA_WIDTH(DATA_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) dut (
        .clk(clk_tb),
        .rst_n(rst_n_tb),
        .in_data(in_data_tb),
        .out_data(out_data_tb)
    );

    // -------------------------------------------------------
    //  Clock generation
    // -------------------------------------------------------
    always #(CLK_PERIOD/2) clk_tb = ~clk_tb;

    // -------------------------------------------------------
    //  Task: Directed test
    // -------------------------------------------------------
    task automatic drive_and_check(
        input logic signed [DATA_WIDTH-1:0] in_val,
        input logic signed [DATA_WIDTH-1:0] expected
    );
    begin
        // Drive all lanes
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            in_data_tb[i] = in_val;
        end

        @(negedge clk_tb);

        // Check all lanes
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            if (out_data_tb[i] === expected) begin
                pass_count++;
            end else begin
                $display("FAIL (Directed): lane=%0d in=%0d expected=%0d got=%0d",
                          i, in_val, expected, out_data_tb[i]);
                fail_count++;
            end
        end
    end
    endtask

    // -------------------------------------------------------
    //  Task: Random test
    // -------------------------------------------------------
    task automatic drive_and_check_random();
        logic signed [DATA_WIDTH-1:0] in_val;
        logic signed [DATA_WIDTH-1:0] expected;
    begin
        // Random INT8 value (-128 to 127)
        in_val = $urandom_range(0,255) - 128;

        // Golden model
        expected = (in_val < 0) ? 0 : in_val;

        // Drive all lanes
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            in_data_tb[i] = in_val;
        end

        @(negedge clk_tb);

        // Check all lanes
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            if (out_data_tb[i] === expected) begin
                pass_count++;
            end else begin
                $display("FAIL (Random): lane=%0d in=%0d expected=%0d got=%0d",
                          i, in_val, expected, out_data_tb[i]);
                fail_count++;
            end
        end
    end
    endtask

    // -------------------------------------------------------
    //  Stimulus
    // -------------------------------------------------------
    initial begin
        // Init
        clk_tb   = 0;
        rst_n_tb = 0;

        for (int i = 0; i < ARRAY_SIZE; i++) begin
            in_data_tb[i] = '0;
        end

        // Reset
        @(negedge clk_tb);
        rst_n_tb = 1;

        // ---------------------------------------------------
        // Directed tests
        // ---------------------------------------------------
        $display("Starting Directed Tests...");
        drive_and_check(8,    8);
        drive_and_check(0,    0);
        drive_and_check(-5,   0);
        drive_and_check(-128, 0);
        drive_and_check(127,  127);

        // ---------------------------------------------------
        // Random tests (5000)
        // ---------------------------------------------------
        $display("Starting Random Tests...");
        for (int t = 0; t < 5000; t++) begin
            drive_and_check_random();

            // Progress print every 500 tests
            if (t % 500 == 0) begin
                $display("Progress: %0d / 5000", t);
            end
        end

        // ---------------------------------------------------
        // Summary
        // ---------------------------------------------------
        $display("=====================================");
        $display("FINAL RESULTS");
        $display("PASS = %0d", pass_count);
        $display("FAIL = %0d", fail_count);
        $display("=====================================");

        if (fail_count == 0)
            $display("ALL TESTS PASSED ✅");
        else
            $display("SOME TESTS FAILED ❌");

        $stop;
    end

endmodule