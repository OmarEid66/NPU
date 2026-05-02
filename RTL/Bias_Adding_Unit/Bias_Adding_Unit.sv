// =============================================================================
// Bias_Adding_Unit.sv  —  NanoNPU Bias Adder
// =============================================================================
module Bias_Adding_Unit #(
    parameter int ACT_WIDTH  = 8,    // Activation input width  (Act FIFO  = 8b)
    parameter int BIAS_WIDTH = 32,   // Bias input width        (Bias FIFO = 32b)
    parameter int OUT_WIDTH  = 8,    // Output width to ReLU    (= ACT_WIDTH)
    parameter int NUM_CH     = 8     // Output channels (systolic array = 8x8)
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          start,
    input  logic                          valid_in,
    input  logic [NUM_CH*ACT_WIDTH-1:0]   act_in,
    input  logic [NUM_CH*BIAS_WIDTH-1:0]  bias_in,
    output logic                          valid_out,
    output logic [NUM_CH*OUT_WIDTH-1:0]   out,
    output logic                          done
);

    // =========================================================================
    // Saturation constants (signed OUT_WIDTH arithmetic)
    // =========================================================================
    localparam signed [BIAS_WIDTH-1:0] SAT_MAX = {{(BIAS_WIDTH-OUT_WIDTH){1'b0}},
                                                   1'b0, {(OUT_WIDTH-1){1'b1}}};  //  127
    localparam signed [BIAS_WIDTH-1:0] SAT_MIN = {{(BIAS_WIDTH-OUT_WIDTH){1'b1}},
                                                   1'b1, {(OUT_WIDTH-1){1'b0}}};  // -128

    // =========================================================================
    // Intermediate signals
    // =========================================================================
    logic signed [BIAS_WIDTH-1:0] sum_ext [NUM_CH];
    logic        [OUT_WIDTH-1:0]  result  [NUM_CH];

    // =========================================================================
    // Per-channel: sign-extend → add → saturate
    // =========================================================================
    generate
        for (genvar i = 0; i < NUM_CH; i++) begin : bias_addition

            // 1. Calculate sum continuously
            assign sum_ext[i] = BIAS_WIDTH'(signed'(act_in[i*ACT_WIDTH +: ACT_WIDTH]))
                              + signed'(bias_in[i*BIAS_WIDTH +: BIAS_WIDTH]);

            // 2. Saturate continuously using ternary operators
            assign result[i] = (sum_ext[i] > SAT_MAX) ? OUT_WIDTH'(SAT_MAX) :
                               (sum_ext[i] < SAT_MIN) ? OUT_WIDTH'(SAT_MIN) :
                                                        OUT_WIDTH'(sum_ext[i]);
        end
    endgenerate

    // =========================================================================
    // Output assembly
    // =========================================================================
    generate
        for (genvar i = 0; i < NUM_CH; i++) begin : out_assign
            assign out[i*OUT_WIDTH +: OUT_WIDTH] = result[i];
        end
    endgenerate

    assign valid_out = start & valid_in;
    assign done      = start & valid_in;

endmodule