// ================================================================
//  npu_top — Neural Processing Unit Top-Level
//
//  Architecture:
//    Host → SRAM/IMEM → CU → SA (8×8) → ACC → BIAS → REQ → ReLU → STORE → SRAM
//
//  Memory:
//    IMEM : RAM32      — 32×32-bit instruction memory
//    DMEM : RAM256x32  — 256×32-bit dual-port data SRAM
//
//  Datapath:
//    LOAD_ACT/WGT  → Ping-Pong Buffers → Systolic Array (8×8)
//    SA output     → acc_buffer → bias_adder → pbias_buffer
//                 → req_unit   → preq_buffer
//                 → relu_unit  → relu_buffer
//                 → store_engine → SRAM
//
//  SRAM Port 0 mux priority (select_apb_npu / select_apb_npu_addr):
//    host wr > store_engine > CU reads
//
//  Parameters:
//    DATA_W     : activation/weight width (default 8, INT8)
//    DATA_W_PATH: accumulator width       (default 32, INT32)
//    SA_SIZE    : systolic array dimension (default 8)
//
// ================================================================

module npu_top #(
    parameter DATA_W      = 8,
    parameter DATA_W_PATH = 32,
    parameter SA_SIZE     = 8,
    parameter INST_ADDR_W = 5,
    parameter INST_DATA_W = 32,
    parameter SRAM_DATA_W = 32,
    parameter SRAM_ADDR_W = 8


)(
    input  logic        clk,
    input  logic        rst_n,

    // ── Host memory load mode ─────────────────────────────────
    input  logic        load_imem,       // HIGH while host loads instruction memory
    input  logic        load_dmem,       // HIGH while host loads data SRAM
    input  logic        dmem_rd_host,

    // ── Instruction memory write port (host → IMEM) ───────────
    input  logic [3:0]  imem_wr_we,      // byte-enable (4'hF = full word)
    input  logic        imem_wr_en,      // write strobe (1-cycle pulse)
    input  logic [INST_ADDR_W-1:0]  imem_wr_addr,    // word address
    input  logic [INST_DATA_W-1:0] imem_wr_data,    // instruction word

    // ── Data SRAM write port (host → DMEM) ───────────────────
    input  logic        dmem_wr_en,      // write strobe (1-cycle pulse)
    input  logic [3:0]  dmem_wr_be,      // byte enable (4-bit mask)
    input  logic [SRAM_ADDR_W-1:0]  dmem_wr_addr,    // word address (0-255)
    input  logic [SRAM_DATA_W-1:0] dmem_wr_data,    // write data

    // ── Data SRAM read port (host ← DMEM) ────────────────────
    input  logic        dmem_rd_en,      // read enable
    input  logic [SRAM_ADDR_W-1:0]  dmem_rd_addr,    // word address (0-255)
    output logic [SRAM_DATA_W-1:0] dmem_rd_data,    // read data (combinational from port 0)

    // ── NPU control ───────────────────────────────────────────
    input  logic        start_npu,       // pulse to start NPU execution
    output logic        done_processing, // when all instructions in instr memory is finsihed like asking new instructions
    output logic        npu_done         // HIGH when HALT instruction reached
);

// ================================================================
//  Local Parameters
// ================================================================

// SRAM geometry
localparam SRAM_BE_W   = SRAM_DATA_W / 8;   // 4

// Instruction memory geometry
localparam INST_BE_W   = 4;

// Ping-Pong buffer geometry (shared by ACT and WGT)
localparam PP_ROWS      = SA_SIZE;                  // 8
localparam PP_COLS      = SA_SIZE;                  // 8
localparam PP_WIDTH     = DATA_W;                   // 8-bit INT8
localparam PP_WR_DATA_W = SRAM_DATA_W;              // 32-bit write (4 bytes per SRAM word)
localparam PP_WR_ADDR_W = 4;                        // 4-bit addr (0-15, 16 words per tile)
localparam PP_RD_ROW_W  = $clog2(PP_ROWS);          // 3-bit row select (0-7)
localparam PP_RD_DATA_W = PP_COLS * PP_WIDTH;       // 64-bit full-row output

// Misc
localparam DATA_W_OUT = 32;
localparam SRAM_AW    = 8;
localparam C_WIDTH    = 5;

// ================================================================
//  Internal Signals
// ================================================================

// ── Data SRAM (RAM256x32) — Port 0 RW ────────────────────────
logic [SRAM_BE_W-1:0]   sram_we0;
logic                   sram_en0;
logic [SRAM_ADDR_W-1:0] sram_a0;
logic [SRAM_DATA_W-1:0] sram_di0;
logic [SRAM_DATA_W-1:0] sram_do0;

// ── Data SRAM — Port 1 R ──────────────────────────────────────
logic                   sram_en1;
logic [SRAM_ADDR_W-1:0] sram_a1;
logic [SRAM_DATA_W-1:0] sram_do1;

// ── Instruction Memory (RAM32) — Port 0 RW ───────────────────
logic [INST_BE_W-1:0]   inst_we0;
logic                   inst_en0;
logic [INST_ADDR_W-1:0] inst_a0;
logic [INST_DATA_W-1:0] inst_di0;
logic [INST_DATA_W-1:0] inst_do0;

// ── ACT Ping-Pong Buffer ──────────────────────────────────────
logic                    act_wr_en;
logic [PP_WR_ADDR_W-1:0] act_wr_byte_addr;
logic [PP_WR_DATA_W-1:0] act_wr_data;
logic [PP_RD_ROW_W-1:0]  act_rd_row;
logic [PP_RD_DATA_W-1:0] act_rd_data;
logic                    act_swap;
logic                    act_fill_done;
logic                    act_active_bank;

// ── WGT Ping-Pong Buffer ──────────────────────────────────────
logic                    wgt_wr_en;
logic [PP_WR_ADDR_W-1:0] wgt_wr_byte_addr;
logic [PP_WR_DATA_W-1:0] wgt_wr_data;
logic [PP_RD_ROW_W-1:0]  wgt_rd_row;
logic [PP_RD_DATA_W-1:0] wgt_rd_data;
logic                    wgt_swap;
logic                    wgt_fill_done;
logic                    wgt_active_bank;

// ── CU → IMEM/SRAM mux controls ──────────────────────────────
logic        imem_rd_wr;          // 0=host writes IMEM, 1=CU reads IMEM
logic        select_apb_npu;      // 0=store drives di0, 1=host drives di0
logic [1:0]  select_apb_npu_addr; // SRAM address mux select

// ── CU → SRAM port signals ────────────────────────────────────
logic                   cu_sram_en0;
logic [SRAM_ADDR_W-1:0] cu_sram_a0;
logic                   cu_sram_en1;
logic [SRAM_ADDR_W-1:0] cu_sram_a1;

// ── CU instruction fetch ──────────────────────────────────────
logic [INST_ADDR_W-1:0] PC;
logic [INST_DATA_W-1:0] inst_data;
logic                   inst_rd_en;

logic                   addr_st_rel;

// ── scale register ────────────────────────────────────────────
logic scale_wr_en;
logic [DATA_W_PATH-1:0] scale;

// ── acc_buffer (SA output capture) ───────────────────────────
logic                        bacc_wr_en;
logic [$clog2(SA_SIZE)-1:0]  bacc_addr;
logic [$clog2(SA_SIZE)-1:0]  acc_rd_addr;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] acc_rd_data;

// ── bias_buffer ───────────────────────────────────────────────
logic                        bb_wr_en;
logic [$clog2(SA_SIZE)-1:0]  bb_wr_addr;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] bias;

// ── bias_adder ────────────────────────────────────────────────
logic                        ba_start;
logic                        ba_done;
logic                        pb_wr_en;
logic [$clog2(SA_SIZE)-1:0]  pb_wr_addr;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] pb_wr_data;

// ── pbias_buffer ──────────────────────────────────────────────
logic [$clog2(SA_SIZE)-1:0]  pb_rd_addr;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] pb_rd_data;

// ── req_unit ──────────────────────────────────────────────────
logic        req_start;
logic        req_done;
logic [4:0]  n_scale;
logic                        preq_wr_en;
logic [$clog2(SA_SIZE)-1:0]  preq_wr_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      preq_wr_data;

// ── preq_buffer ───────────────────────────────────────────────
logic [$clog2(SA_SIZE)-1:0]  preq_rd_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      preq_rd_data;
logic [$clog2(SA_SIZE)-1:0]    preq_rd_addr_rel ;
logic [$clog2(SA_SIZE)-1:0]    preq_rd_addr_st ;

// ── relu_unit ─────────────────────────────────────────────────
logic        relu_start;
logic        relu_done;
logic                        relu_wr_en;
logic [$clog2(SA_SIZE)-1:0]  relu_wr_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      relu_wr_data;

// ── relu_buffer ───────────────────────────────────────────────
logic [$clog2(SA_SIZE)-1:0]  relu_rd_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      relu_rd_data;

// ── store_engine ──────────────────────────────────────────────
logic        st_start;
logic        st_done;
logic        st_buf_sel;
logic [SRAM_AW-1:0]  st_tile_addr;
logic [SRAM_BE_W-1:0] st_sram_we0;
logic        st_sram_en0;
logic [SRAM_AW-1:0]      st_sram_a0;
logic [DATA_W_PATH-1:0]  st_sram_di0;

// ── Systolic Array ────────────────────────────────────────────
logic [SA_SIZE-1:0][DATA_W-1:0]      act_in;
logic [SA_SIZE-1:0][DATA_W-1:0]      weight_in;
logic                   sa_transpose_en;
logic                   sa_start;
logic                   sa_valid_in;
logic                   sa_valid_out;
logic                   sa_busy;
logic                   sa_done;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] psum_out;

// ================================================================
//  Continuous Assignments
// ================================================================

// IMEM connections
assign inst_di0      = imem_wr_data;
assign inst_data     = inst_do0;
assign inst_we0 = load_imem ? imem_wr_we : 4'b0000;

// SRAM port 1: CU owns entirely (read-only for NPU loads)
assign sram_en1 = cu_sram_en1;
assign sram_a1  = cu_sram_a1;

// Host read data comes directly from SRAM port 0 output
assign dmem_rd_data = sram_do0;

// Unpack 64-bit ping-pong row into 8×8-bit arrays for SA
genvar i;
generate
    for (i = 0; i < SA_SIZE; i++) begin : ACT_UNPACK
        assign act_in[i] = act_rd_data[i*DATA_W +: DATA_W];
    end
    for (i = 0; i < SA_SIZE; i++) begin : WGT_UNPACK
        assign weight_in[i] = wgt_rd_data[i*DATA_W +: DATA_W];
    end
endgenerate

// ================================================================
//  Module Instantiations
// ================================================================

// ── Control Unit ─────────────────────────────────────────────
CU #() cu (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (start_npu),

    .load_imem        (load_imem),
    .load_dmem        (load_dmem),
    .dmem_rd_host       (dmem_rd_host),

    .imem_rd_wr       (imem_rd_wr),
    .select_apb_npu      (select_apb_npu),
    .select_apb_npu_addr (select_apb_npu_addr),

    .inst_data        (inst_data),
    .inst_rd_en       (inst_rd_en),
    .PC               (PC),

    .sram_en0         (cu_sram_en0),
    .sram_a0          (cu_sram_a0),
    .sram_do0         (sram_do0),

    .sram_en1         (cu_sram_en1),
    .sram_a1          (cu_sram_a1),
    .sram_do1         (sram_do1),

    .act_wr_en        (act_wr_en),
    .act_wr_byte_addr (act_wr_byte_addr),
    .act_wr_data      (act_wr_data),
    .act_swap         (act_swap),
    .act_fill_done    (act_fill_done),

    .wgt_wr_en        (wgt_wr_en),
    .wgt_wr_byte_addr (wgt_wr_byte_addr),
    .wgt_wr_data      (wgt_wr_data),
    .wgt_swap         (wgt_swap),
    .wgt_fill_done    (wgt_fill_done),

    .act_rd_row       (act_rd_row),
    .wgt_rd_row       (wgt_rd_row),

    .scale_wr_en      (scale_wr_en),

    .sa_valid_out     (sa_valid_out),
    .sa_busy          (sa_busy),
    .sa_done          (sa_done),
    .sa_start         (sa_start),
    .sa_valid_in      (sa_valid_in),
    .sa_transpose_en  (sa_transpose_en),

    .bacc_wr_en       (bacc_wr_en),
    .bacc_addr        (bacc_addr),

    .ba_start         (ba_start),
    .ba_done          (ba_done),

    .bb_wr_en         (bb_wr_en),
    .bb_wr_addr       (bb_wr_addr),

    .req_start        (req_start),
    .req_done         (req_done),
    .n_scale          (n_scale),

    .relu_start       (relu_start),
    .relu_done        (relu_done),

    .addr_st_rel(addr_st_rel),

    .st_buf_sel       (st_buf_sel),
    .st_tile_addr     (st_tile_addr),
    .st_start         (st_start),
    .st_done          (st_done),

    .done_processing  (done_processing),
    .npu_done         (npu_done)
);

// ── IMEM enable mux: host write (0) vs CU read (1) ───────────
mux2x1 #(1) mux_imem_en (
    .a   (imem_wr_en),
    .b   (inst_rd_en),
    .sel (imem_rd_wr),
    .y   (inst_en0)
);

// ── IMEM address mux: host addr (0) vs PC (1) ────────────────
mux2x1 #(INST_ADDR_W) mux_imem_addr (
    .a   (imem_wr_addr),
    .b   (PC),
    .sel (imem_rd_wr),
    .y   (inst_a0)
);

// ── Instruction Memory ────────────────────────────────────────
RAM32_ u_inst_mem (
    .CLK (clk),
    .WE0 (inst_we0),
    .EN0 (inst_en0),
    .A0  (inst_a0),
    .Di0 (inst_di0),
    .Do0 (inst_do0)
);

// ── SRAM di0 mux: store_engine (0) vs host (1) ───────────────
mux2x1 #(SRAM_DATA_W) mux_sram_di0 (
    .a   (st_sram_di0),
    .b   (dmem_wr_data),
    .sel (select_apb_npu),
    .y   (sram_di0)
);

// ── SRAM address mux (4-way) ──────────────────────────────────
//   00: store_engine addr   01: host read addr
//   10: CU addr             11: host write addr
mux4x1 #(SRAM_ADDR_W) mux_sram_addr (
    .a   (st_sram_a0),
    .b   (dmem_rd_addr),
    .c   (cu_sram_a0),
    .d   (dmem_wr_addr),
    .sel (select_apb_npu_addr),
    .y   (sram_a0)
);

mux4x1 #(1) mux_sram_en (
    .a   (st_sram_en0),
    .b   (dmem_rd_en),
    .c   (cu_sram_en0),
    .d   (dmem_wr_en),
    .sel (select_apb_npu_addr),
    .y   (sram_en0)
);

mux4x1 #(4) mux_sram_wr (
    .a   (st_sram_we0),
    .b   (4'b0000),
    .c   (4'b0000),
    .d   (dmem_wr_be),
    .sel (select_apb_npu_addr),
    .y   (sram_we0)
);

// ── Data SRAM (dual-port: 1RW + 1R) ──────────────────────────
RAM128x32_1RW1R u_data_sram (
    .CLK (clk),
    .WE0 (sram_we0),
    .EN0 (sram_en0),
    .A0  (sram_a0),
    .Di0 (sram_di0),
    .Do0 (sram_do0),
    .EN1 (sram_en1),
    .A1  (sram_a1),
    .Do1 (sram_do1)
);

// ── ACT Ping-Pong Buffer ──────────────────────────────────────
pingpong_buffer #(
    .ROWS  (PP_ROWS),
    .COLS  (PP_COLS),
    .WIDTH (PP_WIDTH)
) u_act_pp (
    .clk          (clk),
    .rst_n        (rst_n),
    .wr_en        (act_wr_en),
    .wr_byte_addr (act_wr_byte_addr),
    .wr_data      (act_wr_data),
    .rd_row       (act_rd_row),
    .rd_data      (act_rd_data),
    .swap         (act_swap),
    .fill_done    (act_fill_done),
    .active_bank  (act_active_bank)
);

// ── WGT Ping-Pong Buffer ──────────────────────────────────────
pingpong_buffer #(
    .ROWS  (PP_ROWS),
    .COLS  (PP_COLS),
    .WIDTH (PP_WIDTH)
) u_wgt_pp (
    .clk          (clk),
    .rst_n        (rst_n),
    .wr_en        (wgt_wr_en),
    .wr_byte_addr (wgt_wr_byte_addr),
    .wr_data      (wgt_wr_data),
    .rd_row       (wgt_rd_row),
    .rd_data      (wgt_rd_data),
    .swap         (wgt_swap),
    .fill_done    (wgt_fill_done),
    .active_bank  (wgt_active_bank)
);

// ── Bias Buffer (loaded by LOAD_BIAS instruction) ─────────────
bias_buffer #(SA_SIZE, DATA_W_PATH) u_bias_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (bb_wr_en),
    .wr_addr (bb_wr_addr),
    .wr_data (sram_do1),    // bias values come from SRAM port 1
    .rd_data (bias)
);

// ── Scale Register (loaded by LOAD_SCL instruction) ───────────
scale_reg #() u_scale_reg (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en     (scale_wr_en),
    .scale     (sram_do1),  // M0 comes from SRAM port 1
    .scale_out (scale)
);

// ── Systolic Array 8×8 ────────────────────────────────────────
SA_NxN_top #(DATA_W, DATA_W_PATH, SA_SIZE) u_sa (
    .clk          (clk),
    .rst_n        (rst_n),
    .act_in       (act_in),
    .weight_in    (weight_in),
    .transpose_en (sa_transpose_en),
    .start        (sa_start),
    .valid_in     (sa_valid_in),
    .valid_out    (sa_valid_out),
    .busy         (sa_busy),
    .done         (sa_done),
    .psum_out     (psum_out)
);

// ── Accumulation Buffer (SA output → INT32) ───────────────────
acc_buffer #(SA_SIZE, DATA_W_PATH) u_acc_buf (
    .clk      (clk),
    .rst_n    (rst_n),
    .wr_en    (bacc_wr_en),
    .wr_addr  (bacc_addr),
    .wr_data  (psum_out),
    .rd_addr  (acc_rd_addr),
    .rd_data  (acc_rd_data)
);

// ── Bias Adder (acc + bias → pbias) ──────────────────────────
bias_adder #(SA_SIZE, DATA_W_PATH) u_bias_adder (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (ba_start),
    .done         (ba_done),
    .busy         (),
    .acc_rd_addr  (acc_rd_addr),
    .acc_rd_data  (acc_rd_data),
    .bias_rd_data (bias),
    .pb_wr_en     (pb_wr_en),
    .pb_wr_addr   (pb_wr_addr),
    .pb_wr_data   (pb_wr_data)
);

// ── Post-Bias Buffer ──────────────────────────────────────────
pbias_buffer #(SA_SIZE, DATA_W_PATH) u_pbias_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (pb_wr_en),
    .wr_addr (pb_wr_addr),
    .wr_data (pb_wr_data),
    .rd_addr (pb_rd_addr),
    .rd_data (pb_rd_data)
);

// ── Requantization Unit (INT32 → INT8) ────────────────────────
req_unit #(SA_SIZE, DATA_W_PATH, C_WIDTH) u_req (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (req_start),
    .done         (req_done),
    .busy         (),
    .b            (scale),      // M0 multiplier from scale_reg
    .c            (n_scale),    // shift amount from instruction
    .pb_rd_addr   (pb_rd_addr),
    .pb_rd_data   (pb_rd_data),
    .preq_wr_en   (preq_wr_en),
    .preq_wr_addr (preq_wr_addr),
    .preq_wr_data (preq_wr_data)
);

// ── Post-REQ Buffer (INT8) ────────────────────────────────────
preq_buffer #(SA_SIZE) u_preq_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (preq_wr_en),
    .wr_addr (preq_wr_addr),
    .wr_data (preq_wr_data),
    .rd_addr (preq_rd_addr),
    .rd_data (preq_rd_data)
);

// ── ReLU Unit ─────────────────────────────────────────────────
relu_unit #(SA_SIZE, DATA_W) u_relu (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (relu_start),
    .done         (relu_done),
    .busy         (),
    .preq_rd_addr (preq_rd_addr_rel),
    .preq_rd_data (preq_rd_data),
    .relu_wr_en   (relu_wr_en),
    .relu_wr_addr (relu_wr_addr),
    .relu_wr_data (relu_wr_data)
);

// ── Post-ReLU Buffer (INT8) ───────────────────────────────────
relu_buffer #(SA_SIZE, DATA_W) u_relu_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (relu_wr_en),
    .wr_addr (relu_wr_addr),
    .wr_data (relu_wr_data),
    .rd_addr (relu_rd_addr),
    .rd_data (relu_rd_data)
);

mux2x1 #($clog2(SA_SIZE)) mux_to_rd_addr (
.a(preq_rd_addr_rel),
.b(preq_rd_addr_st),
.sel(addr_st_rel),
.y(preq_rd_addr)
);

// ── Store Engine (buffer → SRAM) ─────────────────────────────
// Reads selected buffer (preq or relu), packs 8×INT8 into 2×32-bit
// words, and writes back to SRAM port 0 (via mux in npu_top)
store_engine #(SA_SIZE, DATA_W, SRAM_AW) u_store (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (st_start),
    .done         (st_done),
    .busy         (),
    .buf_sel      (st_buf_sel),     // 0=preq_buf, 1=relu_buf
    .base_addr    (st_tile_addr),   // SRAM base address from instruction
    .preq_rd_addr (preq_rd_addr_st),
    .preq_rd_data (preq_rd_data),
    .relu_rd_addr (relu_rd_addr),
    .relu_rd_data (relu_rd_data),
    .st_sram_we0  (st_sram_we0),
    .st_sram_en0  (st_sram_en0),
    .st_sram_a0   (st_sram_a0),
    .st_sram_di0  (st_sram_di0)
);

endmodule
