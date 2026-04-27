// 2-to-1 Multiplexer in SystemVerilog

module mux2x1 (

input logic a,
input logic b,
input logic sel,
output logic y
);

// The output y is assigned based on the value of sel
assign y = sel ? b : a;

endmodule
