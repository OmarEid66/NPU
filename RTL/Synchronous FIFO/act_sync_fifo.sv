// =============================================================================
// Module: act_sync_fifo_8x8
// Description: An array of 8 synchronous FIFOs, each DWIDTH bits wide.
//              Split into two groups of 4:
//                - Group 0 (indices 0–3): written by wr_act_0
//                - Group 1 (indices 4–7): written by wr_act_1
//              All 8 FIFOs share a common read enable (r_act).
//              The global empty/full flags are asserted only when
//              ALL individual FIFOs are empty/full respectively.
// Parameters:
//   DEPTH  - Depth of each individual FIFO  (default: 8)
//   DWIDTH - Data width of each FIFO entry  (default: 8)
// =============================================================================
module act_sync_fifo_8x8 #(parameter DEPTH=8, DWIDTH=8)
(
    input   logic                   clk,                // System clock
    input   logic                   rst_n,              // Active low reset
    input   logic                   wr_act_0,           // Write enable for FIFO group 0 (indices 0–3)
    input   logic                   wr_act_1,           // Write enable for FIFO group 1 (indices 4–7)
    input   logic                   r_act,              // Shared read enable for all FIFOs
    input   logic [4*DWIDTH-1:0]    act_in,             // Packed 32-bit input bus shared by both groups
                                                        // Group 0: act_in[i*DWIDTH +: DWIDTH]
                                                        // Group 1: act_in[(i-4)*DWIDTH +: DWIDTH] (re-indexed)
    output  logic [DWIDTH-1:0]      act_out [DWIDTH],   // Output array: one DWIDTH-bit entry per FIFO
    output  logic                   empty,              // High when ALL 8 FIFOs are empty
    output  logic                   full                // High when ALL 8 FIFOs are full
);

    // -------------------------------------------------------------------------
    // Per-FIFO Status Wires
    // Bit i corresponds to FIFO instance i's empty/full status
    // -------------------------------------------------------------------------
    logic [DWIDTH-1:0] empty_w;     // empty_w[i] = 1 when FIFO i is empty
    logic [DWIDTH-1:0] full_w;      // full_w[i]  = 1 when FIFO i is full

    genvar i;
    generate

        // ---------------------------------------------------------------------
        // Group 0: FIFO instances 0 to (DWIDTH/2 - 1) → indices 0–3
        // Controlled by wr_act_0
        // Slicing: FIFO i gets act_in[i*DWIDTH +: DWIDTH]
        //   FIFO 0 → act_in[7:0]
        //   FIFO 1 → act_in[15:8]
        //   FIFO 2 → act_in[23:16]
        //   FIFO 3 → act_in[31:24]
        // ---------------------------------------------------------------------
        for (i=0; i<DWIDTH/2; i=i+1) begin : gen_fifo0
            sync_fifo #(.DEPTH(DEPTH), .DWIDTH(DWIDTH)) act_fifo0 (
                .rst_n  (rst_n),
                .clk    (clk),
                .wr_en  (wr_act_0),                         // Group 0 write enable
                .rd_en  (r_act),                            // Shared read enable
                .din    (act_in[i*DWIDTH +: DWIDTH]),       // DWIDTH-bit slice i from act_in
                .dout   (act_out[i]),                       // Output to act_out index i
                .empty  (empty_w[i]),                       // Per-FIFO empty flag
                .full   (full_w[i])                         // Per-FIFO full flag
            );
        end

        // ---------------------------------------------------------------------
        // Group 1: FIFO instances (DWIDTH/2) to (DWIDTH-1) → indices 4–7
        // Controlled by wr_act_1
        // Slicing: re-index with (i-4) to stay within act_in[31:0]
        //   FIFO 4 → act_in[7:0]   (i-4=0)
        //   FIFO 5 → act_in[15:8]  (i-4=1)
        //   FIFO 6 → act_in[23:16] (i-4=2)
        //   FIFO 7 → act_in[31:24] (i-4=3)
        // ---------------------------------------------------------------------
        for (i=4; i<DWIDTH; i=i+1) begin : gen_fifo1
            sync_fifo #(.DEPTH(DEPTH), .DWIDTH(DWIDTH)) act_fifo1 (
                .rst_n  (rst_n),
                .clk    (clk),
                .wr_en  (wr_act_1),                         // Group 1 write enable
                .rd_en  (r_act),                            // Shared read enable
                .din    (act_in[(i-4)*DWIDTH +: DWIDTH]),   // Re-indexed slice to stay within 32-bit bus
                .dout   (act_out[i]),                       // Output to act_out index i
                .empty  (empty_w[i]),                       // Per-FIFO empty flag
                .full   (full_w[i])                         // Per-FIFO full flag
            );
        end

    endgenerate

    // -------------------------------------------------------------------------
    // Global Status Flags — reduction AND across all 8 per-FIFO status bits
    //   empty: asserted only when every FIFO is empty
    //   full:  asserted only when every FIFO is full
    // -------------------------------------------------------------------------
    assign empty = &empty_w;
    assign full  = &full_w;

endmodule