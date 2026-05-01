// ============================================================
//  ReLU Module (Vectorized, Combinational)
// ------------------------------------------------------------
//  Description:
//    Implements a parameterizable Rectified Linear Unit (ReLU)
//    over an array of signed input elements.
//
//    For each element:
//        if (value < 0) → output = 0
//        else           → output = value
//
//    Fully combinational — no registers, zero latency.
//    The parent module (relu_unit) handles output registration.
//
//  Parameters:
//    DATA_WIDTH : Bit-width of each input/output element
//    ARRAY_SIZE : Number of parallel elements (vector size)
//
//  Notes:
//    - ReLU decision uses MSB (sign bit) — no full comparator.
//    - Each element processed independently (fully parallel).
//
// ============================================================

module ReLU #(
    parameter int DATA_WIDTH = 8,
    parameter int ARRAY_SIZE = 8
)(
    input  logic [DATA_WIDTH-1:0] in_data  [0:ARRAY_SIZE-1],
    output logic [DATA_WIDTH-1:0] out_data [0:ARRAY_SIZE-1]
);

    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : relu_array
            assign out_data[i] = in_data[i][DATA_WIDTH-1] ? '0 : in_data[i];
        end
    endgenerate

endmodule