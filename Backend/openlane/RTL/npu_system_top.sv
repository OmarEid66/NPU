// ================================================================
//  npu_system_top — Full chip top
//
//  Hierarchy:
//    npu_system_top
//      ├── uart_apb_sys      (UART ↔ APB bridge + 8-slave splitter)
//      │     Slave 0 ──────► npu_apb_decoder
//      │     Slaves 1-7      (tied off / future use)
//      └── npu_apb_decoder   (APB slave ↔ npu_top control)
//            └── npu_top     (Neural Processing Unit)
//
//  APB address map (Slave 0 slot = 0x0000..0x1FFF):
//    0x000  CSR0  control  {dmem_rd_host, load_dmem, load_imem, start_npu}
//    0x004  CSR1  status   {done_processing, npu_done}
//    0x008  DMEM_RD_ADDR   set read address
//    0x00C  DMEM_RD_DATA   read DMEM word
//    0x100..0x17C  IMEM window (32 × 32-bit instructions)
//    0x200..0x3FC  DMEM window (128 × 32-bit data words)  ← was 256/0x5FC
//
//  Parameters:
//    SA_SIZE         : systolic array dimension (default 4)  ← was 8
//    DATA_W          : activation / weight width (default 8)
//
// ================================================================

module npu_system_top #(
    parameter CLK_FREQ_HZ     = 8_000_000,
    parameter DEFAULT_DIVISOR = 16'd87,
    parameter LOCK_ADDR       = 32'hFFFF_FFF0,
    parameter LOCK_KEY        = 32'hDEAD_10CC,
    parameter TIMEOUT_CYCLES  = 32'd5_000_000,
    parameter SA_SIZE         = 4,    // ← 8→4
    parameter DATA_W          = 8,
    parameter DATA_W_PATH     = 32,
    parameter INST_ADDR_W     = 5,
    parameter INST_DATA_W     = 32,
    parameter SRAM_DATA_W     = 32,
    parameter SRAM_ADDR_W     = 6    
)(
    input  wire clk,
    input  wire rst_n,
    input  wire uart_rx,
    output wire uart_tx,
    output wire locked,
    output wire npu_done,
    output wire done_processing
);

localparam SLOT_BITS = 13;

wire                  S0_PSEL;
wire [SLOT_BITS-1:0]  S0_PADDR;
wire                  S0_PENABLE;
wire                  S0_PWRITE;
wire [31:0]           S0_PWDATA;
wire [31:0]           S0_PRDATA;
wire                  S0_PREADY;
wire                  S0_PSLVERR;

wire [31:0] S1_PRDATA=32'h0, S2_PRDATA=32'h0, S3_PRDATA=32'h0;
wire [31:0] S4_PRDATA=32'h0, S5_PRDATA=32'h0, S6_PRDATA=32'h0;
wire [31:0] S7_PRDATA=32'h0;
wire S1_PREADY=1'b1, S2_PREADY=1'b1, S3_PREADY=1'b1, S4_PREADY=1'b1;
wire S5_PREADY=1'b1, S6_PREADY=1'b1, S7_PREADY=1'b1;
wire S1_PSLVERR=1'b0, S2_PSLVERR=1'b0, S3_PSLVERR=1'b0;
wire S4_PSLVERR=1'b0, S5_PSLVERR=1'b0, S6_PSLVERR=1'b0;
wire S7_PSLVERR=1'b0;

wire                   start_npu;
wire                   load_imem;
wire                   load_dmem;
wire                   dmem_rd_host;
wire [3:0]             imem_wr_we;
wire                   imem_wr_en;
wire [INST_ADDR_W-1:0] imem_wr_addr;
wire [INST_DATA_W-1:0] imem_wr_data;
wire                   dmem_wr_en;
wire [3:0]             dmem_wr_be;
wire [SRAM_ADDR_W-1:0] dmem_wr_addr;
wire [SRAM_DATA_W-1:0] dmem_wr_data;
wire                   dmem_rd_en;
wire [SRAM_ADDR_W-1:0] dmem_rd_addr;
wire [SRAM_DATA_W-1:0] dmem_rd_data;

uart_apb_sys #(
    .DEFAULT_DIVISOR (DEFAULT_DIVISOR),
    .LOCK_ADDR       (LOCK_ADDR),
    .LOCK_KEY        (LOCK_KEY),
    .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
    .NUM_SLAVES      (8),
    .SLOT_BITS       (SLOT_BITS)
) u_uart_apb (
    .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx), .locked(locked),
    .S0_PSEL(S0_PSEL), .S0_PADDR(S0_PADDR), .S0_PENABLE(S0_PENABLE),
    .S0_PWRITE(S0_PWRITE), .S0_PWDATA(S0_PWDATA), .S0_PRDATA(S0_PRDATA),
    .S0_PREADY(S0_PREADY), .S0_PSLVERR(S0_PSLVERR),
    .S1_PSEL(), .S1_PADDR(), .S1_PENABLE(), .S1_PWRITE(), .S1_PWDATA(),
    .S1_PRDATA(S1_PRDATA), .S1_PREADY(S1_PREADY), .S1_PSLVERR(S1_PSLVERR),
    .S2_PSEL(), .S2_PADDR(), .S2_PENABLE(), .S2_PWRITE(), .S2_PWDATA(),
    .S2_PRDATA(S2_PRDATA), .S2_PREADY(S2_PREADY), .S2_PSLVERR(S2_PSLVERR),
    .S3_PSEL(), .S3_PADDR(), .S3_PENABLE(), .S3_PWRITE(), .S3_PWDATA(),
    .S3_PRDATA(S3_PRDATA), .S3_PREADY(S3_PREADY), .S3_PSLVERR(S3_PSLVERR),
    .S4_PSEL(), .S4_PADDR(), .S4_PENABLE(), .S4_PWRITE(), .S4_PWDATA(),
    .S4_PRDATA(S4_PRDATA), .S4_PREADY(S4_PREADY), .S4_PSLVERR(S4_PSLVERR),
    .S5_PSEL(), .S5_PADDR(), .S5_PENABLE(), .S5_PWRITE(), .S5_PWDATA(),
    .S5_PRDATA(S5_PRDATA), .S5_PREADY(S5_PREADY), .S5_PSLVERR(S5_PSLVERR),
    .S6_PSEL(), .S6_PADDR(), .S6_PENABLE(), .S6_PWRITE(), .S6_PWDATA(),
    .S6_PRDATA(S6_PRDATA), .S6_PREADY(S6_PREADY), .S6_PSLVERR(S6_PSLVERR),
    .S7_PSEL(), .S7_PADDR(), .S7_PENABLE(), .S7_PWRITE(), .S7_PWDATA(),
    .S7_PRDATA(S7_PRDATA), .S7_PREADY(S7_PREADY), .S7_PSLVERR(S7_PSLVERR)
);

npu_apb_decoder #(
    .SLOT_BITS   (SLOT_BITS),
    .SRAM_ADDR_W (SRAM_ADDR_W),
    .INST_ADDR_W (INST_ADDR_W),
    .DATA_W      (SRAM_DATA_W)
) u_decoder (
    .clk(clk), .rst_n(rst_n),
    .PSEL(S0_PSEL), .PADDR(S0_PADDR), .PENABLE(S0_PENABLE),
    .PWRITE(S0_PWRITE), .PWDATA(S0_PWDATA), .PRDATA(S0_PRDATA),
    .PREADY(S0_PREADY), .PSLVERR(S0_PSLVERR),
    .start_npu(start_npu), .load_imem(load_imem),
    .load_dmem(load_dmem), .dmem_rd_host(dmem_rd_host),
    .imem_wr_we(imem_wr_we), .imem_wr_en(imem_wr_en),
    .imem_wr_addr(imem_wr_addr), .imem_wr_data(imem_wr_data),
    .dmem_wr_en(dmem_wr_en), .dmem_wr_be(dmem_wr_be),
    .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
    .dmem_rd_en(dmem_rd_en), .dmem_rd_addr(dmem_rd_addr),
    .dmem_rd_data(dmem_rd_data),
    .npu_done(npu_done), .done_processing(done_processing)
);

npu_top #(
    .DATA_W      (DATA_W),
    .DATA_W_PATH (DATA_W_PATH),
    .SA_SIZE     (SA_SIZE),
    .INST_ADDR_W (INST_ADDR_W),
    .INST_DATA_W (INST_DATA_W),
    .SRAM_DATA_W (SRAM_DATA_W),
    .SRAM_ADDR_W (SRAM_ADDR_W)
) u_npu (
    .clk(clk), .rst_n(rst_n),
    .load_imem(load_imem), .load_dmem(load_dmem), .dmem_rd_host(dmem_rd_host),
    .imem_wr_we(imem_wr_we), .imem_wr_en(imem_wr_en),
    .imem_wr_addr(imem_wr_addr), .imem_wr_data(imem_wr_data),
    .dmem_wr_en(dmem_wr_en), .dmem_wr_be(dmem_wr_be),
    .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
    .dmem_rd_en(dmem_rd_en), .dmem_rd_addr(dmem_rd_addr),
    .dmem_rd_data(dmem_rd_data),
    .start_npu(start_npu), .done_processing(done_processing), .npu_done(npu_done)
);

endmodule