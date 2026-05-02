// ================================================================
//  tb_npu_system — Randomized System Testbench
//
//  Executes comprehensive randomized matrix math through the APB
//  and UART interfaces to test the NPU end-to-end.
// ================================================================

`timescale 1ns/1ps

module tb_npu_system;

// ================================================================
//  Parameters & Globals
// ================================================================
localparam SA_SIZE    = 8;
localparam DATA_W     = 8;
localparam SRAM_AW    = 8;
localparam CLK_PERIOD = 10;
localparam DIV        = 16'd4;      // Fast UART for simulation
localparam BIT_CLKS   = DIV * 16;
localparam TIMEOUT    = 5_000_000;
localparam ACK        = 8'hAC;

logic clk = 0;
logic rst_n;
logic uart_rx, uart_tx;
logic locked, npu_done, done_processing;

always #(CLK_PERIOD/2) clk = ~clk;

integer pass_cnt = 0, fail_cnt = 0;

// Global test data arrays
logic [7:0]         test_act [0:7][0:7];
logic [7:0]         test_wgt [0:7][0:7];
logic signed [31:0] test_bias [0:7];
logic [31:0]        test_m0;
logic [4:0]         test_n_sc;

// ================================================================
//  DUT Instantiation
// ================================================================
npu_system_top #(
    .DEFAULT_DIVISOR (DIV), .SA_SIZE(SA_SIZE), .DATA_W(DATA_W), .SRAM_ADDR_W(SRAM_AW)
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
        uart_send_byte(addr[31:24]); uart_send_byte(addr[23:16]); uart_send_byte(addr[15:8]); uart_send_byte(addr[7:0]);
        uart_send_byte(data[31:24]); uart_send_byte(data[23:16]); uart_send_byte(data[15:8]); uart_send_byte(data[7:0]);
        uart_recv_byte(resp);
    end
endtask

task automatic apb_read(input [31:0] addr, output [31:0] rdata);
    logic [7:0] b;
    begin
        uart_send_byte(8'hDE); uart_send_byte(8'hAD); uart_send_byte(8'h5A);
        uart_send_byte(addr[31:24]); uart_send_byte(addr[23:16]); uart_send_byte(addr[15:8]); uart_send_byte(addr[7:0]);
        uart_recv_byte(b); 
        uart_recv_byte(b); rdata[31:24] = b;
        uart_recv_byte(b); rdata[23:16] = b;
        uart_recv_byte(b); rdata[15:8]  = b;
        uart_recv_byte(b); rdata[7:0]   = b;
    end
endtask

// Helper Wrappers
task automatic write_imem_word(input [4:0] word_addr, input [31:0] instr);
    apb_write(32'h0000_0100 + {27'b0, word_addr, 2'b00}, instr);
endtask

task automatic write_dmem_word(input [7:0] word_addr, input [31:0] data);
    apb_write(32'h0000_0800 + {24'b0, word_addr, 2'b00}, data);
endtask

task automatic read_dmem_word(input [7:0] word_addr, output [31:0] rdata);
    apb_write(32'h0000_0008, {24'b0, word_addr});
    apb_read(32'h0000_000C, rdata);
endtask

task automatic host_load_mode(); apb_write(32'h0000_0000, 32'h6); endtask
task automatic host_run_mode();  apb_write(32'h0000_0000, 32'h0); endtask
task automatic host_read_mode(); apb_write(32'h0000_0000, 32'h8); endtask 
task automatic npu_start();      apb_write(32'h0000_0000, 32'h0); apb_write(32'h0000_0000, 32'h1); endtask

task automatic wait_npu_done();
    integer n = 0; logic [31:0] s = 0;
    while (!s[0] && n < 500) begin apb_read(32'h0000_0004, s); n++; end
endtask

task automatic do_reset();
    rst_n = 0; uart_rx = 1;
    repeat(8) @(posedge clk);
    rst_n = 1; repeat(4) @(posedge clk);
endtask

// ================================================================
//  Random Data Generators
// ================================================================
task automatic gen_random_tile(input integer min_v, input integer max_v, ref logic [7:0] tile[0:7][0:7]);
    integer r, c, val;
    begin
        for (r=0; r<8; r++) begin
            for (c=0; c<8; c++) begin
                val = $urandom_range(max_v - min_v) + min_v;
                tile[r][c] = 8'(val);
            end
        end
    end
endtask

task automatic gen_random_bias(input integer min_v, input integer max_v, ref logic signed [31:0] bias[0:7]);
    integer c, val;
    begin
        for (c=0; c<8; c++) begin
            val = $urandom_range(max_v - min_v) + min_v;
            bias[c] = val;
        end
    end
endtask

task automatic write_tile_to_sram(input [7:0] base_addr, ref logic [7:0] tile[0:7][0:7]);
    integer r;
    begin
        for (r=0; r<8; r++) begin
            write_dmem_word(base_addr + r*2,     {tile[r][3], tile[r][2], tile[r][1], tile[r][0]});
            write_dmem_word(base_addr + r*2 + 1, {tile[r][7], tile[r][6], tile[r][5], tile[r][4]});
        end
    end
endtask

task automatic write_bias_to_sram(input [7:0] base_addr, ref logic signed [31:0] bias[0:7]);
    integer c;
    for (c=0; c<8; c++) write_dmem_word(base_addr + c, bias[c]);
endtask

// ================================================================
//  Instruction Encoders & Programmers
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

task automatic program_pipeline(input bit use_relu, input [4:0] shift);
    begin
        write_imem_word(5'd0, enc_load(6'b000000, 8'h00));   // ACT @ 0x00
        write_imem_word(5'd1, enc_load(6'b000001, 8'h10));   // WGT @ 0x10
        write_imem_word(5'd2, enc_load(6'b000010, 8'h20));   // BIAS @ 0x20
        write_imem_word(5'd3, enc_load(6'b000011, 8'h28));   // SCL @ 0x28
        write_imem_word(5'd4, enc_comp(6'b000100, 5'd0));    // CONV
        write_imem_word(5'd5, enc_comp(6'b000101, 5'd0));    // ADD_BIAS
        write_imem_word(5'd6, enc_comp(6'b000110, shift));   // REQ
        if (use_relu) begin
            write_imem_word(5'd7, enc_comp(6'b000111, 5'd0)); // RELU
            write_imem_word(5'd8, enc_store(4'b0001, 8'h80)); // STORE (buf 1 = relu)
        end else begin
            write_imem_word(5'd7, {6'b111110, 26'd0});        // NOP
            write_imem_word(5'd8, enc_store(4'b0000, 8'h80)); // STORE (buf 0 = preq)
        end
        write_imem_word(5'd9, {6'b111111, 26'd0});            // HALT
    end
endtask

// ================================================================
//  Dynamic Golden Model
// ================================================================
function automatic [7:0] compute_golden_byte(
    input integer r, input integer c, input bit use_relu,
    ref logic [7:0] act[0:7][0:7], ref logic [7:0] wgt[0:7][0:7],
    ref logic signed [31:0] bias[0:7], input [31:0] m0, input [4:0] shift
);
    logic signed [63:0] psum = 0;
    logic signed [63:0] pb_val, mul, shifted;
    logic [7:0] clipped;
    integer k;

    // 1. MatMul (Signed INT8)
    for (k=0; k<8; k++) psum += $signed(act[r][k]) * $signed(wgt[k][c]);
    
    // 2. Add Bias
    pb_val = psum + bias[c];

    // 3. Requantize (Multiply by M0, Shift)
    mul = pb_val * $signed({1'b0, m0}); 
    shifted = mul >>> shift;
    
    // 4. Saturate INT8
    if (shifted > 64'sd127)      clipped = 8'sd127;
    else if (shifted < -64'sd128) clipped = -8'sd128;
    else                         clipped = 8'(shifted);

    // 5. ReLU
    if (use_relu && clipped[7]) return 8'd0;
    return clipped;
endfunction

task automatic verify_output(input string test_name, input bit use_relu);
    integer r, c;
    logic [31:0] got_lo, got_hi, exp_lo, exp_hi;
    logic [7:0] exp_b;
    begin
        // Initialize to 0 to prevent stack bleeding
        got_lo = 0; got_hi = 0; exp_lo = 0; exp_hi = 0;

        for (r = 0; r < 8; r++) begin
            read_dmem_word(8'h80 + 2*r, got_lo);
            read_dmem_word(8'h80 + 2*r + 1, got_hi);
            
            exp_lo = 0; exp_hi = 0;
            
            for (c = 0; c < 4; c++) begin
                exp_b = compute_golden_byte(r, c, use_relu, test_act, test_wgt, test_bias, test_m0, test_n_sc);
                exp_lo[c*8 +: 8] = exp_b;
            end
            for (c = 4; c < 8; c++) begin
                exp_b = compute_golden_byte(r, c, use_relu, test_act, test_wgt, test_bias, test_m0, test_n_sc);
                exp_hi[(c-4)*8 +: 8] = exp_b;
            end

            if (got_lo !== exp_lo) begin
                $display("  [FAIL] %s Row %0d Lo: Got %08h, Exp %08h", test_name, r, got_lo, exp_lo); fail_cnt++;
            end else pass_cnt++;
            
            if (got_hi !== exp_hi) begin
                $display("  [FAIL] %s Row %0d Hi: Got %08h, Exp %08h", test_name, r, got_hi, exp_hi); fail_cnt++;
            end else pass_cnt++;
        end
    end
endtask

// ================================================================
//  MAIN EXECUTION
// ================================================================
initial begin
    $display("\n============================================================");
    $display("  STARTING RANDOMIZED SYSTEM TESTS");
    $display("============================================================\n");

    // ------------------------------------------------------------------
    // TC1: Full Pipeline (Mixed Random Data)
    // loads -> conv -> bias adder -> req -> relu -> store
    // ------------------------------------------------------------------
    $display("[TC1] Full Pipeline (Mixed Random Data + RELU)");
    do_reset(); host_load_mode();
    
    gen_random_tile(-20, 20, test_act);
    gen_random_tile(-20, 20, test_wgt);
    gen_random_bias(-500, 500, test_bias);
    test_m0 = 32'd1; test_n_sc = 5'd2; // Shift by 2
    
    write_tile_to_sram(8'h00, test_act);
    write_tile_to_sram(8'h10, test_wgt);
    write_bias_to_sram(8'h20, test_bias);
    write_dmem_word(8'h28, test_m0);
    
    program_pipeline(1'b1, test_n_sc); // 1 = Use ReLU
    
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC1", 1'b1);

    // ------------------------------------------------------------------
    // TC2: Bypass ReLU (Mixed Random Data)
    // loads -> conv -> bias adder -> req -> store
    // ------------------------------------------------------------------
    $display("\n[TC2] No ReLU Pipeline (Mixed Random Data)");
    do_reset(); host_load_mode();
    
    gen_random_tile(-50, 50, test_act);
    gen_random_tile(-50, 50, test_wgt);
    gen_random_bias(-1000, 1000, test_bias);
    test_m0 = 32'd1; test_n_sc = 5'd4;
    
    write_tile_to_sram(8'h00, test_act);
    write_tile_to_sram(8'h10, test_wgt);
    write_bias_to_sram(8'h20, test_bias);
    write_dmem_word(8'h28, test_m0);
    
    program_pipeline(1'b0, test_n_sc); // 0 = Skip ReLU
    
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC2", 1'b0);

    // ------------------------------------------------------------------
    // TC3: Positive Data Only (No ReLU)
    // loads -> conv -> bias adder -> req -> store +ve
    // ------------------------------------------------------------------
    $display("\n[TC3] Positive Data Only (No ReLU)");
    do_reset(); host_load_mode();
    
    gen_random_tile(1, 30, test_act);     // Strictly positive
    gen_random_tile(1, 30, test_wgt);     // Strictly positive
    gen_random_bias(0, 1000, test_bias);  // Strictly positive
    test_m0 = 32'd1; test_n_sc = 5'd3;
    
    write_tile_to_sram(8'h00, test_act);
    write_tile_to_sram(8'h10, test_wgt);
    write_bias_to_sram(8'h20, test_bias);
    write_dmem_word(8'h28, test_m0);
    
    program_pipeline(1'b0, test_n_sc); 
    
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC3", 1'b0);

    // ------------------------------------------------------------------
    // TC4: Negative Data Clamping (Random +/-)
    // loads -> conv -> bias adder -> req -> relu -> store -ve
    // ------------------------------------------------------------------
    $display("\n[TC4] Negative Clamping Test (Mixed Data + RELU)");
    do_reset(); host_load_mode();
    
    gen_random_tile(-10, 10, test_act);
    gen_random_tile(-10, 10, test_wgt);
    gen_random_bias(-8000, 8000, test_bias); // Extreme bias to force +/- bounds
    test_m0 = 32'd1; test_n_sc = 5'd0;
    
    write_tile_to_sram(8'h00, test_act);
    write_tile_to_sram(8'h10, test_wgt);
    write_bias_to_sram(8'h20, test_bias);
    write_dmem_word(8'h28, test_m0);
    
    program_pipeline(1'b1, test_n_sc); // Use ReLU to clamp the negatives
    
    host_run_mode(); npu_start(); wait_npu_done(); host_read_mode();
    verify_output("TC4", 1'b1);

    // ------------------------------------------------------------------
    $display("\n============================================================");
    $display("  FINAL RESULTS: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("  *** SUCCESS: ALL RANDOMIZED TESTS PASSED ***");
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