// =============================================================================
//  uart_apb_sys_with_npu.sv
//  uart_apb_sys top level — identical to original except:
//    • Slave 0 is no longer exposed as top-level ports
//    • npu_apb_decoder is instantiated internally on Slave 0
//
//  Slaves 1-7 remain as output ports, unchanged.
// =============================================================================

module uart_apb_sys_with_npu #(
    parameter DEFAULT_DIVISOR = 16'd87,
    parameter LOCK_ADDR       = 32'hFFFF_FFF0,
    parameter LOCK_KEY        = 32'hDEAD_10CC,
    parameter TIMEOUT_CYCLES  = 32'd5_000_000,
    parameter NUM_SLAVES      = 8,
    parameter SLOT_BITS       = 13,
    // NPU parameters
    parameter NPU_DATA_W      = 8,
    parameter NPU_DATA_W_PATH = 32,
    parameter NPU_SA_SIZE     = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    // UART
    input  wire        uart_rx,
    output wire        uart_tx,
    // Status
    output wire        locked,

    // Slave 1–7 (exposed as before — connect your other peripherals here)
    output wire                 S1_PSEL,
    output wire [SLOT_BITS-1:0] S1_PADDR,
    output wire                 S1_PENABLE,
    output wire                 S1_PWRITE,
    output wire [31:0]          S1_PWDATA,
    input  wire [31:0]          S1_PRDATA,
    input  wire                 S1_PREADY,
    input  wire                 S1_PSLVERR,

    output wire                 S2_PSEL,
    output wire [SLOT_BITS-1:0] S2_PADDR,
    output wire                 S2_PENABLE,
    output wire                 S2_PWRITE,
    output wire [31:0]          S2_PWDATA,
    input  wire [31:0]          S2_PRDATA,
    input  wire                 S2_PREADY,
    input  wire                 S2_PSLVERR,

    output wire                 S3_PSEL,
    output wire [SLOT_BITS-1:0] S3_PADDR,
    output wire                 S3_PENABLE,
    output wire                 S3_PWRITE,
    output wire [31:0]          S3_PWDATA,
    input  wire [31:0]          S3_PRDATA,
    input  wire                 S3_PREADY,
    input  wire                 S3_PSLVERR,

    output wire                 S4_PSEL,
    output wire [SLOT_BITS-1:0] S4_PADDR,
    output wire                 S4_PENABLE,
    output wire                 S4_PWRITE,
    output wire [31:0]          S4_PWDATA,
    input  wire [31:0]          S4_PRDATA,
    input  wire                 S4_PREADY,
    input  wire                 S4_PSLVERR,

    output wire                 S5_PSEL,
    output wire [SLOT_BITS-1:0] S5_PADDR,
    output wire                 S5_PENABLE,
    output wire                 S5_PWRITE,
    output wire [31:0]          S5_PWDATA,
    input  wire [31:0]          S5_PRDATA,
    input  wire                 S5_PREADY,
    input  wire                 S5_PSLVERR,

    output wire                 S6_PSEL,
    output wire [SLOT_BITS-1:0] S6_PADDR,
    output wire                 S6_PENABLE,
    output wire                 S6_PWRITE,
    output wire [31:0]          S6_PWDATA,
    input  wire [31:0]          S6_PRDATA,
    input  wire                 S6_PREADY,
    input  wire                 S6_PSLVERR,

    output wire                 S7_PSEL,
    output wire [SLOT_BITS-1:0] S7_PADDR,
    output wire                 S7_PENABLE,
    output wire                 S7_PWRITE,
    output wire [31:0]          S7_PWDATA,
    input  wire [31:0]          S7_PRDATA,
    input  wire                 S7_PREADY,
    input  wire                 S7_PSLVERR
);

    // =========================================================================
    // Internal APB bus (bridge → splitter)
    // =========================================================================
    wire [31:0] m_PADDR;
    wire        m_PSEL;
    wire        m_PENABLE;
    wire        m_PWRITE;
    wire [31:0] m_PWDATA;
    wire [31:0] m_PRDATA;
    wire        m_PREADY;
    wire        m_PSLVERR;

    // =========================================================================
    // Splitter buses
    // =========================================================================
    wire [NUM_SLAVES-1:0]    pselx;
    wire [SLOT_BITS-1:0]     paddr_o;
    wire                     penable_o;
    wire                     pwrite_o;
    wire [31:0]              pwdata_o;
    wire [NUM_SLAVES*32-1:0] prdata_i;
    wire [NUM_SLAVES-1:0]    pready_i;
    wire [NUM_SLAVES-1:0]    pslverr_i;

    // =========================================================================
    // Slave 0 internal wires (NPU)
    // =========================================================================
    wire [31:0] S0_PRDATA;
    wire        S0_PREADY;
    wire        S0_PSLVERR;

    // =========================================================================
    // UART-APB Bridge
    // =========================================================================
    uart_apb_master #(
        .DEFAULT_DIVISOR (DEFAULT_DIVISOR),
        .LOCK_ADDR       (LOCK_ADDR),
        .LOCK_KEY        (LOCK_KEY),
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES)
    ) u_bridge (
        .clk     (clk),
        .rst_n   (rst_n),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx),
        .PADDR   (m_PADDR),
        .PSEL    (m_PSEL),
        .PENABLE (m_PENABLE),
        .PWRITE  (m_PWRITE),
        .PWDATA  (m_PWDATA),
        .PRDATA  (m_PRDATA),
        .PREADY  (m_PREADY),
        .PSLVERR (m_PSLVERR),
        .locked  (locked)
    );

    // =========================================================================
    // APB Splitter
    // =========================================================================
    apb_splitter #(
        .NUM_SLAVES (NUM_SLAVES),
        .SLOT_BITS  (SLOT_BITS)
    ) u_splitter (
        .PADDR     (m_PADDR),
        .PSEL      (m_PSEL),
        .PENABLE   (m_PENABLE),
        .PWRITE    (m_PWRITE),
        .PWDATA    (m_PWDATA),
        .PRDATA    (m_PRDATA),
        .PREADY    (m_PREADY),
        .PSLVERR   (m_PSLVERR),
        .PSELx     (pselx),
        .PADDR_o   (paddr_o),
        .PENABLE_o (penable_o),
        .PWRITE_o  (pwrite_o),
        .PWDATA_o  (pwdata_o),
        .PRDATA_i  (prdata_i),
        .PREADY_i  (pready_i),
        .PSLVERR_i (pslverr_i)
    );

    // =========================================================================
    // Slave 0 — NPU APB decoder (internal, not exposed at top level)
    // =========================================================================
    npu_apb_decoder #(
        .DATA_W      (NPU_DATA_W),
        .DATA_W_PATH (NPU_DATA_W_PATH),
        .SA_SIZE     (NPU_SA_SIZE),
        .SLOT_BITS   (SLOT_BITS)
    ) u_npu_decoder (
        .clk         (clk),
        .rst_n       (rst_n),
        .S0_PSEL     (pselx[0]),
        .S0_PADDR    (paddr_o),
        .S0_PENABLE  (penable_o),
        .S0_PWRITE   (pwrite_o),
        .S0_PWDATA   (pwdata_o),
        .S0_PRDATA   (S0_PRDATA),
        .S0_PREADY   (S0_PREADY),
        .S0_PSLVERR  (S0_PSLVERR)
    );

    // =========================================================================
    // Map splitter buses → slave ports (Slaves 1-7, shared signals)
    // =========================================================================
    assign S1_PADDR = paddr_o;  assign S2_PADDR = paddr_o;
    assign S3_PADDR = paddr_o;  assign S4_PADDR = paddr_o;
    assign S5_PADDR = paddr_o;  assign S6_PADDR = paddr_o;
    assign S7_PADDR = paddr_o;

    assign S1_PENABLE = penable_o;  assign S2_PENABLE = penable_o;
    assign S3_PENABLE = penable_o;  assign S4_PENABLE = penable_o;
    assign S5_PENABLE = penable_o;  assign S6_PENABLE = penable_o;
    assign S7_PENABLE = penable_o;

    assign S1_PWRITE = pwrite_o;  assign S2_PWRITE = pwrite_o;
    assign S3_PWRITE = pwrite_o;  assign S4_PWRITE = pwrite_o;
    assign S5_PWRITE = pwrite_o;  assign S6_PWRITE = pwrite_o;
    assign S7_PWRITE = pwrite_o;

    assign S1_PWDATA = pwdata_o;  assign S2_PWDATA = pwdata_o;
    assign S3_PWDATA = pwdata_o;  assign S4_PWDATA = pwdata_o;
    assign S5_PWDATA = pwdata_o;  assign S6_PWDATA = pwdata_o;
    assign S7_PWDATA = pwdata_o;

    // Per-slave PSEL (Slaves 1-7)
    assign S1_PSEL = pselx[1];  assign S2_PSEL = pselx[2];
    assign S3_PSEL = pselx[3];  assign S4_PSEL = pselx[4];
    assign S5_PSEL = pselx[5];  assign S6_PSEL = pselx[6];
    assign S7_PSEL = pselx[7];

    // =========================================================================
    // PRDATA concatenation — Slave 0 internal, Slaves 1-7 external
    // =========================================================================
    assign prdata_i = {
        S7_PRDATA, S6_PRDATA, S5_PRDATA, S4_PRDATA,
        S3_PRDATA, S2_PRDATA, S1_PRDATA,
        S0_PRDATA                               // NPU result / status
    };

    assign pready_i = {
        S7_PREADY, S6_PREADY, S5_PREADY, S4_PREADY,
        S3_PREADY, S2_PREADY, S1_PREADY,
        S0_PREADY                               // NPU PREADY (stalls on dmem read)
    };

    assign pslverr_i = {
        S7_PSLVERR, S6_PSLVERR, S5_PSLVERR, S4_PSLVERR,
        S3_PSLVERR, S2_PSLVERR, S1_PSLVERR,
        S0_PSLVERR                              // NPU error (invalid address)
    };

endmodule
