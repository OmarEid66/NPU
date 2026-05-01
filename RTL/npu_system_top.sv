// =============================================================================
//  npu_system_top.sv
//
//  Full Integration: UART → APB Bridge → APB Splitter → NPU APB Decoder → NPU
//
//  System Architecture:
//
//   PC / Host
//     │ UART (RX/TX)
//     ▼
//   ┌─────────────────────────────────┐
//   │        uart_apb_sys             │   (uart_apb_master + apb_splitter)
//   │                                 │
//   │  Slave 0 : 0x0000 – 0x1FFF  ───┼──► npu_apb_decoder
//   │  Slave 1 : 0x2000 – 0x3FFF  ───┼──► (unconnected / tie-off)
//   │  ...                            │
//   │  Slave 7 : 0xE000 – 0xFFFF  ───┼──► (unconnected / tie-off)
//   └─────────────────────────────────┘
//                    │
//             npu_apb_decoder
//             (APB → NPU register map)
//               0x000        → Control/Status (start_npu, npu_done, done_processing)
//               0x004–0x1FC  → IMEM (128 words × 32-bit)
//               0x200–0x3FC  → DMEM (256 words × 32-bit, R/W)
//                    │
//                 npu_top
//                 (8×8 Systolic Array NPU)
//
//  UART Protocol (uart_apb_master):
//    TX to NPU : SYNC(0xDEAD) + CMD(0x01=WR / 0x02=RD) + ADDR[31:0] + DATA[31:0]
//    RX from NPU: STATUS + DATA[31:0] (read response)
//    Lock:        Write 0xDEAD_10CC to 0xFFFF_FFF0 to permanently disable bridge
//
//  NPU Address Map (byte addresses within Slave 0 slot):
//    0x0000        Control register
//                    WR PWDATA[0]=1 : start_npu pulse
//                    RD PRDATA[1:0] : {done_processing, npu_done}
//    0x0004–0x01FC IMEM write port  (128 instructions × 32-bit)
//    0x0200–0x03FC DMEM read/write  (256 data words  × 32-bit)
//
//  Parameters:
//    DEFAULT_DIVISOR : UART baud rate divisor  (clk / (baud × 16))
//                      Default 87 → 9600 baud at ~12 MHz,
//                                   115200 baud at ~120 MHz
//    LOCK_ADDR       : Address that triggers permanent bridge lock
//    LOCK_KEY        : Data value that triggers permanent bridge lock
//    TIMEOUT_CYCLES  : APB transaction timeout (in clock cycles)
//
//  Notes:
//    • imem_wr_we is tied to 4'hF (full-word write always).
//    • dmem_rd_host is derived from the APB read enable to the DMEM region.
//    • npu_top INST_ADDR_W overridden to 7 to match the decoder's 7-bit
//      word address (covers 128 instructions). If your npu_top build only
//      uses 32 instructions keep INST_ADDR_W=5 and the upper address bits
//      are harmlessly ignored by the internal IMEM.
//    • Unused APB slave ports (S1–S7) are tied off with PRDATA=0,
//      PREADY=1, PSLVERR=0.
// =============================================================================

`timescale 1ns/1ps

module npu_system_top #(
    parameter DEFAULT_DIVISOR = 16'd87,
    parameter LOCK_ADDR       = 32'hFFFF_FFF0,
    parameter LOCK_KEY        = 32'hDEAD_10CC,
    parameter TIMEOUT_CYCLES  = 32'd5_000_000
)(
    input  logic clk,
    input  logic rst_n,
    // UART pins
    input  logic uart_rx,
    output logic uart_tx,
    // Bridge lock status (optional status output)
    output logic locked,
    // NPU status (optional status outputs)
    output logic npu_done,
    output logic done_processing
);

    // =========================================================================
    //  APB bus wires — Slave 0 (NPU)
    // =========================================================================
    localparam SLOT_BITS = 13;   // 8 KB per slave slot

    wire                  S0_PSEL;
    wire [SLOT_BITS-1:0]  S0_PADDR;
    wire                  S0_PENABLE;
    wire                  S0_PWRITE;
    wire [31:0]           S0_PWDATA;
    wire [31:0]           S0_PRDATA;
    wire                  S0_PREADY;
    wire                  S0_PSLVERR;

    // =========================================================================
    //  APB bus wires — Slaves 1–7 (unused, tied off)
    // =========================================================================
    wire S1_PSEL,  S2_PSEL,  S3_PSEL,  S4_PSEL,  S5_PSEL,  S6_PSEL,  S7_PSEL;
    wire S1_PENABLE, S2_PENABLE, S3_PENABLE, S4_PENABLE;
    wire S5_PENABLE, S6_PENABLE, S7_PENABLE;
    wire S1_PWRITE, S2_PWRITE, S3_PWRITE, S4_PWRITE;
    wire S5_PWRITE, S6_PWRITE, S7_PWRITE;
    wire [SLOT_BITS-1:0] S1_PADDR, S2_PADDR, S3_PADDR, S4_PADDR;
    wire [SLOT_BITS-1:0] S5_PADDR, S6_PADDR, S7_PADDR;
    wire [31:0] S1_PWDATA, S2_PWDATA, S3_PWDATA, S4_PWDATA;
    wire [31:0] S5_PWDATA, S6_PWDATA, S7_PWDATA;

    // Tie off unused slave inputs (PRDATA=0, PREADY=1, PSLVERR=0)
    assign S1_PRDATA = 32'd0; assign S1_PREADY = 1'b1; assign S1_PSLVERR = 1'b0;
    assign S2_PRDATA = 32'd0; assign S2_PREADY = 1'b1; assign S2_PSLVERR = 1'b0;
    assign S3_PRDATA = 32'd0; assign S3_PREADY = 1'b1; assign S3_PSLVERR = 1'b0;
    assign S4_PRDATA = 32'd0; assign S4_PREADY = 1'b1; assign S4_PSLVERR = 1'b0;
    assign S5_PRDATA = 32'd0; assign S5_PREADY = 1'b1; assign S5_PSLVERR = 1'b0;
    assign S6_PRDATA = 32'd0; assign S6_PREADY = 1'b1; assign S6_PSLVERR = 1'b0;
    assign S7_PRDATA = 32'd0; assign S7_PREADY = 1'b1; assign S7_PSLVERR = 1'b0;

    // =========================================================================
    //  Wires: npu_apb_decoder → npu_top
    // =========================================================================
    wire        start_npu_w;
    wire        load_imem_w;
    wire        load_dmem_w;

    wire        imem_wr_en_w;
    wire [6:0]  imem_wr_addr_w;   // 7-bit word addr from decoder
    wire [31:0] imem_wr_data_w;

    wire        dmem_wr_en_w;
    wire [3:0]  dmem_wr_be_w;
    wire [7:0]  dmem_wr_addr_w;
    wire [31:0] dmem_wr_data_w;

    wire        dmem_rd_en_w;
    wire [7:0]  dmem_rd_addr_w;
    wire [31:0] dmem_rd_data_w;

    // =========================================================================
    //  LAYER 1: uart_apb_sys
    //  (uart_apb_master + apb_splitter, 8 slave ports)
    // =========================================================================
    uart_apb_sys #(
        .DEFAULT_DIVISOR (DEFAULT_DIVISOR),
        .LOCK_ADDR       (LOCK_ADDR),
        .LOCK_KEY        (LOCK_KEY),
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
        .NUM_SLAVES      (8),
        .SLOT_BITS       (SLOT_BITS)
    ) u_uart_apb_sys (
        .clk        (clk),
        .rst_n      (rst_n),
        .uart_rx    (uart_rx),
        .uart_tx    (uart_tx),
        .locked     (locked),

        // Slave 0 → npu_apb_decoder
        .S0_PSEL    (S0_PSEL),
        .S0_PADDR   (S0_PADDR),
        .S0_PENABLE (S0_PENABLE),
        .S0_PWRITE  (S0_PWRITE),
        .S0_PWDATA  (S0_PWDATA),
        .S0_PRDATA  (S0_PRDATA),
        .S0_PREADY  (S0_PREADY),
        .S0_PSLVERR (S0_PSLVERR),

        // Slaves 1–7 (unused)
        .S1_PSEL    (S1_PSEL),   .S1_PADDR (S1_PADDR),
        .S1_PENABLE (S1_PENABLE),.S1_PWRITE(S1_PWRITE),
        .S1_PWDATA  (S1_PWDATA), .S1_PRDATA(S1_PRDATA),
        .S1_PREADY  (S1_PREADY), .S1_PSLVERR(S1_PSLVERR),

        .S2_PSEL    (S2_PSEL),   .S2_PADDR (S2_PADDR),
        .S2_PENABLE (S2_PENABLE),.S2_PWRITE(S2_PWRITE),
        .S2_PWDATA  (S2_PWDATA), .S2_PRDATA(S2_PRDATA),
        .S2_PREADY  (S2_PREADY), .S2_PSLVERR(S2_PSLVERR),

        .S3_PSEL    (S3_PSEL),   .S3_PADDR (S3_PADDR),
        .S3_PENABLE (S3_PENABLE),.S3_PWRITE(S3_PWRITE),
        .S3_PWDATA  (S3_PWDATA), .S3_PRDATA(S3_PRDATA),
        .S3_PREADY  (S3_PREADY), .S3_PSLVERR(S3_PSLVERR),

        .S4_PSEL    (S4_PSEL),   .S4_PADDR (S4_PADDR),
        .S4_PENABLE (S4_PENABLE),.S4_PWRITE(S4_PWRITE),
        .S4_PWDATA  (S4_PWDATA), .S4_PRDATA(S4_PRDATA),
        .S4_PREADY  (S4_PREADY), .S4_PSLVERR(S4_PSLVERR),

        .S5_PSEL    (S5_PSEL),   .S5_PADDR (S5_PADDR),
        .S5_PENABLE (S5_PENABLE),.S5_PWRITE(S5_PWRITE),
        .S5_PWDATA  (S5_PWDATA), .S5_PRDATA(S5_PRDATA),
        .S5_PREADY  (S5_PREADY), .S5_PSLVERR(S5_PSLVERR),

        .S6_PSEL    (S6_PSEL),   .S6_PADDR (S6_PADDR),
        .S6_PENABLE (S6_PENABLE),.S6_PWRITE(S6_PWRITE),
        .S6_PWDATA  (S6_PWDATA), .S6_PRDATA(S6_PRDATA),
        .S6_PREADY  (S6_PREADY), .S6_PSLVERR(S6_PSLVERR),

        .S7_PSEL    (S7_PSEL),   .S7_PADDR (S7_PADDR),
        .S7_PENABLE (S7_PENABLE),.S7_PWRITE(S7_PWRITE),
        .S7_PWDATA  (S7_PWDATA), .S7_PRDATA(S7_PRDATA),
        .S7_PREADY  (S7_PREADY), .S7_PSLVERR(S7_PSLVERR)
    );

    // =========================================================================
    //  LAYER 2: npu_apb_decoder
    //  Translates APB transactions into npu_top control signals
    // =========================================================================
    npu_apb_decoder #(
        .SLOT_BITS (SLOT_BITS)
    ) u_npu_apb_decoder (
        .clk            (clk),
        .rst_n          (rst_n),

        // APB slave port — connected to uart_apb_sys Slave 0
        .PSEL           (S0_PSEL),
        .PADDR          (S0_PADDR),
        .PENABLE        (S0_PENABLE),
        .PWRITE         (S0_PWRITE),
        .PWDATA         (S0_PWDATA),
        .PRDATA         (S0_PRDATA),
        .PREADY         (S0_PREADY),
        .PSLVERR        (S0_PSLVERR),

        // NPU control signals
        .start_npu      (start_npu_w),
        .load_imem      (load_imem_w),
        .load_dmem      (load_dmem_w),

        // IMEM write port
        .imem_wr_en     (imem_wr_en_w),
        .imem_wr_addr   (imem_wr_addr_w),
        .imem_wr_data   (imem_wr_data_w),

        // DMEM write port
        .dmem_wr_en     (dmem_wr_en_w),
        .dmem_wr_be     (dmem_wr_be_w),
        .dmem_wr_addr   (dmem_wr_addr_w),
        .dmem_wr_data   (dmem_wr_data_w),

        // DMEM read port
        .dmem_rd_en     (dmem_rd_en_w),
        .dmem_rd_addr   (dmem_rd_addr_w),
        .dmem_rd_data   (dmem_rd_data_w),

        // Status from npu_top
        .npu_done       (npu_done),
        .done_processing(done_processing)
    );

    // =========================================================================
    //  LAYER 3: npu_top
    //  8×8 Systolic Array NPU
    //
    //  Port adaptation notes:
    //
    //  imem_wr_we  : npu_top requires a 4-bit byte-enable for the IMEM write
    //                port. The decoder always writes full 32-bit words, so
    //                tie to 4'hF (all bytes enabled).
    //
    //  dmem_rd_host: npu_top uses this flag to mux the DMEM read port to the
    //                host (vs. the NPU internal read). Assert whenever the
    //                decoder is performing a DMEM read (dmem_rd_en_w).
    //
    //  INST_ADDR_W : Overridden to 7 to match the 7-bit word address produced
    //                by npu_apb_decoder (PADDR[8:2], covering 128 instruction
    //                words). The default npu_top value is 5 (32 words). If you
    //                only need 32 instructions, change back to 5 — the decoder
    //                address bits [8:7] will simply never be asserted.
    //
    //  imem_wr_addr: decoder produces 7-bit; npu_top port is INST_ADDR_W-wide.
    //                With INST_ADDR_W=7 this connects directly.
    // =========================================================================
    npu_top #(
        .DATA_W      (8),
        .DATA_W_PATH (32),
        .SA_SIZE     (8),
        .INST_ADDR_W (7),       // 128-word IMEM to match decoder address range
        .INST_DATA_W (32),
        .SRAM_DATA_W (32),
        .SRAM_ADDR_W (8)
    ) u_npu_top (
        .clk            (clk),
        .rst_n          (rst_n),

        // Host load mode flags
        .load_imem      (load_imem_w),
        .load_dmem      (load_dmem_w),
        .dmem_rd_host   (dmem_rd_en_w),  // host DMEM read → assert dmem_rd_host

        // IMEM write port
        .imem_wr_we     (4'hF),           // full-word write always (tie off)
        .imem_wr_en     (imem_wr_en_w),
        .imem_wr_addr   (imem_wr_addr_w), // 7-bit word address [6:0]
        .imem_wr_data   (imem_wr_data_w),

        // DMEM write port
        .dmem_wr_en     (dmem_wr_en_w),
        .dmem_wr_be     (dmem_wr_be_w),
        .dmem_wr_addr   (dmem_wr_addr_w),
        .dmem_wr_data   (dmem_wr_data_w),

        // DMEM read port
        .dmem_rd_en     (dmem_rd_en_w),
        .dmem_rd_addr   (dmem_rd_addr_w),
        .dmem_rd_data   (dmem_rd_data_w),

        // NPU control
        .start_npu      (start_npu_w),
        .done_processing(done_processing),
        .npu_done       (npu_done)
    );

endmodule
