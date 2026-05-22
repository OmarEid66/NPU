module npu_top #(
    parameter DATA_W      = 8,
    parameter DATA_W_PATH = 32,
    parameter SA_SIZE     = 4,
    parameter INST_ADDR_W = 5,
    parameter INST_DATA_W = 32,
    parameter SRAM_DATA_W = 32,
    parameter SRAM_ADDR_W = 6       // 128-word DMEM default
)(
    input  logic        clk,
    input  logic        rst_n,

    // ── Host memory load mode ─────────────────────────────────
    input  logic        load_imem,       
    input  logic        load_dmem,       
    input  logic        dmem_rd_host,

    // ── Instruction memory write port (host → IMEM) ───────────
    input  logic [3:0]  imem_wr_we,      
    input  logic        imem_wr_en,      
    input  logic [INST_ADDR_W-1:0]  imem_wr_addr,    
    input  logic [INST_DATA_W-1:0] imem_wr_data,    

    // ── Data SRAM write port (host → DMEM) ───────────────────
    input  logic        dmem_wr_en,      
    input  logic [3:0]  dmem_wr_be,      
    input  logic [SRAM_ADDR_W-1:0]  dmem_wr_addr,    
    input  logic [SRAM_DATA_W-1:0] dmem_wr_data,    

    // ── Data SRAM read port (host ← DMEM) ────────────────────
    input  logic        dmem_rd_en,      
    input  logic [SRAM_ADDR_W-1:0]  dmem_rd_addr,    
    output logic [SRAM_DATA_W-1:0] dmem_rd_data,    

    // ── NPU control ───────────────────────────────────────────
    input  logic        start_npu,       
    output logic        done_processing, 
    output logic        npu_done         
);

localparam SRAM_BE_W   = SRAM_DATA_W / 8;   
localparam INST_BE_W   = 4;
localparam PP_ROWS      = SA_SIZE;                  
localparam PP_COLS      = SA_SIZE;
localparam PP_WIDTH     = DATA_W;                   
localparam PP_WR_DATA_W = SRAM_DATA_W;              
localparam PP_WR_ADDR_W = 3;
localparam PP_RD_ROW_W  = $clog2(PP_ROWS);          
localparam PP_RD_DATA_W = PP_COLS * PP_WIDTH;       

localparam DATA_W_OUT = 32;
localparam C_WIDTH    = 5;

logic [SRAM_BE_W-1:0]   sram_we0;
logic                   sram_en0;
logic [SRAM_ADDR_W-1:0] sram_a0;
logic [SRAM_DATA_W-1:0] sram_di0;
logic [SRAM_DATA_W-1:0] sram_do0;

logic                   sram_en1;
logic [SRAM_ADDR_W-1:0] sram_a1;
logic [SRAM_DATA_W-1:0] sram_do1;

logic [INST_BE_W-1:0]   inst_we0;
logic                   inst_en0;
logic [INST_ADDR_W-1:0] inst_a0;
logic [INST_DATA_W-1:0] inst_di0;
logic [INST_DATA_W-1:0] inst_do0;

logic                    act_wr_en;
logic [PP_WR_ADDR_W-1:0] act_wr_byte_addr;
logic [PP_WR_DATA_W-1:0] act_wr_data;
logic [PP_RD_ROW_W-1:0]  act_rd_row;
logic [PP_RD_DATA_W-1:0] act_rd_data;
logic                    act_swap;
logic                    act_fill_done;
logic                    act_active_bank;

logic                    wgt_wr_en;
logic [PP_WR_ADDR_W-1:0] wgt_wr_byte_addr;
logic [PP_WR_DATA_W-1:0] wgt_wr_data;
logic [PP_RD_ROW_W-1:0]  wgt_rd_row;
logic [PP_RD_DATA_W-1:0] wgt_rd_data;
logic                    wgt_swap;
logic                    wgt_fill_done;
logic                    wgt_active_bank;

logic        imem_rd_wr;          
logic        select_apb_npu;
logic [1:0]  select_apb_npu_addr; 

logic                   cu_sram_en0;
logic [SRAM_ADDR_W-1:0] cu_sram_a0;
logic                   cu_sram_en1;
logic [SRAM_ADDR_W-1:0] cu_sram_a1;

logic [INST_ADDR_W-1:0] PC;
logic [INST_DATA_W-1:0] inst_data;
logic                   inst_rd_en;
logic                   addr_st_rel;

logic scale_wr_en;
logic [DATA_W_PATH-1:0] scale;

logic                        bb_wr_en;
logic [$clog2(SA_SIZE)-1:0]  bb_wr_addr;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] bias;

logic [4:0]  n_scale;
logic                        preq_wr_en;
logic [$clog2(SA_SIZE)-1:0]  preq_wr_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      preq_wr_data;

logic [$clog2(SA_SIZE)-1:0]  preq_rd_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      preq_rd_data;
logic [$clog2(SA_SIZE)-1:0]    preq_rd_addr_rel ;
logic [$clog2(SA_SIZE)-1:0]    preq_rd_addr_st ;

logic        relu_start;
logic        relu_done;
logic                        relu_wr_en;
logic [$clog2(SA_SIZE)-1:0]  relu_wr_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      relu_wr_data;

logic [$clog2(SA_SIZE)-1:0]  relu_rd_addr;
logic [SA_SIZE-1:0][DATA_W-1:0]      relu_rd_data;

logic        st_start;
logic        st_done;
logic        st_buf_sel;
logic [SRAM_ADDR_W-1:0]  st_tile_addr;         
logic [SRAM_BE_W-1:0]    st_sram_we0;
logic                    st_sram_en0;
logic [SRAM_ADDR_W-1:0]  st_sram_a0;           
logic [DATA_W_PATH-1:0]  st_sram_di0;

logic [SA_SIZE-1:0][DATA_W-1:0]      act_in;
logic [SA_SIZE-1:0][DATA_W-1:0]      weight_in;
logic                   sa_transpose_en;
logic                   sa_start;
logic                   sa_valid_in;
logic                   sa_valid_out;
logic                   sa_busy;
logic                   sa_done;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] psum_out;

// Pipeline interconnects
logic bias_adder_valid_out;
logic [SA_SIZE-1:0][DATA_W_PATH-1:0] bias_added_data;


assign inst_di0      = imem_wr_data;
assign inst_data     = inst_do0;
assign inst_we0 = load_imem ? imem_wr_we : 4'b0000;

assign sram_en1 = cu_sram_en1;
assign sram_a1  = cu_sram_a1;
assign dmem_rd_data = sram_do0;

genvar i;
generate
    for (i = 0; i < SA_SIZE; i++) begin : ACT_UNPACK
        assign act_in[i] = act_rd_data[i*DATA_W +: DATA_W];
    end
    for (i = 0; i < SA_SIZE; i++) begin : WGT_UNPACK
        assign weight_in[i] = wgt_rd_data[i*DATA_W +: DATA_W];
    end
endgenerate

CU #(
    .INST_DATA_W(INST_DATA_W),
    .INST_ADDR_W(INST_ADDR_W),
    .SA_SIZE(SA_SIZE),
    .SRAM_ADDR_W(SRAM_ADDR_W)    
) cu (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (start_npu),

    .load_imem        (load_imem),
    .load_dmem        (load_dmem),
    .dmem_rd_host     (dmem_rd_host),

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

    // ACC/PBias Ports Removed

    .bb_wr_en         (bb_wr_en),
    .bb_wr_addr       (bb_wr_addr),

    .n_scale          (n_scale),

    .relu_start       (relu_start),
    .relu_done        (relu_done),

    .addr_st_rel      (addr_st_rel),

    .st_buf_sel       (st_buf_sel),
    .st_tile_addr     (st_tile_addr),
    .st_start         (st_start),
    .st_done          (st_done),

    .done_processing  (done_processing),
    .npu_done         (npu_done)
);

mux2x1 #(1) mux_imem_en (
    .a   (imem_wr_en),
    .b   (inst_rd_en),
    .sel (imem_rd_wr),
    .y   (inst_en0)
);

mux2x1 #(INST_ADDR_W) mux_imem_addr (
    .a   (imem_wr_addr),
    .b   (PC),
    .sel (imem_rd_wr),
    .y   (inst_a0)
);

RAM32_ u_inst_mem (
    .CLK (clk),
    .WE0 (inst_we0),
    .EN0 (inst_en0),
    .A0  (inst_a0),
    .Di0 (inst_di0),
    .Do0 (inst_do0)
);

mux2x1 #(SRAM_DATA_W) mux_sram_di0 (
    .a   (st_sram_di0),
    .b   (dmem_wr_data),
    .sel (select_apb_npu),
    .y   (sram_di0)
);

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

RAM64x32_1RW1R u_data_sram (
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

pingpong_buffer #(
    .ROWS  (PP_ROWS),
    .COLS  (PP_COLS),
    .WIDTH (PP_WIDTH),
    .ADDR_W(PP_WR_ADDR_W)         
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

pingpong_buffer #(
    .ROWS  (PP_ROWS),
    .COLS  (PP_COLS),
    .WIDTH (PP_WIDTH),
    .ADDR_W(PP_WR_ADDR_W)         
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

bias_buffer #(SA_SIZE, DATA_W_PATH) u_bias_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (bb_wr_en),
    .wr_addr (bb_wr_addr),
    .wr_data (sram_do1),
    .rd_data (bias)
);

scale_reg #() u_scale_reg (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en     (scale_wr_en),
    .scale     (sram_do1),  
    .scale_out (scale)
);

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

// ────────────────────────────────────────────────────────────
// STREAMING PIPELINE: SA -> Bias -> Req
// ────────────────────────────────────────────────────────────

bias_adder #(SA_SIZE, DATA_W_PATH) u_bias_adder (
    .clk          (clk),
    .rst_n        (rst_n),
    .valid_in     (sa_valid_out),
    .psum_in      (psum_out),
    .bias_in      (bias),
    .valid_out    (bias_adder_valid_out),
    .data_out     (bias_added_data)
);

req_unit #(SA_SIZE, DATA_W_PATH, C_WIDTH) u_req (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (sa_start),
    .valid_in     (bias_adder_valid_out),
    .data_in      (bias_added_data),
    .b            (scale),
    .c            (n_scale),
    .valid_out    (preq_wr_en),
    .preq_wr_addr (preq_wr_addr),
    .data_out     (preq_wr_data)
);

// ────────────────────────────────────────────────────────────

preq_buffer #(SA_SIZE) u_preq_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (preq_wr_en),
    .wr_addr (preq_wr_addr),
    .wr_data (preq_wr_data),
    .rd_addr (preq_rd_addr),
    .rd_data (preq_rd_data)
);

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

store_engine #(
    .SA_SIZE(SA_SIZE), 
    .DATA_WIDTH(DATA_W), 
    .SRAM_AW(SRAM_ADDR_W)        
) u_store (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (st_start),
    .done         (st_done),
    .busy         (),
    .buf_sel      (st_buf_sel),     
    .base_addr    (st_tile_addr),   
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