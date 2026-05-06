module relu_unit #(
    parameter SA_SIZE    = 4,
    parameter DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic done,
    output logic busy,

    output logic [$clog2(SA_SIZE)-1:0]         preq_rd_addr,
    input  var logic [SA_SIZE-1:0][DATA_WIDTH-1:0] preq_rd_data,  

    output logic                               relu_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]         relu_wr_addr,
    output logic [SA_SIZE-1:0][DATA_WIDTH-1:0] relu_wr_data   
);

localparam ROW_CNT_W = $clog2(SA_SIZE);

logic [ROW_CNT_W-1:0] rd_row_cnt;
logic                 running;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 running <= 1'b0;
    else if (start && !running) running <= 1'b1;
    else if (done)              running <= 1'b0;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        rd_row_cnt <= '0;
    else if (done)     rd_row_cnt <= '0;
    else if (start)    rd_row_cnt <= rd_row_cnt + 1'b1;
end

assign preq_rd_addr = rd_row_cnt;

logic [SA_SIZE-1:0][DATA_WIDTH-1:0] relu_comb;

ReLU #(
    .DATA_WIDTH (DATA_WIDTH),
    .ARRAY_SIZE (SA_SIZE)
) u_relu (
    .in_data  (preq_rd_data),
    .out_data (relu_comb)
);

logic                  wr_en_r;
logic [ROW_CNT_W-1:0]  wr_addr_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_en_r      <= 1'b0;
        wr_addr_r    <= '0;
        relu_wr_data <= 0;       // YOSYS FIX: Safely hardcoded to 0
    end else begin
        wr_en_r      <= start;
        wr_addr_r    <= rd_row_cnt;
        relu_wr_data <= relu_comb;
    end
end

assign relu_wr_en   = wr_en_r;
assign relu_wr_addr = wr_addr_r;
assign done = wr_en_r && (wr_addr_r == SA_SIZE - 1);
assign busy = running || start;

endmodule
