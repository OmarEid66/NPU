module bias_buffer #(
    parameter SA_SIZE    = 4,
    parameter DATA_W_OUT = 32
)(
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                wr_en,
    input  logic [$clog2(SA_SIZE)-1:0]          wr_addr,
    input  logic [DATA_W_OUT-1:0]               wr_data,
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0]  rd_data
);

logic [DATA_W_OUT-1:0] mem [SA_SIZE];

always_ff @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
end

genvar i;
generate
    for (i = 0; i < SA_SIZE; i++) begin : BIAS_RD
        assign rd_data[i] = mem[i];
    end
endgenerate

endmodule