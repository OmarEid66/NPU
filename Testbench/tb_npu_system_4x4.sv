// ================================================================
//  tb_npu_system — Randomized System Testbench (4×4 SA version)
//
//  Changes from 8×8:
//    - SA_SIZE: 8→4, SRAM_AW: 8→7
//    - All arrays: [0:7][0:7] → [0:3][0:3], [0:7] → [0:3]
//    - SRAM tile layout: 1 word per row (was 2) — 4 cols fit in 32 bits
//    - SRAM addresses scaled down to fit 128-word DMEM
//    - Golden model: k loop 0..3, c loop 0..3
//    - verify_output: reads 1 word per row (not lo+hi)
//    - write_tile_to_sram: 1 write per row (not 2)
//    - write_dmem_word addr argument: [6:0] range
//
//  EXTENSIONS:
//    - Added helper tasks fill_tile and fill_bias for constant data.
//    - Added TC5: Zero input matrices.
//    - Added TC6: Positive INT8 saturation (+127 clipping).
//    - Added TC7: Negative INT8 saturation (-128 clipping).
//    - Added TC8: Zero-scale multiplier (M0 = 0).
//    - Added TC9: Extreme shift (n_scale = 31).
// ================================================================

`timescale 1ns/1ps

module tb_npu_system_4x4;

// ================================================================
//  Parameters & Globals
// ================================================================
localparam SA_SIZE    = 4;          
localparam DATA_W     = 8;
localparam SRAM_AW    = 7;          // 128-word DMEM
localparam CLK_PERIOD = 10;
localparam DIV        = 16'd4;
localparam BIT_CLKS   = DIV * 16;
localparam TIMEOUT    = 5_000_000;
localparam ACK        = 8'hAC;

logic clk = 0;
logic rst_n;
logic uart_rx, uart_tx;
logic locked, npu_done, done_processing;

always #(CLK_PERIOD/2) clk = ~clk;

integer pass_cnt = 0, fail_cnt = 0;

// ── Global test data arrays — all 4×4 now ─────────────────────
logic [7:0]         test_act  [0:3][0:3];   
logic [7:0]         test_wgt  [0:3][0:3];   
logic signed [31:0] test_bias [0:3];         
logic [31:0]        test_m0;
logic [4:0]         test_n_sc;

// ================================================================
//  DUT
// ================================================================
npu_system_top #(
    .DEFAULT_DIVISOR (DIV),
    .SA_SIZE         (SA_SIZE),
    .DATA_W          (DATA_W),
    .SRAM_ADDR_W     (SRAM_AW)     
) dut (
    .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .locked(locked), .npu_done(npu_done), .done_processing(done_processing)
);

// ================================================================
//  UART & APB Drivers
// ================================================================
task automatic uart_send_byte(input [7:0] b);
    integer i;
    begin
        uart_rx = 0; repeat(BIT_CLKS) @(posedge clk);
        for (i = 0; i < 8; i++) begin
            uart_rx = b[i]; repeat(BIT_CLKS) @(posedge clk);
        end
        uart_rx = 1; repeat(BIT_CLKS) @(posedge clk);
    end
endtask

task automatic uart_recv_byte(output [7:0] b);
    integer i;
    begin
        while (uart_tx !== 0) @(posedge clk);
        repeat(BIT_CLKS/2) @(posedge clk);
        for (i = 0; i < 8; i++) begin
            repeat(BIT_CLKS) @(posedge clk); b[i] = uart_tx;
        end
        repeat(BIT_CLKS) @(posedge clk);
    end
endtask

task automatic apb_write(input [31:0] addr, input [31:0] data);
    logic [7:0] resp;
    begin
        uart_send_byte(8'hDE); uart_send_byte(8'hAD); uart_send_byte(8'hA5);
        uart_send_byte(addr[31:24]); uart_send_byte(addr[23:16]);
        uart_send_byte(addr[15:8]);  uart_send_byte(addr[7:0]);
        uart_send_byte(data[31:24]); uart_send_byte(data[23:16]);
        uart_send_byte(data[15:8]);  uart_send_byte(data[7:0]);
        uart_recv_byte(resp);
    end
endtask

task automatic apb_read(input [31:0] addr, output [31:0] rdata);
    logic [7:0] b;
    begin
        uart_send_byte(8'hDE); uart_send_byte(8'hAD); uart_send_byte(8'h5A);
        uart_send_byte(addr[31:24]); uart_send_byte(addr[23:16]);
        uart_send_byte(addr[15:8]);  uart_send_byte(addr[7:0]);
        uart_recv_byte(b);
        uart_recv_byte(b); rdata[31:24] = b;
        uart_recv_byte(b); rdata[23:16] = b;
        uart_recv_byte(b); rdata[15:8]  = b;
        uart_recv_byte(b); rdata[7:0]   = b;
    end
endtask

// ── APB window base addresses ──────────────────────────────────
task automatic write_imem_word(input [4:0] word_addr, input [31:0] instr);
    apb_write(32'h0000_0100 + {27'b0, word_addr, 2'b00}, instr);
endtask

task automatic write_dmem_word(input [6:0] word_addr, input [31:0] data);
    apb_write(32'h0000_0200 + {25'b0, word_addr, 2'b00}, data);
endtask

task automatic read_dmem_word(input [6:0] word_addr, output [31:0] rdata);
    apb_write(32'h0000_0008, {25'b0, word_addr});   
    apb_read (32'h0000_000C, rdata);                
endtask

task automatic host_load_mode(); apb_write(32'h0000_0000, 32'h6); endtask
task automatic host_run_mode();  apb_write(32'h0000_0000, 32'h0); endtask
task automatic host_read_mode(); apb_write(32'h0000_0000, 32'h8); endtask
task automatic npu_start();
    apb_write(32'h0000_0000, 32'h0);
    apb_write(32'h0000_0000, 32'h1);
endtask

task automatic wait_npu_done();
    integer n; logic [31:0] s;
    n = 0; s = 0;
    while (!s[0] && n < 500) begin
        apb_read(32'h0000_0004, s); n++;
    end
endtask

task automatic do_reset();
    rst_n = 0; uart_rx = 1;
    repeat(8) @(posedge clk);
    rst_n = 1; repeat(4) @(posedge clk);
endtask

// ================================================================
//  Random & Constant Data Generators 
// ================================================================
task automatic gen_random_tile(
    input integer min_v, input integer max_v,
    ref logic [7:0] tile[0:3][0:3]     
);
    integer r, c, val;
    begin
        for (r = 0; r < SA_SIZE; r++) begin
            for (c = 0; c < SA_SIZE; c++) begin
                val = $urandom_range(max_v - min_v) + min_v;
                tile[r][c] = 8'(val);
            end
        end
    end
endtask

task automatic gen_random_bias(
    input integer min_v, input integer max_v,
    ref logic signed [31:0] bias[0:3]   
);
    integer c, val;
    begin
        for (c = 0; c < SA_SIZE; c++) begin
            val = $urandom_range(max_v - min_v) + min_v;
            bias[c] = val;
        end
    end
endtask

task automatic fill_tile(
    input [7:0] val, 
    ref logic [7:0] tile[0:3][0:3]
);
    integer r, c;
    begin
        for (r = 0; r < SA_SIZE; r++) begin
            for (c = 0; c < SA_SIZE; c++) begin
                tile[r][c] = val;
            end
        end
    end
endtask

task automatic fill_bias(
    input signed [31:0] val, 
    ref logic signed [31:0] bias[0:3]
);
    integer c;
    for (c = 0; c < SA_SIZE; c++) bias[c] = val;
endtask

task automatic write_tile_to_sram(
    input [6:0] base_addr,              
    ref logic [7:0] tile[0:3][0:3]      
);
    integer r;
    begin
        for (r = 0; r < SA_SIZE; r++) begin
            write_dmem_word(
                7'(base_addr + r),
                {tile[r][3], tile[r][2], tile[r][1], tile[r][0]}
            );
        end
    end
endtask

task automatic write_bias_to_sram(
    input [6:0] base_addr,
    ref logic signed [31:0] bias[0:3]   
);
    integer c;
    for (c = 0; c < SA_SIZE; c++)
        write_dmem_word(7'(base_addr + c), bias[c]);
endtask

// ================================================================
//  Instruction Encoders
// ================================================================
function [31:0] enc_load(input [5:0] op, input [7:0] tile_a);
    return {op, 4'b0, 6'b0, 8'h00, tile_a};
endfunction

function [31:0] enc_store(input [3:0] buf_sel, input [7:0] tile_a);
    return {6'b001001, buf_sel, 6'b0, 8'h00, tile_a};
endfunction

function [31:0] enc_comp(input [5:0] op, input [4:0] n_scale);
    return {op, 19'b0, 1'b0, n_scale, 1'b0};
endfunction

localparam [6:0] ADDR_ACT   = 7'h00;
localparam [6:0] ADDR_WGT   = 7'h04;
localparam [6:0] ADDR_BIAS  = 7'h08;
localparam [6:0] ADDR_SCALE = 7'h0C;
localparam [6:0] ADDR_OUT   = 7'h10;

task automatic program_pipeline(input bit use_relu, input [4:0] shift);
    begin
        write_imem_word(5'd0, enc_load(6'b000000, ADDR_ACT));    
        write_imem_word(5'd1, enc_load(6'b000001, ADDR_WGT));    
        write_imem_word(5'd2, enc_load(6'b000010, ADDR_BIAS));   
        write_imem_word(5'd3, enc_load(6'b000011, ADDR_SCALE));  
        write_imem_word(5'd4, enc_comp(6'b000100, 5'd0));        
        write_imem_word(5'd5, enc_comp(6'b000101, 5'd0));        
        write_imem_word(5'd6, enc_comp(6'b000110, shift));       
        if (use_relu) begin
            write_imem_word(5'd7, enc_comp(6'b000111, 5'd0));    
            write_imem_word(5'd8, enc_store(4'b0001, ADDR_OUT)); 
        end else begin
            write_imem_word(5'd7, {6'b111110, 26'd0});           
            write_imem_word(5'd8, enc_store(4'b0000, ADDR_OUT)); 
        end
        write_imem_word(5'd9, {6'b111111, 26'd0});               
    end
endtask

// ================================================================
//  Golden Model
// ================================================================
function automatic [7:0] compute_golden_byte(
    input integer r, input integer c,
    input bit use_relu,
    ref logic [7:0]         act [0:3][0:3],  
    ref logic [7:0]         wgt [0:3][0:3],  
    ref logic signed [31:0] bias[0:3],        
    input [31:0] m0,
    input [4:0]  shift
);
    logic signed [63:0] psum;
    logic signed [63:0] pb_val, mul, shifted;
    logic [7:0] clipped;
    integer k;
    begin
        psum = 0;
        for (k = 0; k < SA_SIZE; k++)
            psum += $signed(act[r][k]) * $signed(wgt[k][c]);

        pb_val  = psum + bias[c];
        mul     = pb_val * $signed({1'b0, m0});
        shifted = mul >>> shift;

        if      (shifted >  64'sd127)  clipped = 8'sd127;
        else if (shifted < -64'sd128)  clipped = -8'sd128;
        else                           clipped = 8'(shifted);

        if (use_relu && clipped[7]) return 8'd0;
        return clipped;
    end
endfunction

// ================================================================
//  Output Verification
// ================================================================
task automatic verify_output(input string test_name, input bit use_relu);
    integer r, c;
    logic [31:0] got_word, exp_word;
    logic [7:0]  exp_b;
    begin
        for (r = 0; r < SA_SIZE; r++) begin
            read_dmem_word(7'(ADDR_OUT + r), got_word);

            exp_word = 32'd0;
            for (c = 0; c < SA_SIZE; c++) begin
                exp_b = compute_golden_byte(
                    r, c, use_relu,
                    test_act, test_wgt, test_bias,
                    test_m0, test_n_sc
                );
                exp_word[c*8 +: 8] = exp_b;
            end

            if (got_word !== exp_word) begin
                $display("  [FAIL] %s Row %0d: Got %08h, Exp %08h",
                         test_name, r, got_word, exp_word);
                fail_cnt++;
            end else begin
                pass_cnt++;
            end
        end
    end
endtask

// ================================================================
//  MAIN EXECUTION
// ================================================================
initial begin
    $display("\n============================================================");
    $display("  STARTING RANDOMIZED SYSTEM TESTS  (4x4 SA)");
    $display("============================================================\n");

    // ------------------------------------------------------------------
    // TC1: Full Pipeline (Mixed Random Data + ReLU)
    // ------------------------------------------------------------------
    $display("[TC1] Full Pipeline (Mixed Random Data + RELU)");
    do_reset(); host_load_mode();

    gen_random_tile(-20, 20, test_act);
    gen_random_tile(-20, 20, test_wgt);
    gen_random_bias(-500, 500, test_bias);
    test_m0 = 32'd1; test_n_sc = 5'd2;

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b1, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC1", 1'b1);

    // ------------------------------------------------------------------
    // TC2: No ReLU (Mixed Random Data)
    // ------------------------------------------------------------------
    $display("\n[TC2] No ReLU Pipeline (Mixed Random Data)");
    do_reset(); host_load_mode();

    gen_random_tile(-50, 50, test_act);
    gen_random_tile(-50, 50, test_wgt);
    gen_random_bias(-1000, 1000, test_bias);
    test_m0 = 32'd1; test_n_sc = 5'd4;

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC2", 1'b0);

    // ------------------------------------------------------------------
    // TC3: Positive Data Only (No ReLU)
    // ------------------------------------------------------------------
    $display("\n[TC3] Positive Data Only (No ReLU)");
    do_reset(); host_load_mode();

    gen_random_tile(1, 30, test_act);
    gen_random_tile(1, 30, test_wgt);
    gen_random_bias(0, 1000, test_bias);
    test_m0 = 32'd1; test_n_sc = 5'd3;

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC3", 1'b0);

    // ------------------------------------------------------------------
    // TC4: Negative Clamping (Mixed Data + ReLU)
    // ------------------------------------------------------------------
    $display("\n[TC4] Negative Clamping Test (Mixed Data + RELU)");
    do_reset(); host_load_mode();

    gen_random_tile(-10, 10, test_act);
    gen_random_tile(-10, 10, test_wgt);
    gen_random_bias(-2000, 2000, test_bias); 
    test_m0 = 32'd1; test_n_sc = 5'd0;

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b1, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC4", 1'b1);

    // ------------------------------------------------------------------
    // TC5: Zero Input Test
    // ------------------------------------------------------------------
    $display("\n[TC5] Zero Input Test");
    do_reset(); host_load_mode();

    fill_tile(8'd0, test_act);
    fill_tile(8'd0, test_wgt);
    fill_bias(32'd0, test_bias); 
    test_m0 = 32'd1; test_n_sc = 5'd0;

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC5", 1'b0);

    // ------------------------------------------------------------------
    // TC6: Positive Saturation (Forced +127 Clamping)
    // ------------------------------------------------------------------
    $display("\n[TC6] Positive Saturation (+127 Clipping)");
    do_reset(); host_load_mode();

    fill_tile(8'd127, test_act);
    fill_tile(8'd127, test_wgt);
    fill_bias(32'sd10000, test_bias);  // Massive positive bias
    test_m0 = 32'd2; test_n_sc = 5'd0; // No shift, multiplier of 2

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC6", 1'b0);

    // ------------------------------------------------------------------
    // TC7: Negative Saturation (Forced -128 Clamping, No ReLU)
    // ------------------------------------------------------------------
    $display("\n[TC7] Negative Saturation (-128 Clipping, No ReLU)");
    do_reset(); host_load_mode();

    fill_tile(8'd127, test_act);
    fill_tile(8'h80, test_wgt);         // -128 in two's complement
    fill_bias(-32'sd10000, test_bias);  // Massive negative bias
    test_m0 = 32'd2; test_n_sc = 5'd0;

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);  // Must bypass ReLU to see the -128
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC7", 1'b0);

    // ------------------------------------------------------------------
    // TC8: Zero Scale Multiplier (M0 = 0)
    // ------------------------------------------------------------------
    $display("\n[TC8] Zero Scale Multiplier (M0 = 0)");
    do_reset(); host_load_mode();

    gen_random_tile(-50, 50, test_act);
    gen_random_tile(-50, 50, test_wgt);
    gen_random_bias(-500, 500, test_bias);
    test_m0 = 32'd0; test_n_sc = 5'd2;  // M0 is completely zeroed out

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC8", 1'b0);

    // ------------------------------------------------------------------
    // TC9: Extreme Right Shift (n_scale = 31)
    // ------------------------------------------------------------------
    $display("\n[TC9] Extreme Right Shift (n_scale = 31)");
    do_reset(); host_load_mode();

    gen_random_tile(-100, 100, test_act);
    gen_random_tile(-100, 100, test_wgt);
    gen_random_bias(-1000, 1000, test_bias);
    test_m0 = 32'd1; test_n_sc = 5'd31; // Max possible shift

    write_tile_to_sram(ADDR_ACT,   test_act);
    write_tile_to_sram(ADDR_WGT,   test_wgt);
    write_bias_to_sram(ADDR_BIAS,  test_bias);
    write_dmem_word   (ADDR_SCALE, test_m0);

    program_pipeline(1'b0, test_n_sc);
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC9", 1'b0);

    // ------------------------------------------------------------------
    $display("\n============================================================");
    $display("  FINAL RESULTS: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("  *** SUCCESS: ALL TESTS PASSED ***");
    else               $display("  *** ERROR: SILICON BUG DETECTED ***");
    $display("============================================================\n");
    $finish;
end

// Watchdog
initial begin
    #(CLK_PERIOD * TIMEOUT);
    $display("!! GLOBAL WATCHDOG TIMEOUT !!");
    $finish;
end

endmodule