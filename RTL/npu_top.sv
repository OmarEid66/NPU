module npu_top #(parameter DATA_W = 8, parameter DATA_W_PATH = 32, parameter SA_SIZE = 8) 
(
input       clk,
input       rst_n,
);


// SRAM Parameters
localparam SRAM_DATA_W = 32;
localparam SRAM_ADDR_W = 8;          
localparam SRAM_BE_W   = SRAM_DATA_W / 8;   


// Instruction Memory Parameters
localparam INST_DATA_W = 32;         
localparam INST_ADDR_W = 5;          
localparam INST_BE_W   = 4;          

// Ping-Pong Parameters (shared by ACT and WGT)
localparam PP_ROWS  = SA_SIZE;               // 8
localparam PP_COLS  = SA_SIZE;               // 8
localparam PP_WIDTH = DATA_W;                // 8-bit INT8

// Write port: SRAM gives 32-bit = 4 bytes per read
// 16 writes fill one bank (8 rows × 8 cols = 64 bytes)
localparam PP_WR_DATA_W  = SRAM_DATA_W;      // 32-bit write data
localparam PP_WR_ADDR_W  = 4;                // 4-bit addr (0-15, 16 words)
localparam PP_RD_ROW_W   = $clog2(PP_ROWS);  // 3-bit row select (0-7)
localparam PP_RD_DATA_W  = PP_COLS * PP_WIDTH; // 64-bit full row output



// Data SRAM Signals — RAM256x32 dual port (1RW + 1R)
// Port 0: Read-Write → host writes data / NPU writes results
// Port 1: Read-Only  → NPU loader reads tiles

// Port 0 — Read/Write
logic [SRAM_BE_W-1:0]   sram_we0;    // byte write enable (4-bit)
logic                   sram_en0;    // port 0 enable
logic [SRAM_ADDR_W-1:0] sram_a0;     // address (8-bit, 0-255)
logic [SRAM_DATA_W-1:0] sram_di0;    // write data (32-bit)
logic [SRAM_DATA_W-1:0] sram_do0;    // read data  (32-bit)

// Port 1 — Read Only
logic                   sram_en1;    // port 1 enable
logic [SRAM_ADDR_W-1:0] sram_a1;     // address (8-bit, 0-255)
logic [SRAM_DATA_W-1:0] sram_do1;    // read data (32-bit)

// Instruction Memory Signals — RAM128x16 single port (1RW)
// Port 0: Read-Write → host writes program / CU reads instructions
logic [INST_BE_W-1:0]   inst_we0;    // byte write enable (2-bit)
logic                   inst_en0;    // port enable
logic [INST_ADDR_W-1:0] inst_a0;     // address (7-bit, 0-127)
logic [INST_DATA_W-1:0] inst_di0;    // write data (16-bit) ← host writes program
logic [INST_DATA_W-1:0] inst_do0;    // read data  (16-bit) ← CU reads instruction


// ACT Ping-Pong Buffer Signals
// Write port (from SRAM loader → inactive bank)
logic                      act_wr_en;
logic [PP_WR_ADDR_W-1:0]   act_wr_byte_addr;  // 0-15
logic [PP_WR_DATA_W-1:0]   act_wr_data;       // 32-bit packed 4×INT8

// Read port (to SA → active bank, full row)
logic [PP_RD_ROW_W-1:0]    act_rd_row;        // 0-7
logic [PP_RD_DATA_W-1:0]   act_rd_data;       // 64-bit row output

// Control
logic                      act_swap;           // pulse to swap banks
logic                      act_fill_done;      // inactive bank fully loaded
logic                      act_active_bank;    // 0=BankA active 1=BankB active

// WGT Ping-Pong Buffer Signals
// Write port (from SRAM loader → inactive bank)
logic                      wgt_wr_en;
logic [PP_WR_ADDR_W-1:0]   wgt_wr_byte_addr;  // 0-15
logic [PP_WR_DATA_W-1:0]   wgt_wr_data;       // 32-bit packed 4×INT8

// Read port (to SA → active bank, full row)
logic [PP_RD_ROW_W-1:0]    wgt_rd_row;        // 0-7
logic [PP_RD_DATA_W-1:0]   wgt_rd_data;       // 64-bit row output

// Control
logic                      wgt_swap;           // pulse to swap banks
logic                      wgt_fill_done;      // inactive bank fully loaded
logic                      wgt_active_bank;    // 0=BankA active 1=BankB active

RAM32 u_inst_mem (
    .CLK (clk),
    .WE0 (inst_we0),    // 4-bit byte enable
    .EN0 (inst_en0),    // enable
    .A0  (inst_a0),     // 5-bit address
    .Di0 (inst_di0),    // 32-bit write data (host loads program)
    .Do0 (inst_do0)     // 32-bit read data  (CU fetches instruction)
);

CU #() cu (

);

RAM256x32_1RW1R u_data_sram (
    .CLK (clk),
    // Port 0 RW
    .WE0 (sram_we0),    // 4-bit byte enable
    .EN0 (sram_en0),    // enable
    .A0  (sram_a0),     // 8-bit address
    .Di0 (sram_di0),    // 32-bit write data
    .Do0 (sram_do0),    // 32-bit read data
    // Port 1 R
    .EN1 (sram_en1),    // enable
    .A1  (sram_a1),     // 8-bit address
    .Do1 (sram_do1)     // 32-bit read data
);


// ACT Ping-Pong Buffer Instantiation
pingpong_buffer #(
    .ROWS  (PP_ROWS),
    .COLS  (PP_COLS),
    .WIDTH (PP_WIDTH)
) u_act_pp (
    .clk          (clk),
    .rst_n        (rst_n),

    // Write port
    .wr_en        (act_wr_en),
    .wr_byte_addr (act_wr_byte_addr),
    .wr_data      (act_wr_data),

    // Read port
    .rd_row       (act_rd_row),
    .rd_data      (act_rd_data),

    // Control
    .swap         (act_swap),
    .fill_done    (act_fill_done),
    .active_bank  (act_active_bank)
);

// WGT Ping-Pong Buffer Instantiation
pingpong_buffer #(
    .ROWS  (PP_ROWS),
    .COLS  (PP_COLS),
    .WIDTH (PP_WIDTH)
) u_wgt_pp (
    .clk          (clk),
    .rst_n        (rst_n),

    // Write port
    .wr_en        (wgt_wr_en),
    .wr_byte_addr (wgt_wr_byte_addr),
    .wr_data      (wgt_wr_data),

    // Read port
    .rd_row       (wgt_rd_row),
    .rd_data      (wgt_rd_data),

    // Control
    .swap         (wgt_swap),
    .fill_done    (wgt_fill_done),
    .active_bank  (wgt_active_bank)
);



SA_NxN_top #(DATA_W,DATA_W_PATH,SA_SIZE) SA (
.clk(clk),
.rst_n(rst_n),

.act_in(),
.weight_in(),

.transpose_en(),

.start(),
.valid_in(),

.valid_out(),
.busy(),
.done(),

.psum_out()
);

endmodule