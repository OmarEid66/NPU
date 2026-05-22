module pingpong_buffer #(
    parameter int ROWS   = 4,
    parameter int COLS   = 4,
    parameter int WIDTH  = 8,
    parameter int ADDR_W = 3
)(
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     wr_en,
    input  logic [ADDR_W-1:0]        wr_byte_addr, 
    input  logic [31:0]              wr_data,

    input  logic [$clog2(ROWS)-1:0]  rd_row,
    output logic [COLS*WIDTH-1:0]    rd_data,

    input  logic                     swap,
    output logic                     fill_done,
    output logic                     active_bank
);

    logic [ROWS-1:0][COLS-1:0][WIDTH-1:0] bank_a;
    logic [ROWS-1:0][COLS-1:0][WIDTH-1:0] bank_b;

    logic [2:0] fill_count;

    // FIXED: Map address directly to the row index for 4x4 (1 word/row)
    logic [1:0] wr_row;
    assign wr_row = wr_byte_addr[1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_count <= '0;
            fill_done  <= 1'b0;
        end else begin
            fill_done <= 1'b0;
            if (wr_en) begin
                if (fill_count == 3'd3) begin
                    fill_count <= '0;
                    fill_done  <= 1'b1;
                end else begin
                    fill_count <= fill_count + 3'd1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_bank <= 1'b0;
        else if (swap)
            active_bank <= ~active_bank;
    end

    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (active_bank == 1'b0) begin
                bank_b[wr_row][0] <= wr_data[ 7: 0];
                bank_b[wr_row][1] <= wr_data[15: 8];
                bank_b[wr_row][2] <= wr_data[23:16];
                bank_b[wr_row][3] <= wr_data[31:24];
            end else begin
                bank_a[wr_row][0] <= wr_data[ 7: 0];
                bank_a[wr_row][1] <= wr_data[15: 8];
                bank_a[wr_row][2] <= wr_data[23:16];
                bank_a[wr_row][3] <= wr_data[31:24];
            end
        end
    end

    always_comb begin
        for (int c = 0; c < COLS; c++) begin
            if (active_bank == 1'b0)
                rd_data[c*WIDTH +: WIDTH] = bank_a[rd_row][c];
            else
                rd_data[c*WIDTH +: WIDTH] = bank_b[rd_row][c];
        end
    end

endmodule