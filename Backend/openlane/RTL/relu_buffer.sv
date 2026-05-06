module relu_buffer #(
    parameter SA_SIZE    = 4,
    parameter DATA_WIDTH = 8   
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                                  wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]            wr_addr,
    input  var logic [SA_SIZE-1:0][DATA_WIDTH-1:0] wr_data, // FIXED: Added 'var'

    input  logic [$clog2(SA_SIZE)-1:0]            rd_addr,
    output logic [SA_SIZE-1:0][DATA_WIDTH-1:0]    rd_data
);

logic [SA_SIZE-1:0][DATA_WIDTH-1:0] mem [SA_SIZE];  

always_ff @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
end

assign rd_data = mem[rd_addr];

endmodule
