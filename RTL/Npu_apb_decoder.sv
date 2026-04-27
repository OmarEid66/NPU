// =============================================================================
//  npu_apb_decoder.sv
//
//  APB decode logic ONLY — no npu_top inside.
//  Left side  : APB slave port  (connect to uart_apb_sys S0)
//  Right side : npu_top signals (connect to npu_top ports directly)
//
//  Address map  (PADDR = 13-bit byte offset, SLOT_BITS=13 → 8 KB slot)
//  ─────────────────────────────────────────────────────────────────────────
//  0x000         Control / Status
//                  WR : PWDATA[0] → start_npu  (latched, auto-clears on npu_done)
//                  RD : PRDATA    = {30'b0, done_processing, npu_done}
//
//  0x004–0x1FC   Instruction memory  (128 words × 32-bit)
//                  WR : imem_wr_en / imem_wr_addr[6:0] / imem_wr_data
//
//  0x200–0x3FC   Data SRAM           (256 words × 32-bit)
//                  WR : dmem_wr_en / dmem_wr_be / dmem_wr_addr[7:0] / dmem_wr_data
//                  RD : dmem_rd_en / dmem_rd_addr[7:0] → dmem_rd_data
//                       PREADY held low 1 extra cycle (registered read latency)
//
//  other         PSLVERR = 1
// =============================================================================

module npu_apb_decoder #(
    parameter SLOT_BITS = 13        // must match uart_apb_sys SLOT_BITS
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // ── APB slave port (connect to uart_apb_sys S0_* ports) ──────────────────
    input  logic                 PSEL,
    input  logic [SLOT_BITS-1:0] PADDR,      // [12:0] byte offset in 8 KB slot
    input  logic                 PENABLE,
    input  logic                 PWRITE,
    input  logic [31:0]          PWDATA,
    output logic [31:0]          PRDATA,
    output logic                 PREADY,
    output logic                 PSLVERR,

    // ── npu_top ports (connect directly to npu_top instance) ─────────────────
    // Control
    output logic                 start_npu,
    output logic                 load_imem,
    output logic                 load_dmem,

    // Instruction memory write
    output logic                 imem_wr_en,
    output logic [6:0]           imem_wr_addr,   // word addr 0–127
    output logic [31:0]          imem_wr_data,

    // Data SRAM write
    output logic                 dmem_wr_en,
    output logic [3:0]           dmem_wr_be,     // byte enables
    output logic [7:0]           dmem_wr_addr,   // word addr 0–255
    output logic [31:0]          dmem_wr_data,

    // Data SRAM read
    output logic                 dmem_rd_en,
    output logic [7:0]           dmem_rd_addr,   // word addr 0–255
    input  logic [31:0]          dmem_rd_data,   // 1-cycle registered latency

    // Status from npu_top
    input  logic                 npu_done,
    input  logic                 done_processing
);

    // =========================================================================
    // APB transaction qualifiers
    // =========================================================================
    wire apb_write = PSEL & PENABLE &  PWRITE;
    wire apb_read  = PSEL & PENABLE & ~PWRITE;

    // =========================================================================
    // Address region decode
    //   sel_ctrl : 0x000                (1 word  — control/status)
    //   sel_imem : 0x004 – 0x1FC       (128 words — instruction memory)
    //   sel_dmem : 0x200 – 0x3FC       (256 words — data SRAM)
    //   sel_none : anything else        (unmapped → PSLVERR)
    // =========================================================================
    wire sel_ctrl = (PADDR[12:2] == 11'h000);
    wire sel_imem = (PADDR[12:9] == 4'b0000) & ~sel_ctrl;   // 0x004–0x1FC
    wire sel_dmem = (PADDR[12:10] == 3'b001);                // 0x200–0x3FC
    wire sel_none = ~sel_ctrl & ~sel_imem & ~sel_dmem;

    // =========================================================================
    // START register
    //   PC writes PADDR=0x000, PWDATA[0]=1 → latched into start_npu
    //   Auto-clears when npu_done pulses high
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if      (!rst_n)               start_npu <= 1'b0;
        else if (apb_write & sel_ctrl) start_npu <= PWDATA[0];
        else if (npu_done)             start_npu <= 1'b0;
    end

    // =========================================================================
    // load_imem / load_dmem
    //   Registered strobes — high for 1 cycle after each APB write in region
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_imem <= 1'b0;
            load_dmem <= 1'b0;
        end else begin
            load_imem <= apb_write & sel_imem;
            load_dmem <= apb_write & sel_dmem;
        end
    end

    // =========================================================================
    // Instruction memory write port
    //   imem_wr_addr : PADDR[8:2]  (7-bit word address, covers 0–127)
    // =========================================================================
    assign imem_wr_en   = apb_write & sel_imem;
    assign imem_wr_addr = PADDR[8:2];
    assign imem_wr_data = PWDATA;

    // =========================================================================
    // Data SRAM write port
    //   dmem_wr_addr : PADDR[9:2]  (8-bit word address, covers 0–255)
    //   dmem_wr_be   : 4'hF — PC always writes full 32-bit words
    // =========================================================================
    assign dmem_wr_en   = apb_write & sel_dmem;
    assign dmem_wr_be   = 4'hF;
    assign dmem_wr_addr = PADDR[9:2];
    assign dmem_wr_data = PWDATA;

    // =========================================================================
    // Data SRAM read port
    //   dmem_rd_data comes back registered (1-cycle latency) from npu_top
    // =========================================================================
    assign dmem_rd_en   = apb_read & sel_dmem;
    assign dmem_rd_addr = PADDR[9:2];

    // =========================================================================
    // PRDATA mux
    // =========================================================================
    always_comb begin
        case (1'b1)
            sel_ctrl : PRDATA = {30'b0, done_processing, npu_done};
            sel_dmem : PRDATA = dmem_rd_data;   // registered in npu_top
            sel_imem : PRDATA = 32'h0;          // write-only from APB side
            default  : PRDATA = 32'hDEAD_BEEF; // unmapped
        endcase
    end

    // =========================================================================
    // PREADY
    //   Writes           → always 1  (single-cycle, no wait states)
    //   DMEM read        → hold 0 for 1 extra cycle (absorb registered latency)
    //   Everything else  → always 1
    // =========================================================================
    logic dmem_rd_pending;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dmem_rd_pending <= 1'b0;
        else        dmem_rd_pending <= apb_read & sel_dmem & ~dmem_rd_pending;
    end

    assign PREADY  = PWRITE                       ? 1'b1 :
                     (sel_dmem & ~dmem_rd_pending) ? 1'b0 :
                                                     1'b1;

    // =========================================================================
    // PSLVERR — access to unmapped address region
    // =========================================================================
    assign PSLVERR = PSEL & PENABLE & sel_none;

endmodule