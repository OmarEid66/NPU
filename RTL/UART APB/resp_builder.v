// Response Builder
// Response format: STATUS DATA[3:0](read only)
// STATUS: 0xAC = ACK, 0xEE = error
module resp_builder (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] resp_data,
    input  wire        resp_error,
    input  wire        resp_is_read,
    input  wire        resp_valid,
    input  wire        tx_busy,
    output reg  [7:0]  tx_data,
    output reg         tx_start,
    output wire        resp_ready
);

    localparam S_IDLE   = 3'd0,
               S_STATUS = 3'd1,
               S_WAIT   = 3'd2,
               S_DATA   = 3'd3,
               S_DONE   = 3'd4;

    reg [2:0]  state;
    reg [1:0]  byte_cnt;
    reg [31:0] data_reg;
    reg        is_read;
    reg        error_reg;

    assign resp_ready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            byte_cnt  <= 2'd0;
            data_reg  <= 32'd0;
            tx_data   <= 8'd0;
            tx_start  <= 1'b0;
            is_read   <= 1'b0;
            error_reg <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (resp_valid) begin
                        data_reg  <= resp_data;
                        is_read   <= resp_is_read;
                        error_reg <= resp_error;
                        state     <= S_STATUS;
                    end
                end

                S_STATUS: begin
                    if (!tx_busy) begin
                        tx_data  <= error_reg ? 8'hEE : 8'hAC;
                        tx_start <= 1'b1;
                        if (is_read && !error_reg) begin
                            state    <= S_WAIT;
                            byte_cnt <= 2'd0;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                S_WAIT: begin
                    // Wait for TX to finish before sending next byte
                    if (!tx_busy && !tx_start) begin
                        state <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (!tx_busy) begin
                        tx_data  <= data_reg[31:24];
                        tx_start <= 1'b1;
                        data_reg <= {data_reg[23:0], 8'd0};
                        if (byte_cnt == 2'd3) begin
                            state <= S_DONE;
                        end else begin
                            byte_cnt <= byte_cnt + 1;
                            state    <= S_WAIT;
                        end
                    end
                end

                S_DONE: begin
                    if (!tx_busy && !tx_start)
                        state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
