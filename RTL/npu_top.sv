module npu_top #() 
(
input       clk,
input       rst_n,
);


// SRAM 
reg  [3:0]   WE0;
reg          EN0;
reg  [7:0]   A0;
reg  [31:0]  Di0;
wire [31:0]  Do0;
reg          EN1;
reg  [7:0]   A1;
wire [31:0]  Do1;

RAM256_1RW1R SRAM (
    .CLK(clk),
    .WE0(WE0),
    .EN0(EN0),
    .EN1(EN1),
    .A1(A1),
    .Do1(Do1),
    .A0(A0),
    .Di0(Di0),
    .Do0(Do0)
);


endmodule