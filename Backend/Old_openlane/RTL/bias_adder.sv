module bias_adder #(
    parameter SA_SIZE    = 4,
    parameter DATA_W_OUT = 32
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    output logic done,
    output logic busy,

    output logic [$clog2(SA_SIZE)-1:0]          acc_rd_addr,
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0]  acc_rd_data,

    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0]  bias_rd_data,

    output logic                                 pb_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]           pb_wr_addr,
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0]  pb_wr_data
);

typedef enum logic [1:0] {
    BA_IDLE = 2'd0,
    BA_READ = 2'd1,
    BA_ADD  = 2'd2,
    BA_DONE = 2'd3
} ba_state_t;

ba_state_t state, next_state;

logic [$clog2(SA_SIZE)-1:0] row_cnt;
logic [$clog2(SA_SIZE)-1:0] row_cnt_r;
logic                        last_row;

assign last_row = (row_cnt == SA_SIZE - 1);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= BA_IDLE;
    else        state <= next_state;
end

always_comb begin
    next_state = state;
    case (state)
        BA_IDLE: if (start)  next_state = BA_READ;
        BA_READ:             next_state = BA_ADD;
        BA_ADD:  begin
            if (last_row)    next_state = BA_DONE;
            else             next_state = BA_READ;
        end
        BA_DONE:             next_state = BA_IDLE;
        default:             next_state = BA_IDLE;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row_cnt <= '0;
    else if (state == BA_IDLE)
        row_cnt <= '0;
    else if (state == BA_ADD && !last_row)
        row_cnt <= row_cnt + 1'b1;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) row_cnt_r <= '0;
    else if (state == BA_READ) row_cnt_r <= row_cnt;
end

assign acc_rd_addr = row_cnt;

genvar c;
generate
    for (c = 0; c < SA_SIZE; c++) begin : ADD_COL
        assign pb_wr_data[c] = acc_rd_data[c] + bias_rd_data[c];
    end
endgenerate

assign pb_wr_en   = (state == BA_ADD);
assign pb_wr_addr = row_cnt_r;
assign busy       = (state != BA_IDLE);
assign done       = (state == BA_DONE);

endmodule