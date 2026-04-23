module pooling_unit_tb;
//declare the parameters and identifiers
parameter no_rows = 5 ;
parameter no_cols = 5 ;
parameter filter_row = 2;
parameter filter_col = 2;
parameter DATA_WIDTH = 32;
logic clk = 1'b0 , arstn,en;
logic [DATA_WIDTH-1:0] in [0:(no_rows*no_cols)-1];
logic [DATA_WIDTH+1:0] out [0:(2**(filter_row*filter_col))-1];
logic done;
//Instantiate the module under test
pooling_unit DUT(.*);
//Generate the clock
localparam T = 10 ;
always #(T/2) clk = ~ clk ;
//Create the stimulis using initial block
initial begin
    arstn = 1'b0 ;
    en = 1'b0;
    repeat(2) @(negedge clk);
    arstn = 1'b1 ;
    en = 1'b1 ;
    foreach (in[i]) begin
        in[i] = i ;
    end
    repeat(16) @(negedge clk);
    en = 1'b0 ;
    foreach (in[i]) begin
        in[i] = $urandom_range(0,10) ;
    end
    repeat(3) @(negedge clk);
    en = 1'b1 ;
    repeat(16) @(negedge clk);
    en = 1'b0 ; 
    #2 $stop;
end
endmodule
