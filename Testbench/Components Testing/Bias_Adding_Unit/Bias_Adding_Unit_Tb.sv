// =============================================================================
// tb_Bias_Adding_Unit.sv  —  NanoNPU Bias Adder Testbench  (5000 tests)
//
// Test distribution (5000 total):
//   Group 1  [  500] Fully random act + bias
//   Group 2  [  500] Zero bias  — output must equal input
//   Group 3  [  500] Zero act   — output must equal saturate(bias)
//   Group 4  [  500] Max positive act (127) + random positive bias → saturate
//   Group 5  [  500] Min negative act (-128) + random negative bias → saturate
//   Group 6  [  500] Small act + small bias — no saturation expected
//   Group 7  [  500] Large positive bias only (act=0) → saturate to 127
//   Group 8  [  500] Large negative bias only (act=0) → saturate to -128
//   Group 9  [  500] Mixed signs — positive act + negative bias
//   Group 10 [  500] Full 8x8 matrix sweep (same bias per row)
//   + Fixed corner cases always run first (8 directed tests)
// =============================================================================

`timescale 1ns/1ps

module tb_Bias_Adding_Unit;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int ACT_WIDTH  = 8;
    localparam int BIAS_WIDTH = 32;
    localparam int OUT_WIDTH  = 8;
    localparam int NUM_CH     = 8;
    localparam int TOTAL_RAND = 5000;

    // =========================================================================
    // DUT ports
    // =========================================================================
    logic                          clk;
    logic                          rst_n;
    logic                          start;
    logic                          valid_in;
    logic [NUM_CH*ACT_WIDTH-1:0]   act_in;
    logic [NUM_CH*BIAS_WIDTH-1:0]  bias_in;
    logic                          valid_out;
    logic [NUM_CH*OUT_WIDTH-1:0]   out;
    logic                          done;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    Bias_Adding_Unit #(
        .ACT_WIDTH  (ACT_WIDTH),
        .BIAS_WIDTH (BIAS_WIDTH),
        .OUT_WIDTH  (OUT_WIDTH),
        .NUM_CH     (NUM_CH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .valid_in  (valid_in),
        .act_in    (act_in),
        .bias_in   (bias_in),
        .valid_out (valid_out),
        .out       (out),
        .done      (done)
    );

    // =========================================================================
    // Clock — 100 MHz
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Counters
    // =========================================================================
    int pass_count;
    int fail_count;
    int test_num;

    // =========================================================================
    // Task: pack flat buses
    // =========================================================================
    task automatic pack_inputs(
        input logic signed [ACT_WIDTH-1:0]  act  [NUM_CH],
        input logic signed [BIAS_WIDTH-1:0] bias [NUM_CH]
    );
        int k;
        for (k = 0; k < NUM_CH; k++) begin
            act_in [k*ACT_WIDTH  +: ACT_WIDTH]  = act[k];
            bias_in[k*BIAS_WIDTH +: BIAS_WIDTH] = bias[k];
        end
    endtask

    // =========================================================================
    // Function: read one output channel
    // =========================================================================
    function automatic logic signed [OUT_WIDTH-1:0] get_out(input int ch);
        return signed'(out[ch*OUT_WIDTH +: OUT_WIDTH]);
    endfunction

    // =========================================================================
    // Function: reference saturating adder
    // =========================================================================
    function automatic logic signed [OUT_WIDTH-1:0] ref_add(
        input logic signed [ACT_WIDTH-1:0]  a,
        input logic signed [BIAS_WIDTH-1:0] b
    );
        logic signed [BIAS_WIDTH-1:0] s;
        localparam signed [OUT_WIDTH-1:0] SAT_MAX = {1'b0, {(OUT_WIDTH-1){1'b1}}};
        localparam signed [OUT_WIDTH-1:0] SAT_MIN = {1'b1, {(OUT_WIDTH-1){1'b0}}};
        s = BIAS_WIDTH'(signed'(a)) + b;
        if      (s > BIAS_WIDTH'(signed'(SAT_MAX))) return SAT_MAX;
        else if (s < BIAS_WIDTH'(signed'(SAT_MIN))) return SAT_MIN;
        else                                        return OUT_WIDTH'(s);
    endfunction

    // =========================================================================
    // Task: run one transaction and check
    // =========================================================================
    task automatic run_and_check(
        input string                        grp_name,
        input logic signed [ACT_WIDTH-1:0]  act  [NUM_CH],
        input logic signed [BIAS_WIDTH-1:0] bias [NUM_CH]
    );
        logic signed [OUT_WIDTH-1:0] exp_val;
        logic signed [OUT_WIDTH-1:0] actual;
        logic all_ok;
        int   ch;

        pack_inputs(act, bias);
        start    = 1'b1;
        valid_in = 1'b1;
        @(posedge clk); #1;

        // Check control signals
        if (!done || !valid_out) begin
            $display("FAIL [%s #%0d] done=%0b valid_out=%0b (expected 1)",
                     grp_name, test_num, done, valid_out);
            fail_count++;
            start    = 1'b0;
            valid_in = 1'b0;
            test_num++;
            return;
        end

        // Check all channels
        all_ok = 1'b1;
        for (ch = 0; ch < NUM_CH; ch++) begin
            exp_val = ref_add(act[ch], bias[ch]);
            actual  = get_out(ch);
            if (actual !== exp_val) begin
                $display("FAIL [%s #%0d] ch%0d got=%0d exp=%0d (act=%0d bias=%0d)",
                         grp_name, test_num, ch,
                         $signed(actual), $signed(exp_val),
                         $signed(act[ch]), $signed(bias[ch]));
                all_ok = 1'b0;
            end
        end

        if (all_ok) pass_count++;
        else        fail_count++;

        start    = 1'b0;
        valid_in = 1'b0;
        test_num++;
        @(posedge clk); #1;
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin

        // ── All locals declared here (ModelSim static var rule) ───────────────
        logic signed [ACT_WIDTH-1:0]  act  [NUM_CH];
        logic signed [BIAS_WIDTH-1:0] bias [NUM_CH];
        logic signed [OUT_WIDTH-1:0]  exp_val;
        logic                         all_rows_ok;
        int                           i, row, col, t;
        int                           rand_act_raw;
        int                           rand_bias_raw;

        // ── Reset ─────────────────────────────────────────────────────────────
        pass_count = 0;
        fail_count = 0;
        test_num   = 1;
        rst_n      = 1'b0;
        start      = 1'b0;
        valid_in   = 1'b0;
        act_in     = '0;
        bias_in    = '0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        $display("========================================");
        $display(" NanoNPU Bias Adder — 5000 Test Suite  ");
        $display("========================================");

        // =====================================================================
        // DIRECTED CORNER CASES (always run first, 8 tests)
        // =====================================================================
        $display("-- Directed corner cases --");

        // C1: All zeros
        for (i=0;i<NUM_CH;i++) begin act[i]=0;       bias[i]=0;         end
        run_and_check("C1 All zeros", act, bias);

        // C2: Max positive, zero bias
        for (i=0;i<NUM_CH;i++) begin act[i]=8'sd127;  bias[i]=32'sd0;   end
        run_and_check("C2 Max act zero bias", act, bias);

        // C3: Min negative, zero bias
        for (i=0;i<NUM_CH;i++) begin act[i]=-8'sd128; bias[i]=32'sd0;   end
        run_and_check("C3 Min act zero bias", act, bias);

        // C4: Positive overflow boundary (127+1=128 → 127)
        for (i=0;i<NUM_CH;i++) begin act[i]=8'sd127;  bias[i]=32'sd1;   end
        run_and_check("C4 Pos sat boundary", act, bias);

        // C5: Negative overflow boundary (-128-1=-129 → -128)
        for (i=0;i<NUM_CH;i++) begin act[i]=-8'sd128; bias[i]=-32'sd1;  end
        run_and_check("C5 Neg sat boundary", act, bias);

        // C6: Exact positive saturation limit (127+0=127, no sat)
        for (i=0;i<NUM_CH;i++) begin act[i]=8'sd127;  bias[i]=32'sd0;   end
        run_and_check("C6 Exact sat limit pos", act, bias);

        // C7: valid_in=0 — done must be 0
        start=1'b1; valid_in=1'b0; act_in='1; bias_in='1;
        @(posedge clk); #1;
        if (!done && !valid_out) begin
            $display("PASS [C7 valid_in gating #%0d]", test_num);
            pass_count++;
        end else begin
            $display("FAIL [C7 valid_in gating #%0d] done=%0b valid_out=%0b",
                     test_num, done, valid_out);
            fail_count++;
        end
        start=1'b0; valid_in=1'b0; test_num++;
        @(posedge clk); #1;

        // C8: Large bias magnitude (act=0, bias=2^30 → sat to 127)
        for (i=0;i<NUM_CH;i++) begin act[i]=8'sd0; bias[i]=32'sd1073741824; end
        run_and_check("C8 Huge positive bias", act, bias);

        // =====================================================================
        // GROUP 1: Fully random act + bias (500 tests)
        // =====================================================================
        $display("-- Group 1: Fully random (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_act_raw  = $random;
                rand_bias_raw = $random;
                act[i]  = rand_act_raw[ACT_WIDTH-1:0];
                bias[i] = rand_bias_raw;
            end
            run_and_check("G1 Random", act, bias);
        end

        // =====================================================================
        // GROUP 2: Zero bias — output = input (500 tests)
        // =====================================================================
        $display("-- Group 2: Zero bias identity (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_act_raw = $random;
                act[i]  = rand_act_raw[ACT_WIDTH-1:0];
                bias[i] = 32'sd0;
            end
            run_and_check("G2 Zero bias", act, bias);
        end

        // =====================================================================
        // GROUP 3: Zero act — output = saturate(bias) (500 tests)
        // =====================================================================
        $display("-- Group 3: Zero act (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_bias_raw = $random;
                act[i]  = 8'sd0;
                bias[i] = rand_bias_raw;
            end
            run_and_check("G3 Zero act", act, bias);
        end

        // =====================================================================
        // GROUP 4: Max act (127) + random positive bias → always saturate (500)
        // =====================================================================
        $display("-- Group 4: Max act + positive bias saturation (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_bias_raw = $urandom_range(1, 2147483647);
                act[i]  = 8'sd127;
                bias[i] = rand_bias_raw;
            end
            run_and_check("G4 Max act sat", act, bias);
        end

        // =====================================================================
        // GROUP 5: Min act (-128) + random negative bias → always saturate (500)
        // =====================================================================
        $display("-- Group 5: Min act + negative bias saturation (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_bias_raw = -$urandom_range(1, 2147483647);
                act[i]  = -8'sd128;
                bias[i] = rand_bias_raw;
            end
            run_and_check("G5 Min act sat", act, bias);
        end

        // =====================================================================
        // GROUP 6: Small act + small bias — no saturation (500 tests)
        //   act in [-50..50], bias in [-50..50] → sum in [-100..100] → no sat
        // =====================================================================
        $display("-- Group 6: Small values no saturation (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                act[i]  = 8'($urandom_range(0,100)) - 8'sd50;
                bias[i] = 32'($urandom_range(0,100)) - 32'sd50;
            end
            run_and_check("G6 Small no sat", act, bias);
        end

        // =====================================================================
        // GROUP 7: act=0, large positive bias → saturate to 127 (500 tests)
        // =====================================================================
        $display("-- Group 7: Large positive bias saturation (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_bias_raw = $urandom_range(128, 2147483647);
                act[i]  = 8'sd0;
                bias[i] = rand_bias_raw;
            end
            run_and_check("G7 Large pos bias", act, bias);
        end

        // =====================================================================
        // GROUP 8: act=0, large negative bias → saturate to -128 (500 tests)
        // =====================================================================
        $display("-- Group 8: Large negative bias saturation (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_bias_raw = -$urandom_range(129, 2147483647);
                act[i]  = 8'sd0;
                bias[i] = rand_bias_raw;
            end
            run_and_check("G8 Large neg bias", act, bias);
        end

        // =====================================================================
        // GROUP 9: Mixed signs — positive act, negative bias (500 tests)
        // =====================================================================
        $display("-- Group 9: Mixed signs (500) --");
        for (t = 0; t < 500; t++) begin
            for (i = 0; i < NUM_CH; i++) begin
                rand_act_raw  =  $urandom_range(0, 127);
                rand_bias_raw = -$urandom_range(0, 2147483647);
                act[i]  = rand_act_raw[ACT_WIDTH-1:0];
                bias[i] = rand_bias_raw;
            end
            run_and_check("G9 Mixed signs", act, bias);
        end

        // =====================================================================
        // GROUP 10: Full 8x8 matrix sweep — same bias row-by-row (500 tests)
        //   Each test = one full matrix pass (8 rows), bias changes per test
        //   Total rows checked = 500 * 8 = 4000 row transactions
        // =====================================================================
        $display("-- Group 10: Full 8x8 matrix sweep (500 matrices) --");
        for (t = 0; t < 500; t++) begin
            // Pick a fresh random bias vector for this matrix
            for (i = 0; i < NUM_CH; i++) begin
                rand_bias_raw = $random;
                bias[i] = rand_bias_raw;
            end

            all_rows_ok = 1'b1;

            for (row = 0; row < NUM_CH; row++) begin
                // Each row has random activations
                for (col = 0; col < NUM_CH; col++) begin
                    rand_act_raw = $random;
                    act[col] = rand_act_raw[ACT_WIDTH-1:0];
                end

                pack_inputs(act, bias);
                start = 1'b1; valid_in = 1'b1;
                @(posedge clk); #1;

                for (col = 0; col < NUM_CH; col++) begin
                    exp_val = ref_add(act[col], bias[col]);
                    if (get_out(col) !== exp_val) begin
                        $display("FAIL [G10 Matrix #%0d] row%0d col%0d got=%0d exp=%0d",
                                 t, row, col,
                                 $signed(get_out(col)), $signed(exp_val));
                        all_rows_ok = 1'b0;
                    end
                end

                start = 1'b0; valid_in = 1'b0;
                @(posedge clk); #1;
            end

            if (all_rows_ok) pass_count++;
            else             fail_count++;
            test_num++;
        end

        // =====================================================================
        // Final report
        // =====================================================================
        $display("=========================================");
        $display(" Total transactions : %0d", test_num - 1);
        $display(" PASSED             : %0d", pass_count);
        $display(" FAILED             : %0d", fail_count);
        $display("=========================================");
        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" SOME TESTS FAILED — review log above");
        $display("=========================================");

        $stop;
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    initial begin
        #10000000;
        $fatal(1, "TIMEOUT: simulation exceeded limit");
    end

endmodule