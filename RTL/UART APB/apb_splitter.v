// APB Bus Splitter / Address Decoder
// Routes a single APB master to up to 8 APB slave ports.
// Each slave occupies an 8 KB slot (0x2000 bytes).
//
// Address map:
//   Slave 0: 0x0000_0000 - 0x0000_1FFF
//   Slave 1: 0x0000_2000 - 0x0000_3FFF
//   Slave 2: 0x0000_4000 - 0x0000_5FFF
//   Slave 3: 0x0000_6000 - 0x0000_7FFF
//   Slave 4: 0x0000_8000 - 0x0000_9FFF
//   Slave 5: 0x0000_A000 - 0x0000_BFFF
//   Slave 6: 0x0000_C000 - 0x0000_DFFF
//   Slave 7: 0x0000_E000 - 0x0000_FFFF
//
// Accesses outside the 64 KB window respond with PSLVERR.

module apb_splitter #(
    parameter NUM_SLAVES  = 8,
    parameter SLOT_BITS   = 13    // log2(8192) = 13 bits per slot
)(
    // APB master side (from apb_master)
    input  wire [31:0] PADDR,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire        PWRITE,
    input  wire [31:0] PWDATA,
    output wire [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERR,

    // APB slave side — active-low active-high select per slave
    output wire [NUM_SLAVES-1:0]    PSELx,
    output wire [SLOT_BITS-1:0]     PADDR_o,
    output wire                     PENABLE_o,
    output wire                     PWRITE_o,
    output wire [31:0]              PWDATA_o,
    input  wire [NUM_SLAVES*32-1:0] PRDATA_i,
    input  wire [NUM_SLAVES-1:0]    PREADY_i,
    input  wire [NUM_SLAVES-1:0]    PSLVERR_i
);

    localparam SEL_BITS = 3;  // log2(NUM_SLAVES)
    localparam ADDR_TOP = SLOT_BITS + SEL_BITS - 1;  // bit 15

    // Slave index from address
    wire [SEL_BITS-1:0] slave_sel = PADDR[ADDR_TOP:SLOT_BITS];

    // Address is in range if upper bits [31:16] are zero
    wire in_range = (PADDR[31:ADDR_TOP+1] == {(32-ADDR_TOP-1){1'b0}});

    // Generate per-slave PSEL
    genvar i;
    generate
        for (i = 0; i < NUM_SLAVES; i = i + 1) begin : gen_psel
            assign PSELx[i] = PSEL & in_range & (slave_sel == i[SEL_BITS-1:0]);
        end
    endgenerate

    // Pass-through signals
    assign PADDR_o   = PADDR[SLOT_BITS-1:0];
    assign PENABLE_o = PENABLE;
    assign PWRITE_o  = PWRITE;
    assign PWDATA_o  = PWDATA;

    // Mux read data from selected slave
    wire [31:0] prdata_mux [0:NUM_SLAVES-1];
    generate
        for (i = 0; i < NUM_SLAVES; i = i + 1) begin : gen_prdata
            assign prdata_mux[i] = PRDATA_i[i*32 +: 32];
        end
    endgenerate

    assign PRDATA = in_range ? prdata_mux[slave_sel] : 32'd0;

    // Mux PREADY: default high for out-of-range (immediate error response)
    assign PREADY = in_range ? PREADY_i[slave_sel] : 1'b1;

    // Mux PSLVERR: assert for out-of-range accesses
    assign PSLVERR = in_range ? PSLVERR_i[slave_sel] : (PSEL & PENABLE);

endmodule
