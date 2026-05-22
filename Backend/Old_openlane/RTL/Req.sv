module req_unit #(
    parameter SA_SIZE = 4,
    parameter B_WIDTH = 32,
    parameter C_WIDTH = 5
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,     
    output logic done,      
    output logic busy,      

    input  logic [B_WIDTH-1:0] b,       
    input  logic [C_WIDTH-1:0] c,       

    output logic [$clog2(SA_SIZE)-1:0]      pb_rd_addr,
    input  var logic [SA_SIZE-1:0][31:0]    pb_rd_data, // FIXED: Added 'var'

    output logic                            preq_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]      preq_wr_addr,
    output logic [SA_SIZE-1:0][7:0]         preq_wr_data  
);

localparam ROW_CNT_W = $clog2(SA_SIZE);

logic [ROW_CNT_W-1:0] row_cnt;       
logic                  running;       
logic                  last_row;

assign last_row = (row_cnt == SA_SIZE - 1);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 running <= 1'b0;
    else if (start && !running) running <= 1'b1;
    else if (done)              running <= 1'b0;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        row_cnt <= '0;
    else if (done)     row_cnt <= '0;          
    else if (start)    row_cnt <= row_cnt + 1'b1;
end

assign pb_rd_addr = row_cnt;

genvar col;
generate
    for (col = 0; col < SA_SIZE; col++) begin : REQ_COL
        logic signed [63:0] mul_result;  
        logic signed [63:0] shifted;     
        logic        [7:0]  clipped;

        assign mul_result = $signed(pb_rd_data[col]) * $signed(b);
        assign shifted = mul_result >>> c;

        assign clipped = (shifted[63] == 1'b0) ? 
                         ( (|shifted[62:7])  ? 8'sh7F : shifted[7:0] ) : 
                         ( (~&shifted[62:7]) ? 8'sh80 : shifted[7:0] );

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) preq_wr_data[col] <= 8'sh00;
            else        preq_wr_data[col] <= clipped;
        end
    end
endgenerate

logic                  wr_en_r;
logic [ROW_CNT_W-1:0]  wr_addr_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_en_r   <= 1'b0;
        wr_addr_r <= '0;
    end else begin
        wr_en_r   <= start;          
        wr_addr_r <= row_cnt;        
    end
end

assign preq_wr_en   = wr_en_r;
assign preq_wr_addr = wr_addr_r;

assign done = wr_en_r && (wr_addr_r == SA_SIZE - 1);
assign busy = running || start;

endmodule