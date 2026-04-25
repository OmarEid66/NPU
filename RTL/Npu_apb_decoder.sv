// =============================================================================
//  npu_apb_decoder.sv
//  APB Slave 0 decoder — sits between uart_apb_sys and npu_top.
//  Translates APB transactions into npu_top's native load/start/done interface.
//
//  Address map (PADDR is 13-bit, 8 KB slot):
//
//  PADDR[12:10]  Region       npu_top signal
//  ──────────────────────────────────────────────────────────────────
//  000_0000_0000  0x000  WR   Control: PWDATA[0]=start_npu
//                        RD   Status:  PRDATA[1]=done_processing
//                                      PRDATA[0]=npu_done
//  000_0xxx_xxxx  0x004-0x1FC WR  Instruction memory (128 words)
//                                  imem_wr_en / imem_wr_addr / imem_wr_data
//  001_xxxx_xxxx  0x200-0x3FC WR  Data SRAM write
//                                  dmem_wr_en / dmem_wr_be / dmem_wr_addr / dmem_wr_data
//                             RD  Data SRAM read
//                                  dmem_rd_en / dmem_rd_addr → dmem_rd_data (1-cycle latency)
//  other                      —   PSLVERR
// =============================================================================

module npu_apb_decoder #(
    parameter DATA_W      = 8,
    parameter DATA_W_PATH = 32,
    parameter SA_SIZE     = 8,
    parameter SLOT_BITS   = 13          // must match uart_apb_sys SLOT_BITS
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // ── APB Slave 0 port (from uart_apb_sys / apb_splitter) ──────────────────
    input  logic                  S0_PSEL,
    input  logic [SLOT_BITS-1:0]  S0_PADDR,    // [12:0]
    input  logic                  S0_PENABLE,
    input  logic                  S0_PWRITE,
    input  logic [31:0]           S0_PWDATA,
    output logic [31:0]           S0_PRDATA,
    output logic                  S0_PREADY,
    output logic                  S0_PSLVERR
);

    // =========================================================================
    // APB transaction qualifiers
    // =========================================================================
    wire apb_write = S0_PSEL & S0_PENABLE &  S0_PWRITE;
    wire apb_read  = S0_PSEL & S0_PENABLE & ~S0_PWRITE;

    // =========================================================================
    // Address region decode
    // PADDR is a byte address within the 8 KB slot.
    // Word addresses are PADDR >> 2.
    //
    //  Region   PADDR[12:2] range      Byte range
    //  ctrl     11'h000                0x000
    //  imem     PADDR[12:9]==4'b0000   0x004–0x1FC  (127 words, addr[8:2])
    //           and PADDR[12:2]!=0
    //  dmem     PADDR[12:10]==3'b001   0x200–0x3FC  (256 words, addr[9:2])
    // =========================================================================
    wire sel_ctrl = (S0_PADDR[12:2] == 11'h000);
    wire sel_imem = (S0_PADDR[12:9] == 4'b0000) & ~sel_ctrl; // 0x004–0x1FC
    wire sel_dmem = (S0_PADDR[12:10] == 3'b001);              // 0x200–0x3FC
    wire sel_none = ~sel_ctrl & ~sel_imem & ~sel_dmem;

    // =========================================================================
    // Wires to/from npu_top
    // =========================================================================
    logic        npu_start;
    logic        npu_load_imem;
    logic        npu_load_dmem;

    logic        npu_imem_wr_en;
    logic [6:0]  npu_imem_wr_addr;
    logic [31:0] npu_imem_wr_data;

    logic        npu_dmem_wr_en;
    logic [3:0]  npu_dmem_wr_be;
    logic [7:0]  npu_dmem_wr_addr;
    logic [31:0] npu_dmem_wr_data;
    logic        npu_dmem_rd_en;
    logic [7:0]  npu_dmem_rd_addr;
    logic [31:0] npu_dmem_rd_data;

    logic        npu_done;
    logic        npu_done_processing;

    // =========================================================================
    // START register (write to ctrl, auto-clears on npu_done)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            npu_start <= 1'b0;
        else if (apb_write & sel_ctrl)
            npu_start <= S0_PWDATA[0];
        else if (npu_done)
            npu_start <= 1'b0;          // auto-clear when NPU finishes
    end

    // load_imem: high while PC is actively writing to instruction memory
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            npu_load_imem <= 1'b0;
        else
            npu_load_imem <= apb_write & sel_imem;  // combinatorial qualified by 1 reg
    end

    // load_dmem: high while PC is actively writing to data SRAM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            npu_load_dmem <= 1'b0;
        else
            npu_load_dmem <= apb_write & sel_dmem;
    end

    // =========================================================================
    // Instruction memory write port
    //   imem_wr_addr is 7-bit word address (0-127) — PADDR[8:2]
    // =========================================================================
    assign npu_imem_wr_en   = apb_write & sel_imem;
    assign npu_imem_wr_addr = S0_PADDR[8:2];       // 7-bit word addr
    assign npu_imem_wr_data = S0_PWDATA;

    // =========================================================================
    // Data SRAM write port
    //   dmem_wr_addr is 8-bit word address (0-255) — PADDR[9:2]
    // =========================================================================
    assign npu_dmem_wr_en   = apb_write & sel_dmem;
    assign npu_dmem_wr_be   = 4'hF;                // full 32-bit word writes from PC
    assign npu_dmem_wr_addr = S0_PADDR[9:2];       // 8-bit word addr
    assign npu_dmem_wr_data = S0_PWDATA;

    // =========================================================================
    // Data SRAM read port (1-cycle latency → PREADY held low for 1 extra cycle)
    // =========================================================================
    assign npu_dmem_rd_en   = apb_read & sel_dmem;
    assign npu_dmem_rd_addr = S0_PADDR[9:2];

    // =========================================================================
    // PRDATA mux
    // =========================================================================
    always_comb begin
        case (1'b1)
            sel_ctrl : S0_PRDATA = {30'b0, npu_done_processing, npu_done};
            sel_dmem : S0_PRDATA = npu_dmem_rd_data;   // registered inside npu_top
            sel_imem : S0_PRDATA = 32'h0;              // instruction mem: write-only from APB
            default  : S0_PRDATA = 32'hDEAD_BEEF;
        endcase
    end

    // =========================================================================
    // PREADY
    //   - Always 1 for writes (registers and SRAM writes are single-cycle)
    //   - Hold low for 1 extra cycle on SRAM reads (dmem has 1-cycle read latency)
    //   - Hold low on result reads until npu_done
    // =========================================================================
    logic dmem_rd_pending;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dmem_rd_pending <= 1'b0;
        else
            dmem_rd_pending <= apb_read & sel_dmem & ~dmem_rd_pending;
    end

    assign S0_PREADY  = S0_PWRITE ? 1'b1 :                        // writes: always ready
                        (sel_dmem & ~dmem_rd_pending) ? 1'b0 :    // dmem read: 1-cycle wait
                        1'b1;

    // =========================================================================
    // PSLVERR — invalid address
    // =========================================================================
    assign S0_PSLVERR = S0_PSEL & S0_PENABLE & sel_none;

    // =========================================================================
    // npu_top instantiation
    // =========================================================================
    npu_top #(
        .DATA_W      (DATA_W),
        .DATA_W_PATH (DATA_W_PATH),
        .SA_SIZE     (SA_SIZE)
    ) u_npu (
        .clk              (clk),
        .rst_n            (rst_n),

        .load_imem        (npu_load_imem),
        .load_dmem        (npu_load_dmem),

        .imem_wr_en       (npu_imem_wr_en),
        .imem_wr_addr     (npu_imem_wr_addr),
        .imem_wr_data     (npu_imem_wr_data),

        .dmem_wr_en       (npu_dmem_wr_en),
        .dmem_wr_be       (npu_dmem_wr_be),
        .dmem_wr_addr     (npu_dmem_wr_addr),
        .dmem_wr_data     (npu_dmem_wr_data),

        .dmem_rd_en       (npu_dmem_rd_en),
        .dmem_rd_addr     (npu_dmem_rd_addr),
        .dmem_rd_data     (npu_dmem_rd_data),

        .start_npu        (npu_start),
        .done_processing  (npu_done_processing),
        .npu_done         (npu_done)
    );

endmodule
