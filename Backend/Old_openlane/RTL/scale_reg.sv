
module scale_reg #(parameter DATA_WIDTH = 32)(
input logic clk ,
input logic rst_n ,
input logic wr_en ,
input logic [DATA_WIDTH-1:0] scale ,
output logic [DATA_WIDTH-1:0] scale_out 

);

logic [DATA_WIDTH-1:0] scale_reg ;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        scale_reg <= 0;
    else if (wr_en)
        scale_reg <= scale ;
end

assign scale_out = scale_reg ;

endmodule