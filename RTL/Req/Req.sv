// =============================================================================
// Module: requantization
// Description: Reduces precision from INT32 to INT8 using Dyadic Numbers.
//              Implements the operation: qo = qa * b >> c
//              where b/2^c is the dyadic approximation of the scaling
//              factor ratio (Sa/So), fixed at design time per layer.
//
//              Based on SwiftTron paper (Fig. 7):
//              qo = qa * (Sa/So) ≈ qa * (b / 2^c)
//
// Parameters:
//   B_WIDTH  - Bit width of the dyadic multiplier b   (default: 32)
//   C_WIDTH  - Bit width of the shift amount c        (default: 5)
// =============================================================================
module requantization #(
    parameter B_WIDTH = 32,     // Width of dyadic numerator b
    parameter C_WIDTH = 5       // Width of shift amount c (max shift = 2^5 = 32)
)
(
    input  logic                clk,
    input  logic                rst_n,

    input  logic signed [31:0]  qa,         // INT32 input (from MatMul accumulator)
    input  logic        [B_WIDTH-1:0] b,    // Dyadic numerator  — fixed per layer at design time
    input  logic        [C_WIDTH-1:0] c,    // Dyadic shift amount — fixed per layer at design time

    output logic signed [7:0]   qo          // INT8 requantized output
);

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    logic signed [63:0] mul_result;     // Full-precision product (32+32 bits to avoid overflow)
    logic signed [63:0] shifted;        // After right shift by c
    logic signed [7:0]  clipped;        // After saturation clipping to INT8 range [-128, 127]

    // -------------------------------------------------------------------------
    // Step 1: Multiply qa by dyadic numerator b
    //         qa is INT32 (signed), b is treated as unsigned dyadic coefficient
    //         Result needs 64 bits to hold the full product safely
    // -------------------------------------------------------------------------
    assign mul_result = qa * $signed({1'b0, b});    // Zero-extend b to make it unsigned-signed safe

    // -------------------------------------------------------------------------
    // Step 2: Right shift by c (arithmetic shift to preserve sign)
    //         Implements division by 2^c using >>> (arithmetic right shift)
    //         This is the dyadic number division: b / 2^c
    // -------------------------------------------------------------------------
    assign shifted = mul_result >>> c;

    // -------------------------------------------------------------------------
    // Step 3: Saturate/clip result to INT8 range [-128, 127]
    //         Prevents overflow when casting 64-bit result back to 8 bits
    // -------------------------------------------------------------------------
    always_comb begin
        if (shifted > 64'sh000000000000007F)        // Overflow:  clamp to +127
            clipped = 8'sh7F;
        else if (shifted < 64'shFFFFFFFFFFFFFF80)   // Underflow: clamp to -128
            clipped = 8'sh80;
        else
            clipped = shifted[7:0];                 // Within range: safe truncation
    end

    // -------------------------------------------------------------------------
    // Step 4: Register the output (pipeline stage)
    //         Synchronous reset, output registered for timing closure
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n)
            qo <= 8'sh00;
        else
            qo <= clipped;
    end

endmodule