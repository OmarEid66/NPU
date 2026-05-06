module mux4x1 #(
    parameter DATA_WIDTH = 1
)(
    input  logic [DATA_WIDTH-1:0] a,     // sel = 2'b00
    input  logic [DATA_WIDTH-1:0] b,     // sel = 2'b01
    input  logic [DATA_WIDTH-1:0] c,     // sel = 2'b10
    input  logic [DATA_WIDTH-1:0] d,     // sel = 2'b11
    input  logic [1:0]            sel,   // 2-bit select
    output logic [DATA_WIDTH-1:0] y
);
 
always_comb begin
    case (sel)
        2'b00:   y = a;
        2'b01:   y = b;
        2'b10:   y = c;
        2'b11:   y = d;
        default: y = '0;
    endcase
end
 
endmodule