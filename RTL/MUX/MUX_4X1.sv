// 4-to-1 Multiplexer (MUX) in SystemVerilog
module mux4x1 (
    input logic a,
    input logic b,
    input logic c,
    input logic d,
    input logic sel,
    output logic y
);

// The output y is assigned based on the value of sel
assign y = (sel == 2'b00) ? a :
           (sel == 2'b01) ? b :
           (sel == 2'b10) ? c : d;


endmodule
