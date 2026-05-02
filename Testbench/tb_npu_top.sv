// ================================================================
//  tb_npu_top_extended.sv  (v2 — 31 suites, S0-S30)
//  Extended self-checking testbench for npu_top
//
//  Test Suites
//  ───────────
//  SUITE 0  (original)  : 3 iterations, identity weight, positive ACT
//                         Iter0: ACT=1   Iter1: ACT=col+1  Iter2: ACT=r+c
//
//  SUITE 1  Negative ACT: ACT values are negative INT8 (-1..-8 per col)
//           Weight=identity, bias=0 → pre-ReLU output is negative
//           ReLU must clip everything to 0
//
//  SUITE 2  Bias offset: ACT=all-zeros, weight=identity, bias=16 per lane
//           After CONV output is 0, bias lifts to 16, REQ→16, ReLU→16
//
//  SUITE 3  Positive bias + negative act cancel:
//           ACT=-4, weight=identity, bias=+32 (INT32)
//           conv=-4, add_bias=+28, REQ=28, ReLU=28
//
//  SUITE 4  REQ saturation: large positive ACT → pre-ReLU > 127 → clamp 127
//           ACT=127, weight=identity, M0=2^30, n=30 → result=127
//
//  SUITE 5  Mixed-sign rows: even rows ACT=+5, odd rows ACT=-5
//           ReLU clips odd rows to 0, even rows stay 5
//
//  SUITE 6  All-zeros: ACT=0, WGT=0, bias=0 → output=0 throughout
//
//  SUITE 7  Non-identity weight (all-ones 8×8):
//           ACT row = [1,1,1,1,1,1,1,1], WGT all-ones
//           conv[r][c] = sum_k(act[r][k]*wgt[k][c]) = 8×1×1 = 8 per element
//           bias=0, M0=2^30, n=30 → REQ=8, ReLU=8
//
//  Memory layout: all suites share a single DMEM frame.
//  Each suite reloads DMEM+IMEM and resets the NPU between runs.
//
//  N.B. enc_ls tile_b field is unused by the CU in non-split-load
//  instructions (LOAD_ACT/WGT/BIAS/SCL with a single tile address).
//  We keep it 0 throughout for clarity.
// ================================================================

`timescale 1ns/1ps

module tb_npu_top;

    // ─────────────────────────────────────────────────────────────
    //  Parameters
    // ─────────────────────────────────────────────────────────────
    localparam CLK_PERIOD   = 10;
    localparam DATA_W       = 8;
    localparam DATA_W_PATH  = 32;
    localparam SA_SIZE      = 8;
    localparam INST_ADDR_W  = 5;
    localparam INST_DATA_W  = 32;
    localparam SRAM_DATA_W  = 32;
    localparam SRAM_ADDR_W  = 8;
    localparam DMEM_SIZE    = 256;
    localparam IMEM_SIZE    = 32;

    // Opcode table
    localparam [5:0] OP_LOAD_ACT  = 6'b000000;
    localparam [5:0] OP_LOAD_WGT  = 6'b000001;
    localparam [5:0] OP_LOAD_BIAS = 6'b000010;
    localparam [5:0] OP_LOAD_SCL  = 6'b000011;
    localparam [5:0] OP_CONV      = 6'b000100;
    localparam [5:0] OP_ADD_BIAS  = 6'b000101;
    localparam [5:0] OP_REQ       = 6'b000110;
    localparam [5:0] OP_RELU      = 6'b000111;
    localparam [5:0] OP_STORE     = 6'b001001;
    localparam [5:0] OP_NOP       = 6'b111110;
    localparam [5:0] OP_HALT      = 6'b111111;

    // Fixed DMEM layout for single-iteration suites
    localparam int ACT_BASE  =   0;   // 16 words
    localparam int WGT_BASE  =  16;   // 16 words
    localparam int BIAS_BASE =  32;   //  8 words
    localparam int SCL_BASE  =  40;   //  1 word
    localparam int OUT_BASE  =  64;   // 16 words
    // Scratch area starts at 80 — unused in extended suites

    // Identity M0: 2^30 with n_scale=30 → output = input (no scaling)
    localparam [31:0] M0_IDENT  = 32'h4000_0000;  // 2^30
    localparam [4:0]  NS_IDENT  = 5'd30;

    // ─────────────────────────────────────────────────────────────
    //  Clock / reset
    // ─────────────────────────────────────────────────────────────
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ─────────────────────────────────────────────────────────────
    //  DUT ports
    // ─────────────────────────────────────────────────────────────
    logic                       load_imem, load_dmem, dmem_rd_host;
    logic [3:0]                 imem_wr_we;
    logic                       imem_wr_en;
    logic [INST_ADDR_W-1:0]     imem_wr_addr;
    logic [INST_DATA_W-1:0]     imem_wr_data;
    logic                       dmem_wr_en;
    logic [3:0]                 dmem_wr_be;
    logic [SRAM_ADDR_W-1:0]     dmem_wr_addr;
    logic [SRAM_DATA_W-1:0]     dmem_wr_data;
    logic                       dmem_rd_en;
    logic [SRAM_ADDR_W-1:0]     dmem_rd_addr;
    logic [SRAM_DATA_W-1:0]     dmem_rd_data;
    logic                       start_npu, done_processing, npu_done;

    // Global counters
    int total_errors = 0;
    int total_checks = 0;
    int suite_errors = 0;
    int suite_checks = 0;
    int pc_idx       = 0;

    // ─────────────────────────────────────────────────────────────
    //  DUT
    // ─────────────────────────────────────────────────────────────
    npu_top #(
        .DATA_W      (DATA_W),
        .DATA_W_PATH (DATA_W_PATH),
        .SA_SIZE     (SA_SIZE),
        .INST_ADDR_W (INST_ADDR_W),
        .INST_DATA_W (INST_DATA_W),
        .SRAM_DATA_W (SRAM_DATA_W),
        .SRAM_ADDR_W (SRAM_ADDR_W)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .load_imem       (load_imem),
        .load_dmem       (load_dmem),
        .dmem_rd_host    (dmem_rd_host),
        .imem_wr_we      (imem_wr_we),
        .imem_wr_en      (imem_wr_en),
        .imem_wr_addr    (imem_wr_addr),
        .imem_wr_data    (imem_wr_data),
        .dmem_wr_en      (dmem_wr_en),
        .dmem_wr_be      (dmem_wr_be),
        .dmem_wr_addr    (dmem_wr_addr),
        .dmem_wr_data    (dmem_wr_data),
        .dmem_rd_en      (dmem_rd_en),
        .dmem_rd_addr    (dmem_rd_addr),
        .dmem_rd_data    (dmem_rd_data),
        .start_npu       (start_npu),
        .done_processing (done_processing),
        .npu_done        (npu_done)
    );

    // ─────────────────────────────────────────────────────────────
    //  Instruction encoders
    // ─────────────────────────────────────────────────────────────
    function automatic [31:0] enc_ls(
        input [5:0] op,      input [3:0] buf_sel,
        input [5:0] ext,     input [7:0] tile_b,
        input [7:0] tile_a
    );
        return {op, buf_sel, ext, tile_b, tile_a};
    endfunction

    function automatic [31:0] enc_cmp(
        input [5:0] op,      input       w_transpose,
        input [4:0] n_sc,    input       bias_bypass
    );
        return {op, 19'd0, w_transpose, n_sc, bias_bypass};
    endfunction

    // ─────────────────────────────────────────────────────────────
    //  Bus helpers
    // ─────────────────────────────────────────────────────────────
    task automatic init_signals();
        load_imem    = 0;  load_dmem    = 0;  dmem_rd_host = 0;
        imem_wr_we   = '0; imem_wr_en   = 0;
        imem_wr_addr = '0; imem_wr_data = '0;
        dmem_wr_en   = 0;  dmem_wr_be   = '0;
        dmem_wr_addr = '0; dmem_wr_data = '0;
        dmem_rd_en   = 0;  dmem_rd_addr = '0;
        start_npu    = 0;
    endtask

    task automatic do_reset();
        rst_n = 1'b0;
        init_signals();
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    task automatic imem_write(input int addr, input [31:0] data);
        @(posedge clk);
        load_imem    <= 1'b1;
        imem_wr_addr <= addr[INST_ADDR_W-1:0];
        imem_wr_data <= data;
        imem_wr_we   <= 4'hF;
        imem_wr_en   <= 1'b1;
        @(posedge clk);
        imem_wr_en   <= 1'b0;
        imem_wr_we   <= 4'h0;
        load_imem    <= 1'b0;
    endtask

    task automatic dmem_write(input int addr, input [31:0] data);
        @(posedge clk);
        load_dmem    <= 1'b1;
        dmem_wr_addr <= addr[SRAM_ADDR_W-1:0];
        dmem_wr_data <= data;
        dmem_wr_be   <= 4'hF;
        dmem_wr_en   <= 1'b1;
        @(posedge clk);
        dmem_wr_en   <= 1'b0;
        dmem_wr_be   <= 4'h0;
        load_dmem    <= 1'b0;
    endtask

    task automatic dmem_read(input int addr, output [31:0] data);
        @(posedge clk);
        dmem_rd_host <= 1'b1;
        dmem_rd_addr <= addr[SRAM_ADDR_W-1:0];
        dmem_rd_en   <= 1'b1;
        @(posedge clk);
        @(posedge clk);
        data = dmem_rd_data;
        dmem_rd_en   <= 1'b0;
        dmem_rd_host <= 1'b0;
        @(posedge clk);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Tile writers
    // ─────────────────────────────────────────────────────────────

    // Write an 8×8 ACT tile from a 2-D byte array
    task automatic write_act(ref logic signed [7:0] act[8][8]);
        for (int r = 0; r < 8; r++) begin
            logic [31:0] wlo, whi;
            wlo = {act[r][3], act[r][2], act[r][1], act[r][0]};
            whi = {act[r][7], act[r][6], act[r][5], act[r][4]};
            dmem_write(ACT_BASE + 2*r,     wlo);
            dmem_write(ACT_BASE + 2*r + 1, whi);
        end
    endtask

    // Write an 8×8 WGT tile from a 2-D byte array
    task automatic write_wgt(ref logic signed [7:0] wgt[8][8]);
        for (int r = 0; r < 8; r++) begin
            logic [31:0] wlo, whi;
            wlo = {wgt[r][3], wgt[r][2], wgt[r][1], wgt[r][0]};
            whi = {wgt[r][7], wgt[r][6], wgt[r][5], wgt[r][4]};
            dmem_write(WGT_BASE + 2*r,     wlo);
            dmem_write(WGT_BASE + 2*r + 1, whi);
        end
    endtask

    // Write 8 INT32 bias words
    task automatic write_bias(ref logic signed [31:0] bias[8]);
        for (int b = 0; b < 8; b++)
            dmem_write(BIAS_BASE + b, bias[b]);
    endtask

    // Write scale word M0 and remember n_scale for instruction
    task automatic write_scale(input logic [31:0] m0);
        dmem_write(SCL_BASE, m0);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Standard single-iteration program loader
    //  (LOAD_ACT → LOAD_WGT → LOAD_BIAS → LOAD_SCL →
    //   CONV → ADD_BIAS → REQ(n) → RELU → STORE → HALT)
    // ─────────────────────────────────────────────────────────────
    task automatic load_single_iter_program(input [4:0] n_scale);
        pc_idx = 0;
        imem_write(pc_idx++, enc_ls (OP_LOAD_ACT,  4'd0, 6'd0, 8'd0, 8'(ACT_BASE)));
        imem_write(pc_idx++, enc_ls (OP_LOAD_WGT,  4'd0, 6'd0, 8'd0, 8'(WGT_BASE)));
        imem_write(pc_idx++, enc_ls (OP_LOAD_BIAS, 4'd0, 6'd0, 8'd0, 8'(BIAS_BASE)));
        imem_write(pc_idx++, enc_ls (OP_LOAD_SCL,  4'd0, 6'd0, 8'd0, 8'(SCL_BASE)));
        imem_write(pc_idx++, enc_cmp(OP_CONV,      1'b0, 5'd0, 1'b0));
        imem_write(pc_idx++, enc_cmp(OP_ADD_BIAS,  1'b0, 5'd0, 1'b0));
        imem_write(pc_idx++, enc_cmp(OP_REQ,       1'b0, n_scale, 1'b0));
        imem_write(pc_idx++, enc_cmp(OP_RELU,      1'b0, 5'd0, 1'b0));
        imem_write(pc_idx++, enc_ls (OP_STORE,     4'd1, 6'd0, 8'd0, 8'(OUT_BASE)));
        imem_write(pc_idx++, {OP_HALT, 26'd0});
    endtask

    // Run NPU, wait for done, timeout guard
    task automatic run_npu(input int timeout_cycles);
        int cnt;
        @(posedge clk); start_npu <= 1'b1;
        @(posedge clk); start_npu <= 1'b0;
        cnt = 0;
        while (!npu_done && cnt < timeout_cycles) begin
            @(posedge clk); cnt++;
        end
        if (cnt >= timeout_cycles) begin
            $display("  [TIMEOUT] NPU did not complete in %0d cycles!", timeout_cycles);
            total_errors++;
        end
        repeat(4) @(posedge clk);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Reference model: full pipeline in software
    //  act[8][8], wgt[8][8] → signed INT8
    //  bias[8] → signed INT32
    //  m0 → UINT32,  n_scale → 5-bit
    //  returns expected[8][8] INT8 after RELU
    // ─────────────────────────────────────────────────────────────
    function automatic [7:0] ref_req_sat(
        input longint val,
        input [31:0]  m0,
        input [4:0]   n
    );
        longint mul, shifted;
        mul     = val * longint'({1'b0, m0});
        shifted = mul >>> n;
        if      (shifted >  127) return 8'sh7F;
        else if (shifted < -128) return 8'sh80;
        else                     return shifted[7:0];
    endfunction

    function automatic [7:0] ref_relu(input logic signed [7:0] x);
        return (x < 0) ? 8'sh00 : x;
    endfunction

    task automatic compute_ref(
        ref   logic signed [7:0]  act[8][8],
        ref   logic signed [7:0]  wgt[8][8],
        ref   logic signed [31:0] bias[8],
        input logic [31:0]        m0,
        input logic [4:0]         n_scale,
        ref   logic [7:0]         exp[8][8]   // output
    );
        logic signed [31:0] acc;
        logic signed [31:0] pb;
        logic [7:0]         req_val;
        for (int r = 0; r < 8; r++) begin
            for (int c = 0; c < 8; c++) begin
                // CONV: dot product of ACT row r with WGT col c
                acc = 0;
                for (int k = 0; k < 8; k++)
                    acc = acc + (act[r][k] * wgt[k][c]);
                // ADD_BIAS: bias indexed by column
                pb  = acc + bias[c];
                // REQ + saturate
                req_val = ref_req_sat(longint'(pb), m0, n_scale);
                // RELU
                exp[r][c] = ref_relu(signed'(req_val));
            end
        end
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Checker: read 16 DMEM words, compare to expected[8][8]
    // ─────────────────────────────────────────────────────────────
    task automatic verify_output(
        ref   logic [7:0] exp[8][8],
        input string      suite_name
    );
        logic [31:0] got, exp_w;
        for (int r = 0; r < 8; r++) begin
            // word_lo = {exp[r][3], exp[r][2], exp[r][1], exp[r][0]}
            exp_w = {exp[r][3], exp[r][2], exp[r][1], exp[r][0]};
            dmem_read(OUT_BASE + 2*r, got);
            suite_checks++; total_checks++;
            if (got === exp_w)
                $display("  [PASS] %s row%0d lo  DMEM[%0d] = 0x%08h",
                         suite_name, r, OUT_BASE+2*r, got);
            else begin
                $display("  [FAIL] %s row%0d lo  DMEM[%0d] = 0x%08h  exp=0x%08h",
                         suite_name, r, OUT_BASE+2*r, got, exp_w);
                suite_errors++; total_errors++;
            end

            // word_hi = {exp[r][7], exp[r][6], exp[r][5], exp[r][4]}
            exp_w = {exp[r][7], exp[r][6], exp[r][5], exp[r][4]};
            dmem_read(OUT_BASE + 2*r + 1, got);
            suite_checks++; total_checks++;
            if (got === exp_w)
                $display("  [PASS] %s row%0d hi  DMEM[%0d] = 0x%08h",
                         suite_name, r, OUT_BASE+2*r+1, got);
            else begin
                $display("  [FAIL] %s row%0d hi  DMEM[%0d] = 0x%08h  exp=0x%08h",
                         suite_name, r, OUT_BASE+2*r+1, got, exp_w);
                suite_errors++; total_errors++;
            end
        end
    endtask

    // Print suite result summary
    task automatic suite_summary(input string name);
        $display("[%0t] --- Suite '%s': checks=%0d errors=%0d %s",
                 $time, name, suite_checks, suite_errors,
                 (suite_errors==0) ? "PASS" : "FAIL <<<");
        suite_errors = 0;
        suite_checks = 0;
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Internal buffer dump helpers (identical to original TB)
    // ─────────────────────────────────────────────────────────────
    task automatic dump_preq(input string tag);
        $display("[%0t] %s preq_buffer (INT8):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h", r,
                dut.u_preq_buf.mem[r][0], dut.u_preq_buf.mem[r][1],
                dut.u_preq_buf.mem[r][2], dut.u_preq_buf.mem[r][3],
                dut.u_preq_buf.mem[r][4], dut.u_preq_buf.mem[r][5],
                dut.u_preq_buf.mem[r][6], dut.u_preq_buf.mem[r][7]);
    endtask

    task automatic dump_relu(input string tag);
        $display("[%0t] %s relu_buffer (INT8):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h", r,
                dut.u_relu_buf.mem[r][0], dut.u_relu_buf.mem[r][1],
                dut.u_relu_buf.mem[r][2], dut.u_relu_buf.mem[r][3],
                dut.u_relu_buf.mem[r][4], dut.u_relu_buf.mem[r][5],
                dut.u_relu_buf.mem[r][6], dut.u_relu_buf.mem[r][7]);
    endtask

    task automatic dump_acc(input string tag);
        $display("[%0t] %s acc_buffer (INT32):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %08h %08h %08h %08h %08h %08h %08h %08h", r,
                dut.u_acc_buf.mem[r][0], dut.u_acc_buf.mem[r][1],
                dut.u_acc_buf.mem[r][2], dut.u_acc_buf.mem[r][3],
                dut.u_acc_buf.mem[r][4], dut.u_acc_buf.mem[r][5],
                dut.u_acc_buf.mem[r][6], dut.u_acc_buf.mem[r][7]);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Watchdog
    // ─────────────────────────────────────────────────────────────
    initial begin
        #(CLK_PERIOD * 500_000);
        $display("\n[%0t] *** WATCHDOG TIMEOUT ***", $time);
        total_errors++;
        $finish;
    end

    // ─────────────────────────────────────────────────────────────
    //  Live EXEC monitor
    // ─────────────────────────────────────────────────────────────
    initial begin
        forever begin
            @(posedge clk);
            if (rst_n && dut.cu.state == dut.cu.EXECUTE && dut.cu.exec_pulse)
                $display("[%0t] EXEC PC=%0d opcode=%b",
                         $time, dut.cu.PC, dut.cu.opcode);
        end
    end

    // =========================================================
    //  DATA DECLARATIONS  (used across all suites)
    // =========================================================
    logic signed [7:0]  act[8][8];
    logic signed [7:0]  wgt[8][8];
    logic signed [31:0] bias[8];
    logic        [7:0]  exp[8][8];
    logic        [31:0] m0;
    logic        [4:0]  ns;

    // =========================================================
    //  SUITE 0 — Original 3-iteration test (identity weight)
    // =========================================================
    // (Reproduced from the original TB in a self-contained block)
    localparam int S0_ITERS = 3;
    int    s0_act_base[S0_ITERS], s0_wgt_base[S0_ITERS];
    int    s0_bias_base[S0_ITERS], s0_scl_base[S0_ITERS];
    int    s0_out_base[S0_ITERS];
    logic [7:0] s0_exp[S0_ITERS][8][8];

    function automatic [7:0] s0_act_pat(input int it, input int r, input int c);
        case (it)
            0: return 8'd1;
            1: return 8'(c + 1);
            2: return 8'((r + c) & 8'h7F);
            default: return 8'd0;
        endcase
    endfunction

    function automatic [7:0] s0_wgt_pat(input int r, input int c);
        return (r == c) ? 8'd1 : 8'd0;   // identity
    endfunction

    task automatic suite0();
        int s0_pc;
        $display("\n================================================================");
        $display(" SUITE 0 — Original 3-iteration test (identity weight, +ve ACT)");
        $display("================================================================");

        // Memory map (identical to original TB)
        s0_act_base[0] =   0; s0_wgt_base[0] =  16; s0_bias_base[0] = 32;
        s0_scl_base[0] =  40; s0_out_base[0] =  64;
        s0_act_base[1] =  80; s0_wgt_base[1] =  96; s0_bias_base[1] =112;
        s0_scl_base[1] = 120; s0_out_base[1] = 144;
        s0_act_base[2] = 160; s0_wgt_base[2] = 176; s0_bias_base[2] =192;
        s0_scl_base[2] = 200; s0_out_base[2] = 224;

        // Expected = act_pattern (identity weight, zero bias, identity rescale)
        for (int it=0;it<S0_ITERS;it++)
            for (int r=0;r<8;r++)
                for (int c=0;c<8;c++)
                    s0_exp[it][r][c] = s0_act_pat(it,r,c);

        // Load tensors
        for (int it=0;it<S0_ITERS;it++) begin
            $display("[%0t] Loading tensors iter %0d", $time, it);
            for (int r=0;r<8;r++) begin
                logic [31:0] wlo, whi;
                wlo={s0_act_pat(it,r,3),s0_act_pat(it,r,2),s0_act_pat(it,r,1),s0_act_pat(it,r,0)};
                whi={s0_act_pat(it,r,7),s0_act_pat(it,r,6),s0_act_pat(it,r,5),s0_act_pat(it,r,4)};
                dmem_write(s0_act_base[it]+2*r,   wlo);
                dmem_write(s0_act_base[it]+2*r+1, whi);
                wlo={s0_wgt_pat(r,3),s0_wgt_pat(r,2),s0_wgt_pat(r,1),s0_wgt_pat(r,0)};
                whi={s0_wgt_pat(r,7),s0_wgt_pat(r,6),s0_wgt_pat(r,5),s0_wgt_pat(r,4)};
                dmem_write(s0_wgt_base[it]+2*r,   wlo);
                dmem_write(s0_wgt_base[it]+2*r+1, whi);
            end
            for (int b=0;b<8;b++) dmem_write(s0_bias_base[it]+b, 32'd0);
            dmem_write(s0_scl_base[it], M0_IDENT);
        end

        // Program: 9×3 + HALT = 28 instructions
        s0_pc = 0;
        for (int it=0;it<S0_ITERS;it++) begin
            imem_write(s0_pc++, enc_ls(OP_LOAD_ACT, 4'd0,6'd0,8'd0,8'(s0_act_base[it])));
            imem_write(s0_pc++, enc_ls(OP_LOAD_WGT, 4'd0,6'd0,8'd0,8'(s0_wgt_base[it])));
            imem_write(s0_pc++, enc_ls(OP_LOAD_BIAS,4'd0,6'd0,8'd0,8'(s0_bias_base[it])));
            imem_write(s0_pc++, enc_ls(OP_LOAD_SCL, 4'd0,6'd0,8'd0,8'(s0_scl_base[it])));
            imem_write(s0_pc++, enc_cmp(OP_CONV,    1'b0,5'd0, 1'b0));
            imem_write(s0_pc++, enc_cmp(OP_ADD_BIAS,1'b0,5'd0, 1'b0));
            imem_write(s0_pc++, enc_cmp(OP_REQ,     1'b0,NS_IDENT,1'b0));
            imem_write(s0_pc++, enc_cmp(OP_RELU,    1'b0,5'd0, 1'b0));
            imem_write(s0_pc++, enc_ls(OP_STORE,    4'd1,6'd0,8'd0,8'(s0_out_base[it])));
        end
        imem_write(s0_pc++, {OP_HALT,26'd0});

        run_npu(50_000);

        for (int it=0;it<S0_ITERS;it++) begin
            $display("\n[%0t] === Verifying iter %0d output @ DMEM[%0d..%0d] ===",
                     $time, it, s0_out_base[it], s0_out_base[it]+15);
            for (int r=0;r<8;r++) begin
                logic [31:0] got, exp_lo, exp_hi;
                exp_lo={s0_exp[it][r][3],s0_exp[it][r][2],s0_exp[it][r][1],s0_exp[it][r][0]};
                exp_hi={s0_exp[it][r][7],s0_exp[it][r][6],s0_exp[it][r][5],s0_exp[it][r][4]};
                dmem_read(s0_out_base[it]+2*r,   got);
                suite_checks++; total_checks++;
                if (got===exp_lo)
                    $display("  [PASS] iter%0d row%0d lo  DMEM[%0d]=0x%08h",it,r,s0_out_base[it]+2*r,got);
                else begin
                    $display("  [FAIL] iter%0d row%0d lo  DMEM[%0d]=0x%08h exp=0x%08h",it,r,s0_out_base[it]+2*r,got,exp_lo);
                    suite_errors++; total_errors++;
                end
                dmem_read(s0_out_base[it]+2*r+1, got);
                suite_checks++; total_checks++;
                if (got===exp_hi)
                    $display("  [PASS] iter%0d row%0d hi  DMEM[%0d]=0x%08h",it,r,s0_out_base[it]+2*r+1,got);
                else begin
                    $display("  [FAIL] iter%0d row%0d hi  DMEM[%0d]=0x%08h exp=0x%08h",it,r,s0_out_base[it]+2*r+1,got,exp_hi);
                    suite_errors++; total_errors++;
                end
            end
        end
        suite_summary("SUITE0-original-3iter");
    endtask

    // =========================================================
    //  SUITE 1 — All-negative ACT → ReLU clips to zero
    //  ACT[r][c] = -(c+1)  (−1..−8)
    //  WGT = identity,  bias = 0,  M0 = 2^30, n = 30
    //  CONV output = -(c+1) per element (diagonal weight)
    //  After REQ: still negative  →  ReLU → 0
    //  Expected output: all zeros
    // =========================================================
    task automatic suite1_neg_act_relu_clip();
        $display("\n================================================================");
        $display(" SUITE 1 — Negative ACT: all values clipped to 0 by ReLU");
        $display("================================================================");
        do_reset();

        // Fill ACT: row r, col c = -(c+1)
        for (int r=0;r<8;r++) begin
            for (int c=0;c<8;c++) act[r][c] = signed'(8'(-(c+1)));
        end
        // Identity WGT
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        // Zero bias, identity scale
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        // Expected: all zero (negative inputs → ReLU clips)
        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected output (should be all 0x00):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite1 after REQ "); dump_relu("Suite1 after RELU");
        verify_output(exp, "S1-neg-relu");
        suite_summary("SUITE1-negative-ACT-relu-clip");
    endtask

    // =========================================================
    //  SUITE 2 — Zero ACT + positive bias lifts output
    //  ACT = 0, WGT = identity, bias[c] = 16*(c+1)
    //  CONV = 0, add_bias = 16*(c+1)
    //  REQ(M0=2^30,n=30) → identity → 16*(c+1)
    //  ReLU: all positive → unchanged
    //  Expected[r][c] = min(16*(c+1), 127)
    // =========================================================
    task automatic suite2_zero_act_bias_lift();
        $display("\n================================================================");
        $display(" SUITE 2 — Zero ACT with positive bias: bias lifts output");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd0;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'(16*(c+1));   // 16,32,48,...,128
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected output:");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite2 after REQ "); dump_relu("Suite2 after RELU");
        verify_output(exp, "S2-bias-lift");
        suite_summary("SUITE2-zero-ACT-bias-lift");
    endtask

    // =========================================================
    //  SUITE 3 — Negative ACT + positive bias cancel/net positive
    //  ACT[r][c] = -4 (all rows/cols)
    //  WGT = identity
    //  CONV[r][c] = -4
    //  bias[c] = +32
    //  add_bias → 28
    //  REQ(ident) → 28  ReLU → 28
    //  Expected: all 0x1C (28)
    // =========================================================
    task automatic suite3_neg_act_pos_bias();
        $display("\n================================================================");
        $display(" SUITE 3 — Negative ACT + positive bias: net positive output");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = -8'sd4;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd32;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected output (all 0x1C = 28):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite3 after REQ "); dump_relu("Suite3 after RELU");
        verify_output(exp, "S3-neg+bias");
        suite_summary("SUITE3-neg-ACT-pos-bias-cancel");
    endtask

    // =========================================================
    //  SUITE 4 — REQ saturation: output clamped to 127
    //  ACT = 127, WGT = identity
    //  CONV = 127, bias = 0
    //  REQ(M0=2^30, n=30) → 127 (no clamp needed, just at limit)
    //  Then also test ACT=127, all-ones WGT:
    //    CONV = sum_k(127*1) = 8*127=1016 → REQ → clamped to 127
    // =========================================================
    task automatic suite4_req_saturation();
        $display("\n================================================================");
        $display(" SUITE 4A — REQ: ACT=127, identity WGT → output exactly 127");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd127;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        verify_output(exp, "S4A-clamp127");
        suite_summary("SUITE4A-REQ-clamp-at-127");

        // ── Suite 4B: all-ones WGT, sum overflows → clamp ───
        $display("\n================================================================");
        $display(" SUITE 4B — REQ: ACT=127, all-ones WGT → CONV=1016 → clamped 127");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd127;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = 8'd1;  // all ones
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] CONV[r][c] = 8*127 = 1016 → REQ → saturated 127:");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite4B after CONV");
        verify_output(exp, "S4B-clamp127");
        suite_summary("SUITE4B-REQ-overflow-clamp");
    endtask

    // =========================================================
    //  SUITE 5 — Mixed-sign rows
    //  Even rows (0,2,4,6): ACT = +5 → after ReLU = 5
    //  Odd  rows (1,3,5,7): ACT = -5 → after ReLU = 0
    //  WGT = identity, bias = 0, identity rescale
    // =========================================================
    task automatic suite5_mixed_sign_rows();
        $display("\n================================================================");
        $display(" SUITE 5 — Mixed-sign rows: even=+5 pass, odd=-5 clipped to 0");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++)
            for (int c=0;c<8;c++)
                act[r][c] = (r % 2 == 0) ? 8'sd5 : -8'sd5;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (even rows=0x05, odd rows=0x00):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite5 after REQ "); dump_relu("Suite5 after RELU");
        verify_output(exp, "S5-mixed-sign");
        suite_summary("SUITE5-mixed-sign-rows");
    endtask

    // =========================================================
    //  SUITE 6 — All zeros: ACT=0, WGT=0, bias=0
    //  Expected: all zeros throughout
    // =========================================================
    task automatic suite6_all_zeros();
        $display("\n================================================================");
        $display(" SUITE 6 — All-zeros: ACT=0, WGT=0, bias=0 → output all zero");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd0;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        verify_output(exp, "S6-all-zeros");
        suite_summary("SUITE6-all-zeros");
    endtask

    // =========================================================
    //  SUITE 7 — All-ones WGT + uniform ACT
    //  ACT[r][c] = 1, WGT[r][c] = 1
    //  CONV[r][c] = sum_k(1*1) = 8
    //  bias=0, M0=2^30, n=30 → REQ=8, ReLU=8
    //  Expected: all 0x08
    // =========================================================
    task automatic suite7_all_ones_wgt();
        $display("\n================================================================");
        $display(" SUITE 7 — All-ones WGT: CONV=8 per element → output 0x08");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd1;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = 8'sd1;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x08):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite7 after CONV");
        verify_output(exp, "S7-all-ones-wgt");
        suite_summary("SUITE7-all-ones-WGT");
    endtask

    // =========================================================
    //  SUITE 8 — n_scale shift: ACT=16, WGT=identity
    //  CONV=16, bias=0
    //  Test n_scale=0,1,2,3,4 → REQ = 16>>0=16, >>1=8, >>2=4, >>3=2, >>4=1
    //  (M0=2^30 with n=30+k equivalent, or simpler: M0=1, n=k)
    //  We use M0=1 (UINT32=1), n_scale=k:
    //    REQ: (16 * 1) >>> k = 16 >> k
    // =========================================================
    task automatic suite8_nscale_sweep();
        int exp_val;
        $display("\n================================================================");
        $display(" SUITE 8 — n_scale sweep: ACT=16, WGT=identity, M0=1, n=0..4");
        $display("================================================================");

        for (int k=0; k<=4; k++) begin
            do_reset();
            $display("\n  [n_scale=%0d] expected output = %0d (0x%02h)", k, 16>>k, 16>>k);

            for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd16;
            for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
            for (int c=0;c<8;c++) bias[c] = 32'sd0;
            m0 = 32'd1;              // M0 = 1
            ns = 5'(k);              // n_scale = k

            compute_ref(act, wgt, bias, m0, ns, exp);
            write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
            load_single_iter_program(ns);
            run_npu(20_000);
            verify_output(exp, $sformatf("S8-n=%0d", k));
        end
        suite_summary("SUITE8-nscale-sweep");
    endtask

    // =========================================================
    //  SUITE 9 — Negative bias brings positive ACT below zero
    //  ACT=+3, WGT=identity → CONV=3
    //  bias=-10 → add_bias = 3-10 = -7
    //  REQ(ident) → -7  ReLU → 0
    //  Expected: all zero
    // =========================================================
    task automatic suite9_pos_act_neg_bias();
        $display("\n================================================================");
        $display(" SUITE 9 — Positive ACT + negative bias → below zero → ReLU=0");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd3;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = -32'sd10;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x00 — net=-7, clipped by ReLU):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite9 after REQ "); dump_relu("Suite9 after RELU");
        verify_output(exp, "S9-pos+neg-bias");
        suite_summary("SUITE9-pos-ACT-neg-bias-relu-0");
    endtask

    // =========================================================
    //  SUITE 10 — INT8_MIN saturation: ACT=-128, WGT=identity
    //  CONV=-128, bias=0 → REQ=-128 (clamped at INT8_MIN)
    //  ReLU → 0
    // =========================================================
    task automatic suite10_int8_min();
        $display("\n================================================================");
        $display(" SUITE 10 — INT8_MIN: ACT=-128, WGT=identity → REQ=-128 → ReLU=0");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = -8'sd128;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x00 — ReLU clips -128 to 0):");
        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite10 after REQ");
        verify_output(exp, "S10-INT8_MIN");
        suite_summary("SUITE10-INT8_MIN-relu-zero");
    endtask

    // =========================================================
    //  SUITE 11 — Back-to-back runs without reloading IMEM
    //  Run the same program twice (NPU reset between runs).
    //  Both runs should produce identical output.
    // =========================================================
    task automatic suite11_back_to_back();
        $display("\n================================================================");
        $display(" SUITE 11 — Back-to-back runs (same IMEM, NPU reset between)");
        $display("================================================================");
        do_reset();

        // ACT=2, WGT=identity, bias=0 → output=2 everywhere
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd2;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);

        // Run 1
        $display("[%0t] --- Run 1 ---", $time);
        run_npu(20_000);
        verify_output(exp, "S11-run1");

        // Reset + run 2 (IMEM/DMEM survive reset)
        do_reset();
        $display("[%0t] --- Run 2 (after reset, same IMEM/DMEM) ---", $time);
        run_npu(20_000);
        verify_output(exp, "S11-run2");

        suite_summary("SUITE11-back-to-back");
    endtask

    // =========================================================
    //  SUITE 12 — Checkerboard ACT pattern
    //  ACT[r][c] = +8 if (r+c) even, -8 if (r+c) odd
    //  WGT = identity → CONV[r][c] = act[r][c]
    //  bias = 0, identity rescale
    //  ReLU: even positions → 8, odd positions → 0
    // =========================================================
    task automatic suite12_checkerboard();
        $display("\n================================================================");
        $display(" SUITE 12 — Checkerboard pattern: +8/-8 alternate");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++)
            for (int c=0;c<8;c++)
                act[r][c] = ((r+c) % 2 == 0) ? 8'sd8 : -8'sd8;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (checkerboard 0x08/0x00):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        verify_output(exp, "S12-checkerboard");
        suite_summary("SUITE12-checkerboard");
    endtask

    // =========================================================
    //  SUITE 13 — Diagonal weight selects single column of ACT
    //  ACT[r][c] = r*8 + c + 1  (unique value per cell, all positive)
    //  WGT = identity (W[k][c] = 1 iff k==c)
    //  CONV[r][c] = sum_k ACT[r][k]*W[k][c] = ACT[r][c]
    //  Expected = relu(req(ACT[r][c])) = ACT[r][c] (all small +ve)
    // =========================================================
    task automatic suite13_unique_values();
        $display("\n================================================================");
        $display(" SUITE 13 — Unique ACT values: each cell = r*8+c+1 (identity W)");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++)
            for (int c=0;c<8;c++)
                act[r][c] = 8'((r*8 + c + 1) & 8'h7F); // keep < 128, all +ve
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected = ACT values (passed through unchanged):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        verify_output(exp, "S13-unique");
        suite_summary("SUITE13-unique-cell-values");
    endtask

    // =========================================================
    //  SUITE 14 — All-negative WGT, positive ACT
    //  ACT=1, WGT=-1 (identity pattern but value=-1)
    //  CONV[r][c] = -1 per element (diagonal)
    //  bias=0 → REQ=-1 → ReLU=0
    // =========================================================
    task automatic suite14_neg_wgt();
        $display("\n================================================================");
        $display(" SUITE 14 — Negative WGT (=-1 on diagonal): output=0 after ReLU");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd1;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? -8'sd1 : 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x00 — CONV=-1, ReLU clips):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite14 after REQ"); dump_relu("Suite14 after RELU");
        verify_output(exp, "S14-neg-wgt");
        suite_summary("SUITE14-negative-WGT");
    endtask


    // =========================================================
    //  SUITE 15 — DMEM Write-Back Integrity
    //  Purpose : verify that STORE writes only to OUT_BASE..
    //            OUT_BASE+15 and does not corrupt adjacent words.
    //  Method  : fill the entire DMEM area around OUT_BASE with a
    //            known sentinel (0xDEADBEEF) via host bus before
    //            running the NPU.  After STORE, read back every
    //            word in OUT_BASE±8 and verify:
    //              - words inside [OUT_BASE..OUT_BASE+15] match exp
    //              - words outside that window still hold sentinel
    // =========================================================
    task automatic suite15_store_isolation();
        logic [31:0] got;
        logic [31:0] sentinel;
        int lo_guard, hi_guard;
        sentinel  = 32'hDEAD_BEEF;
        lo_guard  = OUT_BASE - 8;   // 8 words before output
        hi_guard  = OUT_BASE + 16;  // first word after output tile

        $display("\n================================================================");
        $display(" SUITE 15 — DMEM write-back isolation (sentinel around OUT_BASE)");
        $display("================================================================");
        do_reset();

        // ACT=3, WGT=identity, bias=0 → output=3 everywhere
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd3;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;
        compute_ref(act, wgt, bias, m0, ns, exp);

        // Load ACT/WGT/BIAS/SCL into their standard addresses
        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);

        // Paint sentinel over guard region (avoids touching ACT/WGT/BIAS areas)
        for (int a = lo_guard; a < hi_guard + 8; a++)
            dmem_write(a, sentinel);

        load_single_iter_program(ns);
        run_npu(20_000);

        // ── Check guard words BELOW output region ───────────────
        $display("[S15] Checking lo-guard words [%0d..%0d] — must still be sentinel",
                 lo_guard, OUT_BASE-1);
        for (int a = lo_guard; a < OUT_BASE; a++) begin
            dmem_read(a, got);
            suite_checks++; total_checks++;
            if (got === sentinel)
                $display("  [PASS] guard DMEM[%0d] = 0x%08h (untouched)", a, got);
            else begin
                $display("  [FAIL] guard DMEM[%0d] = 0x%08h  exp=0x%08h (CLOBBERED!)",
                         a, got, sentinel);
                suite_errors++; total_errors++;
            end
        end

        // ── Check output words match expected ───────────────────
        $display("[S15] Checking output words [%0d..%0d] — must match NPU output",
                 OUT_BASE, OUT_BASE+15);
        verify_output(exp, "S15-store-isolation");

        // ── Check guard words ABOVE output region ───────────────
        $display("[S15] Checking hi-guard words [%0d..%0d] — must still be sentinel",
                 hi_guard, hi_guard+7);
        for (int a = hi_guard; a < hi_guard + 8; a++) begin
            dmem_read(a, got);
            suite_checks++; total_checks++;
            if (got === sentinel)
                $display("  [PASS] guard DMEM[%0d] = 0x%08h (untouched)", a, got);
            else begin
                $display("  [FAIL] guard DMEM[%0d] = 0x%08h  exp=0x%08h (CLOBBERED!)",
                         a, got, sentinel);
                suite_errors++; total_errors++;
            end
        end

        suite_summary("SUITE15-store-isolation");
    endtask

    // =========================================================
    //  SUITE 16 — DMEM Byte-Enable (partial-byte write)
    //  Purpose : verify the host DMEM write port's byte-enable
    //            (dmem_wr_be) works correctly.
    //  Method  :
    //    Step 1 – write 0xFFFFFFFF to a scratch word (addr=100).
    //    Step 2 – write 0x00000000 with be=4'b0101 (bytes 0 & 2).
    //    Step 3 – read back; expect 0xFF00FF00 (bytes 1 & 3 kept).
    //    Step 4 – write 0x12345678 with be=4'b1010 (bytes 1 & 3).
    //    Step 5 – read back; expect 0x12FF34FF (mix of all writes).
    // =========================================================
    task automatic suite16_byte_enable();
        logic [31:0] got;
        int addr;
        addr = 100;

        $display("\n================================================================");
        $display(" SUITE 16 — DMEM byte-enable (partial-byte host writes)");
        $display("================================================================");
        do_reset();

        // ── Step 1: fill with all-ones ──────────────────────────
        @(posedge clk);
        load_dmem    <= 1'b1;
        dmem_wr_addr <= addr[SRAM_ADDR_W-1:0];
        dmem_wr_data <= 32'hFFFF_FFFF;
        dmem_wr_be   <= 4'hF;
        dmem_wr_en   <= 1'b1;
        @(posedge clk);
        dmem_wr_en <= 1'b0; dmem_wr_be <= 4'h0; load_dmem <= 1'b0;

        // ── Step 2: write 0x00 to bytes 0 and 2 only ───────────
        @(posedge clk);
        load_dmem    <= 1'b1;
        dmem_wr_addr <= addr[SRAM_ADDR_W-1:0];
        dmem_wr_data <= 32'h0000_0000;
        dmem_wr_be   <= 4'b0101;           // bytes 0 and 2
        dmem_wr_en   <= 1'b1;
        @(posedge clk);
        dmem_wr_en <= 1'b0; dmem_wr_be <= 4'h0; load_dmem <= 1'b0;

        // ── Step 3: read back and check ────────────────────────
        dmem_read(addr, got);
        suite_checks++; total_checks++;
        if (got === 32'hFF00_FF00) begin
            $display("  [PASS] S16 step2: DMEM[%0d]=0x%08h (bytes 0,2 zeroed; 1,3 kept 0xFF)",
                     addr, got);
        end else begin
            $display("  [FAIL] S16 step2: DMEM[%0d]=0x%08h  exp=0xFF00FF00", addr, got);
            suite_errors++; total_errors++;
        end

        // ── Step 4: write 0x12345678 to bytes 1 and 3 only ─────
        @(posedge clk);
        load_dmem    <= 1'b1;
        dmem_wr_addr <= addr[SRAM_ADDR_W-1:0];
        dmem_wr_data <= 32'h1234_5678;
        dmem_wr_be   <= 4'b1010;           // bytes 1 and 3
        dmem_wr_en   <= 1'b1;
        @(posedge clk);
        dmem_wr_en <= 1'b0; dmem_wr_be <= 4'h0; load_dmem <= 1'b0;

        // ── Step 5: read back and check ─────────────────────────
        // data=0x12345678: byte3=0x12, byte2=0x34, byte1=0x56, byte0=0x78
        // be=1010: be[3]=1→write byte3=0x12, be[1]=1→write byte1=0x56
        // prior state: byte3=0x00(from step2), byte2=0x00, byte1=0x00, byte0=0x00
        // result: {0x12, 0x00, 0x56, 0x00} = 0x12005600
        dmem_read(addr, got);
        suite_checks++; total_checks++;
        if (got === 32'h1200_5600) begin
            $display("  [PASS] S16 step4: DMEM[%0d]=0x%08h (byte-enable merge correct)",
                     addr, got);
        end else begin
            $display("  [FAIL] S16 step4: DMEM[%0d]=0x%08h  exp=0x12005600", addr, got);
            suite_errors++; total_errors++;
        end

        suite_summary("SUITE16-byte-enable");
    endtask

    // =========================================================
    //  SUITE 17 — DMEM Host Read-After-Write (no NPU run)
    //  Purpose : confirm DMEM correctly stores and returns values
    //            written via the host bus even when the NPU never
    //            runs — pure memory persistence test.
    //  Method  : write a unique 32-bit word to every DMEM address
    //            in range [80..95], then read all back and compare.
    // =========================================================
    task automatic suite17_dmem_raw();
        logic [31:0] got;
        logic [31:0] pattern[16];
        int base;
        base = 80;

        $display("\n================================================================");
        $display(" SUITE 17 — DMEM host read-after-write (16 unique words, no NPU)");
        $display("================================================================");
        do_reset();

        // Build and write unique patterns
        for (int i = 0; i < 16; i++) begin
            pattern[i] = 32'hA000_0000 | (32'(i) << 16) | 32'hBEEF;
            dmem_write(base + i, pattern[i]);
        end

        // Read back and verify every word
        for (int i = 0; i < 16; i++) begin
            dmem_read(base + i, got);
            suite_checks++; total_checks++;
            if (got === pattern[i])
                $display("  [PASS] S17 DMEM[%0d] = 0x%08h", base+i, got);
            else begin
                $display("  [FAIL] S17 DMEM[%0d] = 0x%08h  exp=0x%08h",
                         base+i, got, pattern[i]);
                suite_errors++; total_errors++;
            end
        end

        suite_summary("SUITE17-dmem-host-raw");
    endtask

    // =========================================================
    //  SUITE 18 — DMEM Address Boundary
    //  Purpose : exercise lowest (addr=0) and highest (addr=255)
    //            DMEM locations via host read/write.
    //  Method  : write distinctive values to addr 0, 1, 254, 255;
    //            read back and verify; these addresses sit at the
    //            physical boundaries of the 256-word SRAM.
    // =========================================================
    task automatic suite18_dmem_boundary();
        logic [31:0] got;
        $display("\n================================================================");
        $display(" SUITE 18 — DMEM address boundary (addr 0,1,254,255)");
        $display("================================================================");
        do_reset();

        // Write boundary words
        dmem_write(  0, 32'hCAFE_0000);
        dmem_write(  1, 32'hCAFE_0001);
        dmem_write(254, 32'hCAFE_00FE);
        dmem_write(255, 32'hCAFE_00FF);

        // Read back and check
        begin
            // addr 0
            dmem_read(0, got); suite_checks++; total_checks++;
            if (got === 32'hCAFE_0000) $display("  [PASS] S18 DMEM[  0] = 0x%08h", got);
            else begin $display("  [FAIL] S18 DMEM[  0] = 0x%08h exp=0xCAFE0000", got);
                       suite_errors++; total_errors++; end
            // addr 1
            dmem_read(1, got); suite_checks++; total_checks++;
            if (got === 32'hCAFE_0001) $display("  [PASS] S18 DMEM[  1] = 0x%08h", got);
            else begin $display("  [FAIL] S18 DMEM[  1] = 0x%08h exp=0xCAFE0001", got);
                       suite_errors++; total_errors++; end
            // addr 254
            dmem_read(254, got); suite_checks++; total_checks++;
            if (got === 32'hCAFE_00FE) $display("  [PASS] S18 DMEM[254] = 0x%08h", got);
            else begin $display("  [FAIL] S18 DMEM[254] = 0x%08h exp=0xCAFE00FE", got);
                       suite_errors++; total_errors++; end
            // addr 255
            dmem_read(255, got); suite_checks++; total_checks++;
            if (got === 32'hCAFE_00FF) $display("  [PASS] S18 DMEM[255] = 0x%08h", got);
            else begin $display("  [FAIL] S18 DMEM[255] = 0x%08h exp=0xCAFE00FF", got);
                       suite_errors++; total_errors++; end
        end

        suite_summary("SUITE18-dmem-boundary");
    endtask

    // =========================================================
    //  SUITE 19 — Dual-Store: two tiles to two addresses
    //  Purpose : verify that two CONV→STORE sequences, each
    //            writing to a different output base, produce
    //            independent results and do not alias.
    //  Tile A  : ACT=+4, WGT=identity, bias=0  → output=4 @ OUT_BASE
    //  Tile B  : ACT=+9, WGT=identity, bias=0  → output=9 @ OUT_BASE+32
    //  Program : LOAD_A→CONV→STORE_A → LOAD_B→CONV→STORE_B → HALT
    //            (single IMEM program, two compute+store cycles)
    // =========================================================
    localparam int OUT_BASE_B = OUT_BASE + 32;  // second tile output @ word 96

    task automatic suite19_dual_store();
        logic [7:0]  exp_a[8][8], exp_b[8][8];
        logic signed [7:0]  act_a[8][8], act_b[8][8];
        logic signed [7:0]  wgt_a[8][8], wgt_b[8][8];
        logic signed [31:0] bias_z[8];
        logic [31:0] got, exp_w;
        logic [31:0] wlo, whi;
        int pc;
        localparam int ACT_B  = 128;
        localparam int WGT_B  = 144;
        localparam int BIAS_B = 160;
        localparam int SCL_B  = 168;

        $display("\n================================================================");
        $display(" SUITE 19 — Dual-store: two CONV+STORE tiles in one program");
        $display("================================================================");
        do_reset();

        // Tile A: ACT=4, WGT=identity
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act_a[r][c] = 8'sd4;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt_a[r][c] = (r==c) ? 8'd1 : 8'd0;
        // Tile B: ACT=9, WGT=identity
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act_b[r][c] = 8'sd9;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt_b[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias_z[c] = 32'sd0;

        compute_ref(act_a, wgt_a, bias_z, M0_IDENT, NS_IDENT, exp_a);
        compute_ref(act_b, wgt_b, bias_z, M0_IDENT, NS_IDENT, exp_b);

        // Write Tile A
        for (int r=0;r<8;r++) begin
            wlo={act_a[r][3],act_a[r][2],act_a[r][1],act_a[r][0]};
            whi={act_a[r][7],act_a[r][6],act_a[r][5],act_a[r][4]};
            dmem_write(ACT_BASE+2*r,   wlo); dmem_write(ACT_BASE+2*r+1, whi);
            wlo={wgt_a[r][3],wgt_a[r][2],wgt_a[r][1],wgt_a[r][0]};
            whi={wgt_a[r][7],wgt_a[r][6],wgt_a[r][5],wgt_a[r][4]};
            dmem_write(WGT_BASE+2*r,   wlo); dmem_write(WGT_BASE+2*r+1, whi);
        end
        for (int b=0;b<8;b++) dmem_write(BIAS_BASE+b, 32'd0);
        dmem_write(SCL_BASE, M0_IDENT);

        // Write Tile B
        for (int r=0;r<8;r++) begin
            wlo={act_b[r][3],act_b[r][2],act_b[r][1],act_b[r][0]};
            whi={act_b[r][7],act_b[r][6],act_b[r][5],act_b[r][4]};
            dmem_write(ACT_B+2*r,   wlo); dmem_write(ACT_B+2*r+1, whi);
            wlo={wgt_b[r][3],wgt_b[r][2],wgt_b[r][1],wgt_b[r][0]};
            whi={wgt_b[r][7],wgt_b[r][6],wgt_b[r][5],wgt_b[r][4]};
            dmem_write(WGT_B+2*r,   wlo); dmem_write(WGT_B+2*r+1, whi);
        end
        for (int b=0;b<8;b++) dmem_write(BIAS_B+b, 32'd0);
        dmem_write(SCL_B, M0_IDENT);

        // Program: A pipeline + store, B pipeline + store, HALT
        pc = 0;
        imem_write(pc++, enc_ls (OP_LOAD_ACT,  4'd0, 6'd0, 8'd0, 8'(ACT_BASE)));
        imem_write(pc++, enc_ls (OP_LOAD_WGT,  4'd0, 6'd0, 8'd0, 8'(WGT_BASE)));
        imem_write(pc++, enc_ls (OP_LOAD_BIAS, 4'd0, 6'd0, 8'd0, 8'(BIAS_BASE)));
        imem_write(pc++, enc_ls (OP_LOAD_SCL,  4'd0, 6'd0, 8'd0, 8'(SCL_BASE)));
        imem_write(pc++, enc_cmp(OP_CONV,      1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_cmp(OP_ADD_BIAS,  1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_cmp(OP_REQ,       1'b0, NS_IDENT, 1'b0));
        imem_write(pc++, enc_cmp(OP_RELU,      1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_ls (OP_STORE,     4'd1, 6'd0, 8'd0, 8'(OUT_BASE)));   // store A
        imem_write(pc++, enc_ls (OP_LOAD_ACT,  4'd0, 6'd0, 8'd0, 8'(ACT_B)));
        imem_write(pc++, enc_ls (OP_LOAD_WGT,  4'd0, 6'd0, 8'd0, 8'(WGT_B)));
        imem_write(pc++, enc_ls (OP_LOAD_BIAS, 4'd0, 6'd0, 8'd0, 8'(BIAS_B)));
        imem_write(pc++, enc_ls (OP_LOAD_SCL,  4'd0, 6'd0, 8'd0, 8'(SCL_B)));
        imem_write(pc++, enc_cmp(OP_CONV,      1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_cmp(OP_ADD_BIAS,  1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_cmp(OP_REQ,       1'b0, NS_IDENT, 1'b0));
        imem_write(pc++, enc_cmp(OP_RELU,      1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_ls (OP_STORE,     4'd1, 6'd0, 8'd0, 8'(OUT_BASE_B))); // store B
        imem_write(pc++, {OP_HALT, 26'd0});

        run_npu(40_000);

        // Verify Tile A @ OUT_BASE
        $display("[S19] Verifying Tile A (ACT=4) @ DMEM[%0d..%0d]", OUT_BASE, OUT_BASE+15);
        for (int r=0;r<8;r++) begin
            exp_w = {exp_a[r][3],exp_a[r][2],exp_a[r][1],exp_a[r][0]};
            dmem_read(OUT_BASE+2*r, got);
            suite_checks++; total_checks++;
            if (got===exp_w)
                $display("  [PASS] S19-A row%0d lo = 0x%08h", r, got);
            else begin
                $display("  [FAIL] S19-A row%0d lo = 0x%08h exp=0x%08h", r, got, exp_w);
                suite_errors++; total_errors++;
            end
            exp_w = {exp_a[r][7],exp_a[r][6],exp_a[r][5],exp_a[r][4]};
            dmem_read(OUT_BASE+2*r+1, got);
            suite_checks++; total_checks++;
            if (got===exp_w)
                $display("  [PASS] S19-A row%0d hi = 0x%08h", r, got);
            else begin
                $display("  [FAIL] S19-A row%0d hi = 0x%08h exp=0x%08h", r, got, exp_w);
                suite_errors++; total_errors++;
            end
        end

        // Verify Tile B @ OUT_BASE_B
        $display("[S19] Verifying Tile B (ACT=9) @ DMEM[%0d..%0d]", OUT_BASE_B, OUT_BASE_B+15);
        for (int r=0;r<8;r++) begin
            exp_w = {exp_b[r][3],exp_b[r][2],exp_b[r][1],exp_b[r][0]};
            dmem_read(OUT_BASE_B+2*r, got);
            suite_checks++; total_checks++;
            if (got===exp_w)
                $display("  [PASS] S19-B row%0d lo = 0x%08h", r, got);
            else begin
                $display("  [FAIL] S19-B row%0d lo = 0x%08h exp=0x%08h", r, got, exp_w);
                suite_errors++; total_errors++;
            end
            exp_w = {exp_b[r][7],exp_b[r][6],exp_b[r][5],exp_b[r][4]};
            dmem_read(OUT_BASE_B+2*r+1, got);
            suite_checks++; total_checks++;
            if (got===exp_w)
                $display("  [PASS] S19-B row%0d hi = 0x%08h", r, got);
            else begin
                $display("  [FAIL] S19-B row%0d hi = 0x%08h exp=0x%08h", r, got, exp_w);
                suite_errors++; total_errors++;
            end
        end

        suite_summary("SUITE19-dual-store");
    endtask

    // =========================================================
    //  SUITE 20 — ACT=+127, WGT=-128, identity pattern
    //  CONV[r][c] = 127 × (-128) = -16256 (large negative)
    //  bias=0  →  REQ → -16256 → saturates at -128 (INT8_MIN)
    //  ReLU clips -128 → 0
    //  Expected: all 0x00
    // =========================================================
    task automatic suite20_pos_act_min_wgt();
        $display("\n================================================================");
        $display(" SUITE 20 — ACT=+127 × WGT=-128 → large negative → ReLU=0");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd127;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? -8'sd128 : 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x00 — large negative CONV, ReLU clips):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite20 after REQ"); dump_relu("Suite20 after RELU");
        verify_output(exp, "S20-maxpos-minwgt");
        suite_summary("SUITE20-pos127-neg128-wgt");
    endtask

    // =========================================================
    //  SUITE 21 — Neg×Neg sign cancellation
    //  ACT=-1, WGT=-1 (identity pattern), bias=0
    //  CONV[r][c] = (-1) × (-1) = +1
    //  REQ(ident) → +1   ReLU → +1
    //  Expected: all 0x01
    // =========================================================
    task automatic suite21_neg_neg_positive();
        $display("\n================================================================");
        $display(" SUITE 21 — ACT=-1 × WGT=-1 → CONV=+1 → ReLU=+1");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = -8'sd1;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? -8'sd1 : 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x01 — neg×neg cancels to positive):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_preq("Suite21 after REQ"); dump_relu("Suite21 after RELU");
        verify_output(exp, "S21-neg-neg");
        suite_summary("SUITE21-neg-neg-positive");
    endtask

    // =========================================================
    //  SUITE 22 — Max accumulator stress test
    //  ACT=127, WGT=127 (all-ones matrix), bias=0
    //  CONV[r][c] = sum_k(127*127) = 8 × 16129 = 129032
    //  This is a 32-bit accumulator stress: 129032 easily fits
    //  in INT32 but must saturate to +127 after REQ.
    //  Expected: all 0x7F
    // =========================================================
    task automatic suite22_max_accumulator();
        $display("\n================================================================");
        $display(" SUITE 22 — Max accumulator stress: ACT=127, WGT=127 all-ones");
        $display("           CONV=8×127²=129032 → REQ saturates to 127");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd127;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = 8'sd127;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x7F — saturated):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite22 after CONV");
        verify_output(exp, "S22-max-acc");
        suite_summary("SUITE22-max-accumulator-stress");
    endtask

    // =========================================================
    //  SUITE 23 — Column-selective bias
    //  ACT=0, WGT=identity, bias[c] = c * 10  (0,10,20,...,70)
    //  CONV = 0, add_bias = c*10
    //  REQ(ident) → c*10 (all fit in INT8 since max=70<127)
    //  ReLU: all positive → unchanged
    //  Expected[r][c] = 10*c  for all rows
    //  Verifies that bias is indexed per-column and independent.
    // =========================================================
    task automatic suite23_column_bias();
        $display("\n================================================================");
        $display(" SUITE 23 — Column-selective bias: bias[c]=c*10, ACT=0");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd0;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'(10*c);   // 0,10,20,30,40,50,60,70
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (col c = 10*c):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        verify_output(exp, "S23-col-bias");
        suite_summary("SUITE23-column-selective-bias");
    endtask

    // =========================================================
    //  SUITE 24 — Negative×Negative large magnitude
    //  ACT=-128, WGT=-128 (identity pattern), bias=0
    //  CONV[r][c] = (-128) × (-128) = +16384  (large positive)
    //  REQ(M0_IDENT,NS_IDENT) → 16384 → saturates at +127
    //  Expected: all 0x7F
    // =========================================================
    task automatic suite24_neg_neg_large();
        $display("\n================================================================");
        $display(" SUITE 24 — ACT=-128 × WGT=-128 → CONV=+16384 → saturates +127");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = -8'sd128;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? -8'sd128 : 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x7F — REQ saturated positive):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite24 after CONV");
        dump_preq("Suite24 after REQ");
        verify_output(exp, "S24-neg-neg-large");
        suite_summary("SUITE24-neg-neg-large-magnitude");
    endtask

    // =========================================================
    //  SUITE 25 — n_scale = 31 (maximum shift)
    //  ACT=127, WGT=identity, bias=0, M0=2^30, n=31
    //  REQ: (127 × 2^30) >> 31 = 127 × 2^30 / 2^31 = 127/2 = 63
    //  (arithmetic right shift of 63.5 truncates to 63)
    //  Expected: all 0x3F (63)
    //  Corner: largest n_scale encoding, tests shift-by-31 path.
    // =========================================================
    task automatic suite25_max_nscale();
        $display("\n================================================================");
        $display(" SUITE 25 — n_scale=31 (max shift): ACT=127 → REQ → 63");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd127;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT;  // 2^30
        ns = 5'd31;     // shift by 31 → 127*2^30 >> 31 = 127/2 = 63

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x3F = 63 — half of 127, truncated):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        verify_output(exp, "S25-nscale31");
        suite_summary("SUITE25-max-nscale-31");
    endtask

    // =========================================================
    //  SUITE 26 — Full matmul with non-identity WGT
    //  WGT = upper-triangular (W[r][c] = 1 if r<=c, else 0)
    //  ACT[r][c] = c + 1  (column-graded: 1,2,3,4,5,6,7,8)
    //  CONV[r][c] = sum_{k=r}^{7} ACT[r][k] * 1
    //             = sum_{k=r}^{7} (k+1) = triangular sum from row r
    //  bias=0, identity rescale.
    //  Golden computed entirely by the software ref model.
    //  Tests that the SA can handle a non-trivial weight matrix.
    // =========================================================
    task automatic suite26_upper_triangular_wgt();
        $display("\n================================================================");
        $display(" SUITE 26 — Full matmul: upper-triangular WGT, column-graded ACT");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'(c + 1);
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r <= c) ? 8'sd1 : 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (triangular sums per row-diagonal block):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite26 after CONV");
        verify_output(exp, "S26-tri-wgt");
        suite_summary("SUITE26-upper-triangular-WGT");
    endtask

    // =========================================================
    //  SUITE 27 — IMEM overwrite: reload different program
    //  Run 1 : ACT=10, identity WGT, n_scale=30 → output=10
    //  Overwrite IMEM with n_scale=1  (M0=1, n=1 → output=5)
    //  Run 2 : same ACT/WGT, but new program with n_scale=1
    //  Expected Run 2 output = 5 (not 10)
    //  Verifies that IMEM can be overwritten between runs and
    //  the CU fetches the new instruction stream.
    // =========================================================
    task automatic suite27_imem_overwrite();
        logic [7:0] exp2[8][8];
        $display("\n================================================================");
        $display(" SUITE 27 — IMEM overwrite: run A (n=30 → out=10), reload, run B (n=1 → out=5)");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd10;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        write_act(act); write_wgt(wgt); write_bias(bias);

        // ── Run A: identity rescale (output = 10) ────────────────
        m0 = M0_IDENT; ns = NS_IDENT;
        dmem_write(SCL_BASE, m0);
        compute_ref(act, wgt, bias, m0, ns, exp);
        load_single_iter_program(ns);

        $display("[%0t] --- Run A (n_scale=30, expected out=10) ---", $time);
        run_npu(20_000);
        verify_output(exp, "S27-runA");

        // ── Overwrite IMEM with n_scale=1, M0=1 (output = 5) ────
        // (10 * 1) >> 1 = 5
        m0 = 32'd1; ns = 5'd1;
        dmem_write(SCL_BASE, m0);
        compute_ref(act, wgt, bias, m0, ns, exp2);

        $display("[%0t] --- Overwriting IMEM (n_scale=1), Run B (expected out=5) ---", $time);
        do_reset();                         // reset NPU back to IDLE so start_npu re-triggers
        write_act(act); write_wgt(wgt); write_bias(bias);
        dmem_write(SCL_BASE, m0);
        load_single_iter_program(ns);   // re-writes IMEM with new n_scale

        run_npu(20_000);

        // Verify using the new expected array
        begin
            logic [31:0] got, ew;
            for (int r=0;r<8;r++) begin
                ew = {exp2[r][3],exp2[r][2],exp2[r][1],exp2[r][0]};
                dmem_read(OUT_BASE+2*r, got);
                suite_checks++; total_checks++;
                if (got===ew)
                    $display("  [PASS] S27-runB row%0d lo = 0x%08h", r, got);
                else begin
                    $display("  [FAIL] S27-runB row%0d lo = 0x%08h exp=0x%08h", r, got, ew);
                    suite_errors++; total_errors++;
                end
                ew = {exp2[r][7],exp2[r][6],exp2[r][5],exp2[r][4]};
                dmem_read(OUT_BASE+2*r+1, got);
                suite_checks++; total_checks++;
                if (got===ew)
                    $display("  [PASS] S27-runB row%0d hi = 0x%08h", r, got);
                else begin
                    $display("  [FAIL] S27-runB row%0d hi = 0x%08h exp=0x%08h", r, got, ew);
                    suite_errors++; total_errors++;
                end
            end
        end
        suite_summary("SUITE27-imem-overwrite");
    endtask

    // =========================================================
    //  SUITE 28 — Store to alternate output base
    //  Same ACT=6, identity WGT, bias=0 computation.
    //  STORE writes to OUT_BASE+32 (word 96) instead of 64.
    //  After NPU completes:
    //    - OUT_BASE+32..OUT_BASE+47 must hold the result.
    //    - OUT_BASE..OUT_BASE+15 must be untouched (sentinel).
    // =========================================================
    localparam int ALT_OUT = OUT_BASE + 32;   // word 96

    task automatic suite28_alt_store_base();
        logic [31:0] got, sentinel2, ew;
        int pc;

        sentinel2 = 32'hFACE_CAFE;

        $display("\n================================================================");
        $display(" SUITE 28 — Store to alternate output base (DMEM[%0d])", ALT_OUT);
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd6;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;
        compute_ref(act, wgt, bias, m0, ns, exp);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);

        // Paint standard output region with sentinel
        for (int a = OUT_BASE; a < OUT_BASE+16; a++)
            dmem_write(a, sentinel2);

        // Build program: same pipeline but STORE to ALT_OUT
        pc = 0;
        imem_write(pc++, enc_ls (OP_LOAD_ACT,  4'd0, 6'd0, 8'd0, 8'(ACT_BASE)));
        imem_write(pc++, enc_ls (OP_LOAD_WGT,  4'd0, 6'd0, 8'd0, 8'(WGT_BASE)));
        imem_write(pc++, enc_ls (OP_LOAD_BIAS, 4'd0, 6'd0, 8'd0, 8'(BIAS_BASE)));
        imem_write(pc++, enc_ls (OP_LOAD_SCL,  4'd0, 6'd0, 8'd0, 8'(SCL_BASE)));
        imem_write(pc++, enc_cmp(OP_CONV,      1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_cmp(OP_ADD_BIAS,  1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_cmp(OP_REQ,       1'b0, ns,   1'b0));
        imem_write(pc++, enc_cmp(OP_RELU,      1'b0, 5'd0, 1'b0));
        imem_write(pc++, enc_ls (OP_STORE,     4'd1, 6'd0, 8'd0, 8'(ALT_OUT)));
        imem_write(pc++, {OP_HALT, 26'd0});

        run_npu(20_000);

        // Verify alt output region has correct values
        $display("[S28] Checking alternate output @ DMEM[%0d..%0d]", ALT_OUT, ALT_OUT+15);
        for (int r=0;r<8;r++) begin
            ew = {exp[r][3],exp[r][2],exp[r][1],exp[r][0]};
            dmem_read(ALT_OUT+2*r, got);
            suite_checks++; total_checks++;
            if (got===ew)
                $display("  [PASS] S28 alt row%0d lo = 0x%08h", r, got);
            else begin
                $display("  [FAIL] S28 alt row%0d lo = 0x%08h exp=0x%08h", r, got, ew);
                suite_errors++; total_errors++;
            end
            ew = {exp[r][7],exp[r][6],exp[r][5],exp[r][4]};
            dmem_read(ALT_OUT+2*r+1, got);
            suite_checks++; total_checks++;
            if (got===ew)
                $display("  [PASS] S28 alt row%0d hi = 0x%08h", r, got);
            else begin
                $display("  [FAIL] S28 alt row%0d hi = 0x%08h exp=0x%08h", r, got, ew);
                suite_errors++; total_errors++;
            end
        end

        // Verify standard output region is still sentinel (STORE did NOT write there)
        $display("[S28] Checking default OUT_BASE region [%0d..%0d] — must be sentinel",
                 OUT_BASE, OUT_BASE+15);
        for (int a = OUT_BASE; a < OUT_BASE+16; a++) begin
            dmem_read(a, got);
            suite_checks++; total_checks++;
            if (got === sentinel2)
                $display("  [PASS] S28 sentinel DMEM[%0d] = 0x%08h (untouched)", a, got);
            else begin
                $display("  [FAIL] S28 sentinel DMEM[%0d] = 0x%08h exp=0x%08h (CLOBBERED!)",
                         a, got, sentinel2);
                suite_errors++; total_errors++;
            end
        end

        suite_summary("SUITE28-alt-store-base");
    endtask

    // =========================================================
    //  SUITE 29 — Zero WGT, non-zero ACT
    //  ACT=127 (all filled), WGT=0 (all zeros), bias[c]=5
    //  CONV = 0 (anything × 0 = 0), add_bias = 5
    //  REQ(ident) → 5,  ReLU → 5
    //  Expected: all 0x05
    //  Corner: verifies WGT=0 truly nullifies the accumulator
    //  regardless of how large ACT is.
    // =========================================================
    task automatic suite29_zero_wgt_nonzero_act();
        $display("\n================================================================");
        $display(" SUITE 29 — Zero WGT, ACT=127: CONV=0, bias=5 → output=5");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++) for (int c=0;c<8;c++) act[r][c] = 8'sd127;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = 8'sd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd5;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (all 0x05 — WGT kills CONV, bias survives):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite29 after CONV");
        verify_output(exp, "S29-zero-wgt");
        suite_summary("SUITE29-zero-WGT-nonzero-ACT");
    endtask

    // =========================================================
    //  SUITE 30 — One-hot ACT rows (sparse activation)
    //  Row r has ACT=1 only in column r, all others 0.
    //  WGT = identity (W[k][c] = 1 iff k==c).
    //  CONV[r][c] = sum_k ACT[r][k]*W[k][c]
    //             = ACT[r][c]*W[c][c] = (r==c) ? 1 : 0
    //  So CONV is the identity matrix itself.
    //  bias=0, REQ=identity, ReLU: all 0 or 1 → unchanged.
    //  Expected[r][c] = (r==c) ? 0x01 : 0x00
    // =========================================================
    task automatic suite30_one_hot_act();
        $display("\n================================================================");
        $display(" SUITE 30 — One-hot ACT rows: CONV = identity matrix output");
        $display("================================================================");
        do_reset();

        for (int r=0;r<8;r++)
            for (int c=0;c<8;c++)
                act[r][c] = (r==c) ? 8'sd1 : 8'sd0;
        for (int r=0;r<8;r++) for (int c=0;c<8;c++) wgt[r][c] = (r==c) ? 8'd1 : 8'd0;
        for (int c=0;c<8;c++) bias[c] = 32'sd0;
        m0 = M0_IDENT; ns = NS_IDENT;

        compute_ref(act, wgt, bias, m0, ns, exp);
        $display("[REF] Expected (identity matrix: diagonal=0x01, rest=0x00):");
        for (int r=0;r<8;r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h",
                r,exp[r][0],exp[r][1],exp[r][2],exp[r][3],
                  exp[r][4],exp[r][5],exp[r][6],exp[r][7]);

        write_act(act); write_wgt(wgt); write_bias(bias); write_scale(m0);
        load_single_iter_program(ns);
        run_npu(20_000);
        dump_acc("Suite30 after CONV");
        verify_output(exp, "S30-one-hot");
        suite_summary("SUITE30-one-hot-ACT-rows");
    endtask

    // =========================================================
    //  Waveform dump
    // =========================================================
    initial begin
        $dumpfile("tb_npu_top_extended.vcd");
        $dumpvars(0, tb_npu_top);
    end

    // =========================================================
    //  MAIN
    // =========================================================
    initial begin
        $display("================================================================");
        $display(" tb_npu_top_extended v2 — Comprehensive NPU Test Suite");
        $display(" Suites 0-30: datapath, memory, corner cases, store isolation");
        $display("================================================================");

        do_reset();

        // ── Original suites ──────────────────────────────────────
        suite0();                     // original 3-iter test
        suite1_neg_act_relu_clip();   // negative ACT → ReLU=0
        suite2_zero_act_bias_lift();  // bias lifts zero ACT output
        suite3_neg_act_pos_bias();    // negative ACT cancelled by bias
        suite4_req_saturation();      // REQ saturate to 127 (A and B)
        suite5_mixed_sign_rows();     // even rows +, odd rows -
        suite6_all_zeros();           // zero propagation
        suite7_all_ones_wgt();        // all-ones WGT, CONV=8
        suite8_nscale_sweep();        // n_scale 0..4 shift sweep
        suite9_pos_act_neg_bias();    // positive ACT pulled below 0
        suite10_int8_min();           // INT8_MIN = -128 → ReLU=0
        suite11_back_to_back();       // back-to-back with reset
        suite12_checkerboard();       // checkerboard ±8 pattern
        suite13_unique_values();      // each cell unique, identity W
        suite14_neg_wgt();            // negative diagonal weight

        // ── New memory & datapath suites ─────────────────────────
        suite15_store_isolation();    // STORE only touches OUT_BASE window
        suite16_byte_enable();        // DMEM partial-byte write (be pins)
        suite17_dmem_raw();           // DMEM host read-after-write, no NPU
        suite18_dmem_boundary();      // DMEM addr 0, 1, 254, 255 boundary
        suite19_dual_store();         // two CONV+STORE tiles, one program
        suite20_pos_act_min_wgt();    // +127 × -128 → large neg → ReLU=0
        suite21_neg_neg_positive();   // -1 × -1 = +1 → ReLU=+1
        suite22_max_accumulator();    // 127 × 127 × 8 = 129032 → sat +127
        suite23_column_bias();        // per-column independent bias values
        suite24_neg_neg_large();      // -128 × -128 = +16384 → sat +127
        suite25_max_nscale();         // n_scale=31 → 127/2=63
        suite26_upper_triangular_wgt(); // non-identity WGT, full matmul
        suite27_imem_overwrite();     // IMEM reload between runs
        suite28_alt_store_base();     // STORE to non-default address
        suite29_zero_wgt_nonzero_act(); // WGT=0 kills all CONV; bias alone
        suite30_one_hot_act();        // sparse one-hot ACT → identity CONV

        $display("\n================================================================");
        $display(" FINAL SUMMARY");
        $display(" Total checks : %0d", total_checks);
        $display(" Total errors : %0d", total_errors);
        if (total_errors == 0) $display(" *** ALL SUITES PASSED ***");
        else                   $display(" *** %0d ERROR(S) FOUND ***", total_errors);
        $display("================================================================");

        repeat(5) @(posedge clk);
        $finish;
    end

endmodule