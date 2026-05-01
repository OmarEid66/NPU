// ================================================================
//  tb_npu_top.sv  —  Multi-iteration self-checking testbench
//
//  Memory map (DMEM = 256 × 32-bit words):
//
//    Iter 0:  ACT  [  0.. 15]   16 words
//             WGT  [ 16.. 31]   16 words   (identity)
//             BIAS [ 32.. 39]    8 words   (zeros)
//             SCL  [ 40]         1 word    (M0 = 2^30)
//             OUT  [ 64.. 79]   16 words
//
//    Iter 1:  ACT  [ 80.. 95]
//             WGT  [ 96..111]
//             BIAS [112..119]
//             SCL  [120]
//             OUT  [144..159]
//
//    Iter 2:  ACT  [160..175]
//             WGT  [176..191]
//             BIAS [192..199]
//             SCL  [200]
//             OUT  [224..239]
//
//  All addresses fit in 256-word SRAM, no overlap.
//
//  Program: per-iteration { LOAD_ACT, LOAD_WGT, LOAD_BIAS,
//           LOAD_SCL, CONV, ADD_BIAS, REQ, RELU, STORE } + HALT
//           = 9*N_ITERS + 1 instructions; with N_ITERS=3 → 28 ≤ 32.
//
//  Test patterns (W=identity, bias=0, M0=2^30, n_scale=30):
//    Iter 0: ACT[r][c] = 1
//    Iter 1: ACT[r][c] = c+1   (1..8)
//    Iter 2: ACT[r][c] = (r+c) & 0x7F
//
// ================================================================

`timescale 1ns/1ps

module tb_npu_top;

    // ────────────────────────────────────────────────
    //  Parameters
    // ────────────────────────────────────────────────
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

    localparam int N_ITERS = 3;

    int act_base [N_ITERS];
    int wgt_base [N_ITERS];
    int bias_base[N_ITERS];
    int scl_base [N_ITERS];
    int out_base [N_ITERS];

    // Expected output for each iter: 8 rows × 8 cols of INT8
    logic [7:0] expected [N_ITERS][8][8];

    // ────────────────────────────────────────────────
    //  Clock / reset
    // ────────────────────────────────────────────────
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ────────────────────────────────────────────────
    //  DUT signals
    // ────────────────────────────────────────────────
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

    int    errors = 0;
    int    checks = 0;
    int    pc_idx = 0;
    string region_owner [DMEM_SIZE];   // for overlap check

    // ────────────────────────────────────────────────
    //  DUT
    // ────────────────────────────────────────────────
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

    // ================================================
    //  Helpers — encoders
    // ================================================
    function automatic [31:0] enc_ls(
        input [5:0] op,    input [3:0] buf_sel,
        input [5:0] ext,   input [7:0] tile_b,
        input [7:0] tile_a
    );
        return {op, buf_sel, ext, tile_b, tile_a};
    endfunction

    function automatic [31:0] enc_cmp(
        input [5:0] op,    input       w_transpose,
        input [4:0] n_sc,  input       bias_bypass
    );
        return {op, 19'd0, w_transpose, n_sc, bias_bypass};
    endfunction

    // ================================================
    //  Helpers — bus drive
    // ================================================
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

    // Reads via host port. Synchronous SRAM:
    //   Cycle k   : drive en/addr  (mux selects host-rd)
    //   Cycle k+1 : SRAM samples,  Do0 valid at end
    //   Cycle k+2 : sample dmem_rd_data (which is sram_do0)
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

    // ================================================
    //  SRAM map allocator + overlap check
    // ================================================
    task automatic claim_region(input int base, input int len, input string name);
        if (base + len > DMEM_SIZE) begin
            $display("[%0t] FATAL: region '%s' base=%0d len=%0d overflows DMEM (%0d)",
                     $time, name, base, len, DMEM_SIZE);
            $fatal;
        end
        for (int k = 0; k < len; k++) begin
            if (region_owner[base+k] != "") begin
                $display("[%0t] FATAL: region '%s' addr %0d already owned by '%s'",
                         $time, name, base+k, region_owner[base+k]);
                $fatal;
            end
            region_owner[base+k] = name;
        end
    endtask

    task automatic build_memory_map();
        // Iter 0
        act_base[0] =   0; wgt_base[0] =  16; bias_base[0] = 32; scl_base[0] = 40; out_base[0] =  64;
        // Iter 1
        act_base[1] =  80; wgt_base[1] =  96; bias_base[1] =112; scl_base[1] =120; out_base[1] = 144;
        // Iter 2
        act_base[2] = 160; wgt_base[2] = 176; bias_base[2] =192; scl_base[2] =200; out_base[2] = 224;

        for (int it = 0; it < N_ITERS; it++) begin
            claim_region(act_base [it], 16, $sformatf("ACT%0d",  it));
            claim_region(wgt_base [it], 16, $sformatf("WGT%0d",  it));
            claim_region(bias_base[it],  8, $sformatf("BIAS%0d", it));
            claim_region(scl_base [it],  1, $sformatf("SCL%0d",  it));
            claim_region(out_base [it], 16, $sformatf("OUT%0d",  it));
        end

        $display("[%0t] Memory map OK — all regions fit in DMEM (256 words) without overlap",
                 $time);
    endtask

    // ================================================
    //  Tensor pattern generators
    // ================================================
    function automatic [7:0] act_pattern(input int it, input int r, input int c);
        case (it)
            0: return 8'd1;
            1: return 8'(c + 1);
            2: return 8'((r + c) & 8'h7F);
            default: return 8'd0;
        endcase
    endfunction

    // Identity 8x8 weights
    function automatic [7:0] wgt_pattern(input int it, input int r, input int c);
        return (r == c) ? 8'd1 : 8'd0;
    endfunction

    // Pre-compute expected results
    task automatic compute_expected();
        for (int it = 0; it < N_ITERS; it++)
            for (int r = 0; r < 8; r++)
                for (int c = 0; c < 8; c++) begin
                    // ACT × W(=I) + bias(=0) → ACT.  With M0=2^30, n_scale=30 → identity rescale.
                    // ReLU on a non-negative INT8 → unchanged.
                    expected[it][r][c] = act_pattern(it, r, c);
                end
    endtask

    // ================================================
    //  Tile loaders (one tile = 8 rows × 8 cols, 16 words)
    // ================================================
    task automatic load_act_tile(input int it);
        int base = act_base[it];
        for (int r = 0; r < 8; r++) begin
            // word_lo = {col3, col2, col1, col0}
            // word_hi = {col7, col6, col5, col4}
            logic [31:0] wlo, whi;
            wlo = { act_pattern(it, r, 3),
                    act_pattern(it, r, 2),
                    act_pattern(it, r, 1),
                    act_pattern(it, r, 0) };
            whi = { act_pattern(it, r, 7),
                    act_pattern(it, r, 6),
                    act_pattern(it, r, 5),
                    act_pattern(it, r, 4) };
            dmem_write(base + 2*r,     wlo);
            dmem_write(base + 2*r + 1, whi);
        end
    endtask

    task automatic load_wgt_tile(input int it);
        int base = wgt_base[it];
        for (int r = 0; r < 8; r++) begin
            logic [31:0] wlo, whi;
            wlo = { wgt_pattern(it, r, 3),
                    wgt_pattern(it, r, 2),
                    wgt_pattern(it, r, 1),
                    wgt_pattern(it, r, 0) };
            whi = { wgt_pattern(it, r, 7),
                    wgt_pattern(it, r, 6),
                    wgt_pattern(it, r, 5),
                    wgt_pattern(it, r, 4) };
            dmem_write(base + 2*r,     wlo);
            dmem_write(base + 2*r + 1, whi);
        end
    endtask

    task automatic load_bias_tile(input int it);
        for (int b = 0; b < 8; b++)
            dmem_write(bias_base[it] + b, 32'd0);
    endtask

    task automatic load_scl_tile(input int it);
        // M0 = 2^30 (paired with n_scale=30 → identity rescale)
        dmem_write(scl_base[it], 32'h4000_0000);
    endtask

    task automatic load_all_tensors();
        for (int it = 0; it < N_ITERS; it++) begin
            $display("[%0t] Loading tensors for iter %0d (ACT@%0d WGT@%0d BIAS@%0d SCL@%0d OUT@%0d)",
                     $time, it, act_base[it], wgt_base[it],
                     bias_base[it], scl_base[it], out_base[it]);
            load_act_tile (it);
            load_wgt_tile (it);
            load_bias_tile(it);
            load_scl_tile (it);
        end
    endtask

    // ================================================
    //  Program loader
    // ================================================
    task automatic emit(input [31:0] instr, input string label);
        if (pc_idx >= IMEM_SIZE) begin
            $display("[%0t] FATAL: program too large for IMEM (%0d words)",
                     $time, IMEM_SIZE);
            $fatal;
        end
        imem_write(pc_idx, instr);
        $display("    IMEM[%0d] = 0x%08h   ; %s", pc_idx, instr, label);
        pc_idx++;
    endtask

    task automatic load_program();
        pc_idx = 0;

        for (int it = 0; it < N_ITERS; it++) begin
            $display("[%0t] -- Iter %0d program --", $time, it);
            emit(enc_ls (OP_LOAD_ACT,  4'd0, 6'd0, 8'd0,            8'(act_base[it])),
                 $sformatf("LOAD_ACT  iter%0d", it));
            emit(enc_ls (OP_LOAD_WGT,  4'd0, 6'd0, 8'd0,            8'(wgt_base[it])),
                 $sformatf("LOAD_WGT  iter%0d", it));
            emit(enc_ls (OP_LOAD_BIAS, 4'd0, 6'd0, 8'd0,            8'(bias_base[it])),
                 $sformatf("LOAD_BIAS iter%0d", it));
            emit(enc_ls (OP_LOAD_SCL,  4'd0, 6'd0, 8'd0,            8'(scl_base[it])),
                 $sformatf("LOAD_SCL  iter%0d", it));
            emit(enc_cmp(OP_CONV,      1'b0, 5'd0,  1'b0),
                 $sformatf("CONV      iter%0d", it));
            emit(enc_cmp(OP_ADD_BIAS,  1'b0, 5'd0,  1'b0),
                 $sformatf("ADD_BIAS  iter%0d", it));
            emit(enc_cmp(OP_REQ,       1'b0, 5'd30, 1'b0),
                 $sformatf("REQ n=30  iter%0d", it));
            emit(enc_cmp(OP_RELU,      1'b0, 5'd0,  1'b0),
                 $sformatf("RELU      iter%0d", it));
            // STORE: buf_sel[0]=1 → relu_buffer
            emit(enc_ls (OP_STORE,     4'd1, 6'd0, 8'd0,            8'(out_base[it])),
                 $sformatf("STORE→%0d iter%0d", out_base[it], it));
        end

        // HALT
        emit({OP_HALT, 26'd0}, "HALT");

        $display("[%0t] Program loaded (%0d instructions, IMEM capacity = %0d)",
                 $time, pc_idx, IMEM_SIZE);
    endtask

    // ================================================
    //  Verification
    // ================================================
    task automatic check(input int addr, input [31:0] expected_w, input string label);
        logic [31:0] got;
        dmem_read(addr, got);
        checks++;
        if (got === expected_w) begin
            $display("  [PASS] %-22s DMEM[%0d] = 0x%08h",
                     label, addr, got);
        end else begin
            $display("  [FAIL] %-22s DMEM[%0d] = 0x%08h  expected 0x%08h",
                     label, addr, got, expected_w);
            errors++;
        end
    endtask

    task automatic verify_iter(input int it);
        int base = out_base[it];
        $display("\n[%0t] === Verifying iter %0d output @ DMEM[%0d..%0d] ===",
                 $time, it, base, base+15);

        for (int r = 0; r < 8; r++) begin
            logic [31:0] exp_lo, exp_hi;
            exp_lo = { expected[it][r][3],
                       expected[it][r][2],
                       expected[it][r][1],
                       expected[it][r][0] };
            exp_hi = { expected[it][r][7],
                       expected[it][r][6],
                       expected[it][r][5],
                       expected[it][r][4] };
            check(base + 2*r,     exp_lo,
                  $sformatf("iter%0d row%0d lo", it, r));
            check(base + 2*r + 1, exp_hi,
                  $sformatf("iter%0d row%0d hi", it, r));
        end
    endtask

    // ================================================
    //  Internal probes (for diagnosis)
    // ================================================
    task automatic dump_acc_buffer(input string tag);
        $display("[%0t] %s acc_buffer (INT32):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %08h %08h %08h %08h %08h %08h %08h %08h", r,
                dut.u_acc_buf.mem[r][0], dut.u_acc_buf.mem[r][1],
                dut.u_acc_buf.mem[r][2], dut.u_acc_buf.mem[r][3],
                dut.u_acc_buf.mem[r][4], dut.u_acc_buf.mem[r][5],
                dut.u_acc_buf.mem[r][6], dut.u_acc_buf.mem[r][7]);
    endtask

    task automatic dump_pbias_buffer(input string tag);
        $display("[%0t] %s pbias_buffer (INT32):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %08h %08h %08h %08h %08h %08h %08h %08h", r,
                dut.u_pbias_buf.mem[r][0], dut.u_pbias_buf.mem[r][1],
                dut.u_pbias_buf.mem[r][2], dut.u_pbias_buf.mem[r][3],
                dut.u_pbias_buf.mem[r][4], dut.u_pbias_buf.mem[r][5],
                dut.u_pbias_buf.mem[r][6], dut.u_pbias_buf.mem[r][7]);
    endtask

    task automatic dump_preq_buffer(input string tag);
        $display("[%0t] %s preq_buffer (INT8):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h", r,
                dut.u_preq_buf.mem[r][0], dut.u_preq_buf.mem[r][1],
                dut.u_preq_buf.mem[r][2], dut.u_preq_buf.mem[r][3],
                dut.u_preq_buf.mem[r][4], dut.u_preq_buf.mem[r][5],
                dut.u_preq_buf.mem[r][6], dut.u_preq_buf.mem[r][7]);
    endtask

    task automatic dump_relu_buffer(input string tag);
        $display("[%0t] %s relu_buffer (INT8):", $time, tag);
        for (int r = 0; r < 8; r++)
            $display("  row%0d: %02h %02h %02h %02h %02h %02h %02h %02h", r,
                dut.u_relu_buf.mem[r][0], dut.u_relu_buf.mem[r][1],
                dut.u_relu_buf.mem[r][2], dut.u_relu_buf.mem[r][3],
                dut.u_relu_buf.mem[r][4], dut.u_relu_buf.mem[r][5],
                dut.u_relu_buf.mem[r][6], dut.u_relu_buf.mem[r][7]);
    endtask

    // ================================================
    //  Watchdog
    // ================================================
    initial begin
        #(CLK_PERIOD * 200000);
        $display("\n[%0t] *** WATCHDOG TIMEOUT *** PC=%0d state=%s opcode=%b",
                 $time, dut.cu.PC, dut.cu.state.name(), dut.cu.opcode);
        errors++;
        $finish;
    end

    // ================================================
    //  Live execution monitor
    // ================================================
    initial begin
        forever begin
            @(posedge clk);
            if (rst_n && (dut.cu.state == dut.cu.EXECUTE) && dut.cu.exec_pulse) begin
                $display("[%0t] EXEC  PC=%0d  opcode=%b",
                         $time, dut.cu.PC, dut.cu.opcode);
            end
        end
    end

    // Snapshot internal buffers each time the CU's main FSM
    // finishes an instruction (transitions to NEXT) — useful
    // for debugging. Disable by commenting this block.
    initial begin
        forever begin
            @(posedge clk);
            if (rst_n && dut.cu.state == dut.cu.NEXT) begin
                case (dut.cu.opcode)
                    OP_CONV:     dump_acc_buffer  ("after CONV    ");
                    OP_ADD_BIAS: dump_pbias_buffer("after ADD_BIAS");
                    OP_REQ:      dump_preq_buffer ("after REQ     ");
                    OP_RELU:     dump_relu_buffer ("after RELU    ");
                    default: ;
                endcase
            end
        end
    end

    // ================================================
    //  Main test
    // ================================================
    initial begin
        $display("================================================");
        $display(" tb_npu_top — multi-iteration self-checking TB");
        $display("================================================");

        // Init region_owner (string array elements default to "")
        do_reset();

        $display("\n[%0t] Building memory map...", $time);
        build_memory_map();

        $display("\n[%0t] Pre-computing expected outputs...", $time);
        compute_expected();

        $display("\n[%0t] Loading test tensors into DMEM...", $time);
        load_all_tensors();

        $display("\n[%0t] Loading program into IMEM...", $time);
        load_program();

        repeat (8) @(posedge clk);

        $display("\n[%0t] Asserting start_npu...", $time);
        @(posedge clk);
        start_npu <= 1'b1;
        @(posedge clk);
        start_npu <= 1'b0;

        wait (npu_done == 1'b1);
        $display("\n[%0t] npu_done asserted — HALT reached.", $time);

        repeat (10) @(posedge clk);

        // Verify each iteration's output region
        for (int it = 0; it < N_ITERS; it++) begin
            verify_iter(it);
        end

        // Final report
        $display("\n================================================");
        $display(" Total checks : %0d", checks);
        $display(" Errors       : %0d", errors);
        if (errors == 0) $display(" *** TEST PASSED ***");
        else             $display(" *** TEST FAILED ***");
        $display("================================================");

        repeat (5) @(posedge clk);
        $finish;
    end

    // ────────────────────────────────────────────────
    //  Waveform dump
    // ────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_npu_top.vcd");
        $dumpvars(0, tb_npu_top);
    end

endmodule