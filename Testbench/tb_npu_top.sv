// ================================================================
//  tb_npu_top — NPU Top-Level Testbench
//
//  Full pipeline test:
//    LOAD_WGT → LOAD_ACT → LOAD_BIAS → LOAD_SCL →
//    CONV → ADD_BIAS → REQ → RELU → STORE → HALT
//
//  Test data:
//    ACT  : 8×8 all 1 (INT8)   packed → 0x01010101 per word
//    WGT  : 8×8 all 1 (INT8)   packed → 0x01010101 per word
//    BIAS : 8×0 (INT32)
//    M0   : 1 (INT32),  n_scale = 0
//
//  Expected output at SRAM[0x40-0x4F]:
//    Each element = 8  → each 32-bit word = 0x08080808
//
//  SRAM map:
//    0x00-0x0F  ACT tile
//    0x10-0x1F  WGT tile
//    0x20-0x27  BIAS (8×INT32)
//    0x28       SCALE M0
//    0x40-0x4F  STORE output
// ================================================================

`timescale 1ns/1ps

module tb_npu_top;

// ── Clock/reset ───────────────────────────────────────────────
localparam CLK_PERIOD = 10;
logic clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;
logic rst_n;

// ── DUT ports ─────────────────────────────────────────────────
logic        load_imem, load_dmem;
logic        imem_wr_we, imem_wr_en;
logic [6:0]  imem_wr_addr;
logic [31:0] imem_wr_data;
logic        dmem_wr_en;
logic [3:0]  dmem_wr_be;
logic [7:0]  dmem_wr_addr;
logic [31:0] dmem_wr_data;
logic        dmem_rd_en;
logic [7:0]  dmem_rd_addr;
logic [31:0] dmem_rd_data;
logic        start_npu, done_processing, npu_done;

// ── DUT ───────────────────────────────────────────────────────
npu_top #(.DATA_W(8), .DATA_W_PATH(32), .SA_SIZE(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .load_imem(load_imem), .load_dmem(load_dmem),
    .imem_wr_we(imem_wr_we), .imem_wr_en(imem_wr_en),
    .imem_wr_addr(imem_wr_addr), .imem_wr_data(imem_wr_data),
    .dmem_wr_en(dmem_wr_en), .dmem_wr_be(dmem_wr_be),
    .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
    .dmem_rd_en(dmem_rd_en), .dmem_rd_addr(dmem_rd_addr),
    .dmem_rd_data(dmem_rd_data),
    .start_npu(start_npu),
    .done_processing(done_processing), .npu_done(npu_done)
);

// ── Opcodes ───────────────────────────────────────────────────
localparam [5:0]
    OP_LOAD_ACT  = 6'b000000, OP_LOAD_WGT  = 6'b000001,
    OP_LOAD_BIAS = 6'b000010, OP_LOAD_SCL  = 6'b000011,
    OP_CONV      = 6'b000100, OP_ADD_BIAS  = 6'b000101,
    OP_REQ       = 6'b000110, OP_RELU      = 6'b000111,
    OP_STORE     = 6'b001001, OP_HALT      = 6'b111111;

// ── Instruction builders ──────────────────────────────────────
function automatic [31:0] mk_load(
    input [5:0] op, input [3:0] bsel,
    input [7:0] ab, input [7:0] aa);
    mk_load = {op, bsel, 6'b0, ab, aa};
endfunction

function automatic [31:0] mk_comp(
    input [5:0] op, input tr, input [4:0] ns, input bp);
    mk_comp = {op, 20'b0, tr, ns, bp};
endfunction

// ── Memory tasks ──────────────────────────────────────────────
task write_imem(input [6:0] addr, input [31:0] d);
    @(negedge clk);
    imem_wr_en = 1; imem_wr_we = 4'hF;
    imem_wr_addr = addr; imem_wr_data = d;
    @(negedge clk);
    imem_wr_en = 0; imem_wr_we = 4'h0;
endtask

task write_dmem(input [7:0] addr, input [31:0] d);
    @(negedge clk);
    dmem_wr_en = 1; dmem_wr_be = 4'hF;
    dmem_wr_addr = addr; dmem_wr_data = d;
    @(negedge clk);
    dmem_wr_en = 0;
endtask

task read_dmem(input [7:0] addr, output [31:0] d);
    @(negedge clk);
    dmem_rd_en = 1; dmem_rd_addr = addr;
    @(posedge clk); @(posedge clk); #1;
    d = dmem_rd_data;
    @(negedge clk);
    dmem_rd_en = 0;
endtask

// ── Checker ───────────────────────────────────────────────────
int pass_cnt = 0, fail_cnt = 0;

task check(input [31:0] got, exp, input string label);
    if (got === exp) begin
        $display("  [PASS] %-30s got=0x%08X", label, got);
        pass_cnt++;
    end else begin
        $display("  [FAIL] %-30s got=0x%08X  exp=0x%08X", label, got, exp);
        fail_cnt++;
    end
endtask

// ── Main test ─────────────────────────────────────────────────
integer i;
logic [31:0] rd;

initial begin
    // Init
    {rst_n, load_imem, load_dmem, imem_wr_en, imem_wr_we,
     dmem_wr_en, dmem_rd_en, start_npu} = '0;
    dmem_wr_be = 4'hF;
    {imem_wr_addr, imem_wr_data, dmem_wr_addr,
     dmem_wr_data, dmem_rd_addr} = '0;

    $display("==============================================");
    $display("  NPU Testbench  — all-ones 8x8 matmul");
    $display("  Expected result per element: 8 (0x08)");
    $display("==============================================");

    // Reset
    repeat(5) @(negedge clk); rst_n = 1; repeat(2) @(negedge clk);

    // ── Phase 1: Load DMEM ───────────────────────────────────
    load_dmem = 1;
    $display("[TB] Phase 1: Loading DMEM...");

    for (i=0; i<16; i++) write_dmem(8'h00+i, 32'h0101_0101); // ACT
    for (i=0; i<16; i++) write_dmem(8'h10+i, 32'h0101_0101); // WGT
    for (i=0; i<8;  i++) write_dmem(8'h20+i, 32'h0000_0000); // BIAS
    write_dmem(8'h28, 32'h0000_0001);                          // M0=1

    load_dmem = 0;

    // ── Phase 2: Load IMEM (program) ────────────────────────
    load_imem = 1;
    $display("[TB] Phase 2: Loading program...");

    write_imem(7'd0, mk_load(OP_LOAD_WGT,  4'h0, 8'h00, 8'h10)); // WGT@0x10
    write_imem(7'd1, mk_load(OP_LOAD_ACT,  4'h0, 8'h00, 8'h00)); // ACT@0x00
    write_imem(7'd2, mk_load(OP_LOAD_BIAS, 4'h0, 8'h00, 8'h20)); // BIAS@0x20
    write_imem(7'd3, mk_load(OP_LOAD_SCL,  4'h0, 8'h00, 8'h28)); // SCL@0x28
    write_imem(7'd4, mk_comp(OP_CONV,      0, 5'd0, 0));          // CONV
    write_imem(7'd5, mk_comp(OP_ADD_BIAS,  0, 5'd0, 0));          // ADD_BIAS
    write_imem(7'd6, mk_comp(OP_REQ,       0, 5'd0, 0));          // REQ n=0
    write_imem(7'd7, mk_comp(OP_RELU,      0, 5'd0, 0));          // RELU
    write_imem(7'd8, mk_load(OP_STORE, 4'b0001, 8'h00, 8'h40));   // STORE relu→0x40
    write_imem(7'd9, {OP_HALT, 26'h0});                            // HALT

    load_imem = 0;

    // ── Phase 3: Run ─────────────────────────────────────────
    $display("[TB] Phase 3: Starting NPU...");
    @(negedge clk); start_npu = 1;
    @(negedge clk); start_npu = 0;

    // ── Phase 4: Wait for HALT ───────────────────────────────
    $display("[TB] Phase 4: Waiting for npu_done...");
    fork
        begin : w
            wait(npu_done === 1'b1);
            $display("[TB] npu_done @ %0t ns", $time);
        end
        begin : t
            #2_000_000;
            $display("[FAIL] TIMEOUT waiting for npu_done");
            fail_cnt++; disable w;
        end
    join_any
    disable w; disable t;
    repeat(4) @(negedge clk);

    // ── Phase 5: Verify ──────────────────────────────────────
    $display("[TB] Phase 5: Verifying SRAM[0x40-0x4F]...");
    load_dmem = 1;
    for (i = 0; i < 16; i++) begin
        read_dmem(8'h40 + i, rd);
        check(rd, 32'h0808_0808, $sformatf("SRAM[0x%02X]", 8'h40+i));
    end
    load_dmem = 0;

    // ── Summary ──────────────────────────────────────────────
    $display("==============================================");
    $display("  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    $display(fail_cnt==0 ? "  *** ALL PASS — OK FOR BACKEND ***"
                         : "  *** FAILURES — FIX BEFORE BACKEND ***");
    $display("==============================================");
    $finish;
end

// ── Global watchdog ───────────────────────────────────────────
initial begin #5_000_000; $display("GLOBAL TIMEOUT"); $finish; end

// ── Waveform ──────────────────────────────────────────────────
initial begin $dumpfile("npu_top_tb.vcd"); $dumpvars(0, tb_npu_top); end

endmodule