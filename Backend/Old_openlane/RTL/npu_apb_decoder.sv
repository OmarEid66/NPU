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
//  │            │   [6:0]  word address → dmem_rd_addr             │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x00C      │ DMEM_RD_DATA — host read data (read-only)        │
//  │            │   [31:0] dmem_rd_data from npu_top               │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x100..    │ IMEM window — 32 words (0x100..0x17C)            │
//  │   0x17C    │   Write: imem_wr_en pulse, addr=(offset-0x100)/4 │
//  ├────────────┼──────────────────────────────────────────────────┤
//  │ 0x200..    │ DMEM window — 128 words (0x200..0x3FC)           │
//  │   0x3FC    │   Write: dmem_wr_en pulse, addr=(offset-0x200)/4 │
//  │            │   Read: combinational from dmem_rd_data           │
//  └────────────┴──────────────────────────────────────────────────┘
// ================================================================

module npu_apb_decoder #(
    parameter SLOT_BITS   = 13,
    parameter SRAM_ADDR_W = 6,    
    parameter INST_ADDR_W = 5,
    parameter DATA_W      = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  PSEL,
    input  wire [SLOT_BITS-1:0]  PADDR,
    input  wire                  PENABLE,
    input  wire                  PWRITE,
    input  wire [DATA_W-1:0]     PWDATA,
    output reg  [DATA_W-1:0]     PRDATA,
    output wire                  PREADY,
    output wire                  PSLVERR,

    output reg                   start_npu,
    output reg                   load_imem,
    output reg                   load_dmem,
    output reg                   dmem_rd_host,

    output reg  [3:0]                imem_wr_we,
    output reg                       imem_wr_en,
    output reg  [INST_ADDR_W-1:0]    imem_wr_addr,
    output reg  [DATA_W-1:0]         imem_wr_data,

    output reg                       dmem_wr_en,
    output reg  [3:0]                dmem_wr_be,
    output reg  [SRAM_ADDR_W-1:0]    dmem_wr_addr,
    output reg  [DATA_W-1:0]         dmem_wr_data,

    output reg  [SRAM_ADDR_W-1:0]    dmem_rd_addr,
    input  wire [DATA_W-1:0]         dmem_rd_data,
    output wire                      dmem_rd_en,

    input  wire                  npu_done,
    input  wire                  done_processing
);

assign PREADY  = 1'b1;
assign PSLVERR = 1'b0;

wire apb_active = PSEL & PENABLE;
wire apb_wr     = apb_active & PWRITE;
wire apb_rd     = apb_active & ~PWRITE;

wire [SLOT_BITS-1:0] offset = PADDR;

// FIXED: Cleaned up address decoding to strictly match 0x100 and 0x200
wire sel_csr  = (offset[SLOT_BITS-1:8] == 'd0);          // 0x000..0x0FF
wire sel_imem = (offset[SLOT_BITS-1:7] == 'd2);          // 0x100..0x17F (Bit 8 = 1)
wire sel_dmem = (offset[SLOT_BITS-1:8] == 'd2);          // FIXED: 0x200..0x2FF (64 words / 256 bytes)

wire [5:0] csr_word = offset[7:2];
wire [INST_ADDR_W-1:0] imem_word_addr = offset[INST_ADDR_W+1:2];
wire [SRAM_ADDR_W-1:0] dmem_word_addr = offset[SRAM_ADDR_W+1:2];

assign dmem_rd_en = dmem_rd_host;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        start_npu    <= 1'b0;
        load_imem    <= 1'b0;
        load_dmem    <= 1'b0;
        dmem_rd_host <= 1'b0;
    end else begin
        start_npu <= 1'b0;
        if (apb_wr && sel_csr && csr_word == 6'd0) begin
            start_npu    <= PWDATA[0];
            load_imem    <= PWDATA[1];
            load_dmem    <= PWDATA[2];
            dmem_rd_host <= PWDATA[3];
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        dmem_rd_addr <= {SRAM_ADDR_W{1'b0}};
    else if (apb_wr && sel_csr && csr_word == 6'd2)
        dmem_rd_addr <= PWDATA[SRAM_ADDR_W-1:0];
    else if (apb_rd && sel_dmem)
        dmem_rd_addr <= dmem_word_addr;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        imem_wr_en   <= 1'b0;
        imem_wr_we   <= 4'h0;
        imem_wr_addr <= {INST_ADDR_W{1'b0}};
        imem_wr_data <= {DATA_W{1'b0}};
    end else begin
        imem_wr_en <= 1'b0;
        if (apb_wr && sel_imem) begin
            imem_wr_en   <= 1'b1;
            imem_wr_we   <= 4'hF;
            imem_wr_addr <= imem_word_addr;
            imem_wr_data <= PWDATA;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dmem_wr_en   <= 1'b0;
        dmem_wr_be   <= 4'h0;
        dmem_wr_addr <= {SRAM_ADDR_W{1'b0}};
        dmem_wr_data <= {DATA_W{1'b0}};
    end else begin
        dmem_wr_en <= 1'b0;
        if (apb_wr && sel_dmem) begin
            dmem_wr_en   <= 1'b1;
            dmem_wr_be   <= 4'hF;
            dmem_wr_addr <= dmem_word_addr;
            dmem_wr_data <= PWDATA;
        end
    end
end

always @(*) begin
    PRDATA = {DATA_W{1'b0}};
    if (apb_rd) begin
        if (sel_csr) begin
            case (csr_word)
                6'd0: PRDATA = {28'b0, dmem_rd_host, load_dmem, load_imem, start_npu};
                6'd1: PRDATA = {30'b0, done_processing, npu_done};
                6'd2: PRDATA = {{(DATA_W-SRAM_ADDR_W){1'b0}}, dmem_rd_addr};
                6'd3: PRDATA = dmem_rd_data;
                default: PRDATA = {DATA_W{1'b0}};
            endcase
        end else if (sel_dmem) begin
            PRDATA = dmem_rd_data;
        end
    end
end

endmodule