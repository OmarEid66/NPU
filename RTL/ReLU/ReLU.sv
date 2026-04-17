// ============================================================
//  ReLU Module (Vectorized, Registered)
// ------------------------------------------------------------
//  Description:
//    Implements a parameterizable Rectified Linear Unit (ReLU)
//    over an array of signed input elements.
//
//    For each element:
//        if (value < 0) → output = 0
//        else           → output = value
//
//    The design is fully parallel and pipelined (1-cycle latency),
//    making it suitable for neural network accelerators and SIMD
//    datapaths.
//
//  Parameters:
//    DATA_WIDTH : Bit-width of each input/output element
//    ARRAY_SIZE : Number of parallel elements (vector size)
//
//  Interface:
//    clk       : Clock signal
//    rst_n     : Active-low asynchronous reset
//    in_data   : Input vector (ARRAY_SIZE elements)
//    out_data  : Output vector (ARRAY_SIZE elements)
//
//  Notes:
//    - ReLU decision is implemented using the MSB (sign bit),
//      avoiding a full comparator for better area/timing.
//    - Each element is processed independently (fully parallel).
//    - Output is registered → 1 cycle latency.
//
// ============================================================

module ReLU #(
    parameter int DATA_WIDTH = 8,   // Bit-width of each element
    parameter int ARRAY_SIZE = 8    // Number of elements in the vector
) (
    input  logic clk,                                       // System clock
    input  logic rst_n,                                     // Active-low reset
    input  logic signed [DATA_WIDTH-1:0] in_data [0:ARRAY_SIZE-1],  // Input vector
    output logic signed [DATA_WIDTH-1:0] out_data[0:ARRAY_SIZE-1]   // Output vector
);

    // --------------------------------------------------------
    //  Generate parallel ReLU units (one per vector element)
    // --------------------------------------------------------
    genvar i;
    generate 
        for (i = 0; i < ARRAY_SIZE; i++) begin : relu_array

            // Sequential logic: registers output (1-cycle latency)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    // Reset output to zero
                    out_data[i] <= '0;
                end 
                else begin
                    // ReLU operation:
                    // If MSB (sign bit) = 1 → negative → clamp to 0
                    // Else → pass input value unchanged
                    out_data[i] <= in_data[i][DATA_WIDTH-1] ? '0 : in_data[i];
                end
            end

        end
    endgenerate

endmodule