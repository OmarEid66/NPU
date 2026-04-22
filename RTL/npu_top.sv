module npu_top #() 
(
input       clk,
input       rst_n,
);


// SRAM 
logic  [3:0]   WE0;
logic          EN0;
logic  [7:0]   A0;
logic  [31:0]  Di0;
logic [31:0]  Do0;
logic          EN1;
logic  [7:0]   A1;
logic [31:0]  Do1;

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

pingpong_buffer #(ROWS,COLS,WIDTH) act_pingpong_buffer (
.clk(clk),
.rst_n(rst_n),

.wr_en(),
.wr_byte_addr(),
.wr_data(),
.rd_row(),
.rd_data(),
.swap(),
.fill_done(),
.active_bank()
);


endmodule