module mux2x1 #(
    parameter DATA_WIDTH = 1
)(
    input  logic [DATA_WIDTH-1:0] a,
    input  logic [DATA_WIDTH-1:0] b,
    input  logic                  sel,    // 0 → a, 1 → b
    output logic [DATA_WIDTH-1:0] y
);
 
assign y = sel ? b : a;
 
endmodule