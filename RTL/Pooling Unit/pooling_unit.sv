module pooling_unit
#(
    parameter no_rows = 5 ,
    parameter no_cols = 5 ,
    parameter filter_row = 2,
    parameter filter_col = 2,
    parameter DATA_WIDTH = 32
)
(
    input  logic clk,arstn,en,
    input  logic [DATA_WIDTH-1:0] in [0:no_rows * no_cols-1], 
    output logic [DATA_WIDTH+1:0] out [0:(2**(filter_row * filter_col))-1],
    output logic done
);

localparam OUT_COLS = no_cols - filter_col + 1 ;
localparam OUT_ROWS = no_rows - filter_row + 1 ;
localparam TOTAL_OUT = OUT_ROWS * OUT_COLS ;
localparam TOTAL_IN = no_rows * no_cols ;
localparam TOTAL_FILTER = filter_row * filter_col ;
localparam ROW_JUMP = filter_col ;

logic [$clog2((no_rows*no_cols))-1:0] pool_addr [0:3];
logic [(filter_row+filter_col)-1:0] counter ;
logic [filter_col-1:0] col_count;


always_ff @(posedge clk, negedge arstn) begin
    if(!arstn) begin
        counter <= 'd0 ;
        col_count <= 'd0 ;
        pool_addr[0] <= 'd0 ;
        pool_addr[1] <= 'd1 ;
        pool_addr[2] <= no_rows ;
        pool_addr[3] <= no_rows+1 ;
        done <= 1'b0;
    end
    else if(en) begin
        if(counter == TOTAL_OUT - 1) begin
            done <= 1'b1 ;
            counter <= 'd0 ;
            col_count <= 'd0 ;
            pool_addr[0] <= 'd0 ;
            pool_addr[1] <= 'd1 ;
            pool_addr[2] <= no_rows ;
            pool_addr[3] <= no_rows+1 ;
        end
        else begin
            done <= 1'b0;
            counter <= counter + 1;
            col_count <= (col_count == OUT_COLS - 1)? 'd0 : col_count + 1;
            if(col_count != OUT_COLS - 1) begin
                pool_addr[0] <= pool_addr[0] + 1;
                pool_addr[1] <= pool_addr[1] + 1;
                pool_addr[2] <= pool_addr[2] + 1;
                pool_addr[3] <= pool_addr[3] + 1;
            end
            else begin
                pool_addr[0] <= pool_addr[0] + ROW_JUMP;
                pool_addr[1] <= pool_addr[1] + ROW_JUMP; 
                pool_addr[2] <= pool_addr[2] + ROW_JUMP;
                pool_addr[3] <= pool_addr[3] + ROW_JUMP;
            end
        end
        out[counter] <= (in[pool_addr[0]] + in[pool_addr[1]] + in[pool_addr[2]] + in[pool_addr[3]])>>2;
    end
    else begin
        done <= 1'b0 ;
    end
end

endmodule
