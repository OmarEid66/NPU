// ================================================================
//  npu_apb_decoder — APB slave interface for npu_top
//
//  Plugs into one APB slave slot of uart_apb_sys (e.g. Slave 0).
//  Each slot is 8 KB (SLOT_BITS = 13, addresses 0x000..0x1FFF).
//
//  Address map (word-aligned, PADDR[1:0] ignored):
//  ┌────────────┬──────────────────────────────────────────────────┐
//  │ Offset     │ Register / Region                                │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x000      │ CSR0 — Control                                   │
//  │            │   [0]   start_npu   (write 1 to pulse)           │
//  │            │   [1]   load_imem   (1 = host owns IMEM)         │
//  │            │   [2]   load_dmem   (1 = host owns DMEM)         │
//  │            │   [3]   dmem_rd_host (1 = host read port active) │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x004      │ CSR1 — Status  (read-only)                       │
//  │            │   [0]   npu_done                                 │
//  │            │   [1]   done_processing                          │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x008      │ DMEM_RD_ADDR — host read address latch           │
//  │            │   [7:0]  word address → dmem_rd_addr             │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x00C      │ DMEM_RD_DATA — host read data (read-only)        │
//  │            │   [31:0] dmem_rd_data from npu_top               │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x100..    │ IMEM window — 32 words (0x100..0x17C)            │
//  │   0x17C    │   Write: imem_wr_en pulse, addr = (offset-0x100)/4│
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x200..    │ DMEM window — 256 words (0x200..0x5FC)           │
//  │   0x5FC    │   Write: dmem_wr_en pulse, addr = (offset-0x200)/4│
//  │            │   Read: combinational from dmem_rd_data           │
//  └────────────┴──────────────────────────────────────────────────┘
//
//  APB timing:
//    All registers respond in 1 cycle (PREADY always 1).
//    start_npu is self-clearing: it pulses HIGH for exactly one
//    clock cycle (the ENABLE phase) then clears itself.
//
//  Verilog-2001 compatible (matches your other .v files).
// ================================================================

module npu_apb_decoder #(
    parameter SLOT_BITS   = 13,   // must match uart_apb_sys
    parameter SRAM_ADDR_W = 8,    // 256-word DMEM
    parameter INST_ADDR_W = 5,    // 32-word IMEM
    parameter DATA_W      = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ── APB slave port (from uart_apb_sys) ─────────────────────
    input  wire                  PSEL,
    input  wire [SLOT_BITS-1:0]  PADDR,
    input  wire                  PENABLE,
    input  wire                  PWRITE,
    input  wire [DATA_W-1:0]     PWDATA,
    output reg  [DATA_W-1:0]     PRDATA,
    output wire                  PREADY,
    output wire                  PSLVERR,

    // ── npu_top control outputs ─────────────────────────────────
    output reg                   start_npu,
    output reg                   load_imem,
    output reg                   load_dmem,
    output reg                   dmem_rd_host,

    // ── IMEM write port (to npu_top) ───────────────────────────
    output reg  [3:0]                imem_wr_we,
    output reg                       imem_wr_en,
    output reg  [INST_ADDR_W-1:0]    imem_wr_addr,
    output reg  [DATA_W-1:0]         imem_wr_data,

    // ── DMEM write port (to npu_top) ───────────────────────────
    output reg                       dmem_wr_en,
    output reg  [3:0]                dmem_wr_be,
    output reg  [SRAM_ADDR_W-1:0]    dmem_wr_addr,
    output reg  [DATA_W-1:0]         dmem_wr_data,

    // ── DMEM read port (to/from npu_top) ───────────────────────
    output reg  [SRAM_ADDR_W-1:0]    dmem_rd_addr,
    input  wire [DATA_W-1:0]         dmem_rd_data,
    output wire                      dmem_rd_en,

    // ── npu_top status inputs ───────────────────────────────────
    input  wire                  npu_done,
    input  wire                  done_processing
);

// ================================================================
//  APB handshake
//  All registers respond in 1 wait state — PREADY always HIGH.
//  No error conditions → PSLVERR always LOW.
// ================================================================
assign PREADY  = 1'b1;
assign PSLVERR = 1'b0;

// Active APB transaction: selected, enabled
wire apb_active = PSEL & PENABLE;
wire apb_wr     = apb_active & PWRITE;
wire apb_rd     = apb_active & ~PWRITE;

// ================================================================
//  Address decode — region select
// ================================================================
// CSR region:  offset < 0x100
// IMEM region: 0x100 <= offset < 0x180  (32 words × 4 bytes)
// DMEM region: 0x200 <= offset < 0x600  (256 words × 4 bytes)

wire [SLOT_BITS-1:0] offset = PADDR;   // PADDR is already slot-local

wire sel_csr  = (offset[SLOT_BITS-1:8] == 0);          // 0x000..0x0FF
wire sel_imem = (offset[SLOT_BITS-1:7] == {{(SLOT_BITS-7){1'b0}}, 2'b10});
                                                         // 0x100..0x17F
wire sel_dmem = (offset[SLOT_BITS-1:10] == {{(SLOT_BITS-10){1'b0}}, 2'b10});
                                                         // 0x200..0x5FF

// CSR sub-address (word index within CSR region)
wire [5:0] csr_word = offset[7:2];   // word address inside CSR

// IMEM word address:  bits [6:2] of offset  (32 words)
wire [INST_ADDR_W-1:0] imem_word_addr = offset[INST_ADDR_W+1:2];

// DMEM word address:  bits [9:2] of offset  (256 words)
wire [SRAM_ADDR_W-1:0] dmem_word_addr = offset[SRAM_ADDR_W+1:2];

// ================================================================
//  DMEM read enable:
//  HIGH during an APB read to the DMEM window, OR
//  when dmem_rd_host is set and the host latched a read address.
//  We route dmem_rd_en → npu_top so it enables SRAM port 0 read.
// ================================================================
assign dmem_rd_en = dmem_rd_host;

// ================================================================
//  CSR0 — Control register
//  Bits: [3]=dmem_rd_host [2]=load_dmem [1]=load_imem [0]=start_npu
//
//  start_npu is write-1-to-pulse: it clears itself every cycle.
//  The remaining bits are sticky (hold until explicitly cleared).
// ================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        start_npu    <= 1'b0;
        load_imem    <= 1'b0;
        load_dmem    <= 1'b0;
        dmem_rd_host <= 1'b0;
    end else begin
        // start_npu always self-clears (1-cycle pulse)
        start_npu <= 1'b0;

        if (apb_wr && sel_csr && csr_word == 6'd0) begin
            start_npu    <= PWDATA[0];   // write-1-to-pulse
            load_imem    <= PWDATA[1];
            load_dmem    <= PWDATA[2];
            dmem_rd_host <= PWDATA[3];
        end
    end
end

// ================================================================
//  DMEM read address latch (CSR offset 0x008, word 2)
//  Write the word address here to set up a DMEM read.
//  Then read CSR offset 0x00C to get the data back.
// ================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        dmem_rd_addr <= {SRAM_ADDR_W{1'b0}};
    else if (apb_wr && sel_csr && csr_word == 6'd2)
        dmem_rd_addr <= PWDATA[SRAM_ADDR_W-1:0];
    // Also support direct DMEM window reads: address set combinationally
    else if (apb_rd && sel_dmem)
        dmem_rd_addr <= dmem_word_addr;
end

// ================================================================
//  IMEM write port
// ================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        imem_wr_en   <= 1'b0;
        imem_wr_we   <= 4'h0;
        imem_wr_addr <= {INST_ADDR_W{1'b0}};
        imem_wr_data <= {DATA_W{1'b0}};
    end else begin
        imem_wr_en <= 1'b0;   // default: no write
        if (apb_wr && sel_imem) begin
            imem_wr_en   <= 1'b1;
            imem_wr_we   <= 4'hF;           // full-word write
            imem_wr_addr <= imem_word_addr;
            imem_wr_data <= PWDATA;
        end
    end
end

// ================================================================
//  DMEM write port
// ================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dmem_wr_en   <= 1'b0;
        dmem_wr_be   <= 4'h0;
        dmem_wr_addr <= {SRAM_ADDR_W{1'b0}};
        dmem_wr_data <= {DATA_W{1'b0}};
    end else begin
        dmem_wr_en <= 1'b0;  // default: no write
        if (apb_wr && sel_dmem) begin
            dmem_wr_en   <= 1'b1;
            dmem_wr_be   <= 4'hF;
            dmem_wr_addr <= dmem_word_addr;
            dmem_wr_data <= PWDATA;
        end
    end
end

// ================================================================
//  APB read data mux
// ================================================================
always @(*) begin
    PRDATA = {DATA_W{1'b0}};

    if (apb_rd) begin
        if (sel_csr) begin
            case (csr_word)
                6'd0: PRDATA = {28'b0, dmem_rd_host, load_dmem, load_imem, start_npu};
                6'd1: PRDATA = {30'b0, done_processing, npu_done};
                6'd2: PRDATA = {{(DATA_W-SRAM_ADDR_W){1'b0}}, dmem_rd_addr};
                6'd3: PRDATA = dmem_rd_data;   // 0x00C: read DMEM data
                default: PRDATA = {DATA_W{1'b0}};
            endcase
        end else if (sel_dmem) begin
            // Direct DMEM window read
            // dmem_rd_addr is updated in the registered always block
            // but for APB reads the data is available the next cycle;
            // PREADY=1 so the master samples PRDATA on the same edge.
            // We present the combinational sram output directly.
            PRDATA = dmem_rd_data;
        end
    end
end

endmodule