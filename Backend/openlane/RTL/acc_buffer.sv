module acc_buffer #(
    parameter SA_SIZE    = 4,
    parameter DATA_W_OUT = 32
)(
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]          wr_addr,
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0]  wr_data,
    input  logic [$clog2(SA_SIZE)-1:0]          rd_addr,
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0]  rd_data
);

logic [SA_SIZE-1:0][DATA_W_OUT-1:0] mem [SA_SIZE];

always_ff @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
end

assign rd_data = mem[rd_addr];

endmodule