// ============================================================
//  ReLU Module (Vectorized, Combinational)
// ============================================================

module ReLU #(
    parameter int DATA_WIDTH = 8,
    parameter int ARRAY_SIZE = 4
)(
    input  logic [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] in_data,   // FIXED: Packed Array
    output logic [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] out_data   // FIXED: Packed Array
);

    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : relu_array
            assign out_data[i] = in_data[i][DATA_WIDTH-1] ? '0 : in_data[i];
        end
    endgenerate

endmodule