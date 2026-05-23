module uart_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,       // 16x baud rate tick
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,
    output reg        busy
);

    localparam IDLE  = 2'd0,
               START = 2'd1,
               DATA  = 2'd2,
               STOP  = 2'd3;

    reg [1:0] state;
    reg [3:0] tick_cnt;
    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            tick_cnt  <= 4'd0;
            bit_cnt   <= 3'd0;
            shift_reg <= 8'd0;
            tx        <= 1'b1;
            busy      <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        state     <= START;
                        shift_reg <= data;
                        tick_cnt  <= 4'd0;
                        busy      <= 1'b1;
                    end
                end

                START: begin
                    tx <= 1'b0;
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin
                            state    <= DATA;
                            tick_cnt <= 4'd0;
                            bit_cnt  <= 3'd0;
                        end else begin
                            tick_cnt <= tick_cnt + 1;
                        end
                    end
                end

                DATA: begin
                    tx <= shift_reg[0];
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin
                            tick_cnt <= 4'd0;
                            shift_reg <= {1'b0, shift_reg[7:1]};
                            if (bit_cnt == 3'd7) begin
                                state <= STOP;
                            end else begin
                                bit_cnt <= bit_cnt + 1;
                            end
                        end else begin
                            tick_cnt <= tick_cnt + 1;
                        end
                    end
                end

                STOP: begin
                    tx <= 1'b1;
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin
                            state <= IDLE;
                            busy  <= 1'b0;
                        end else begin
                            tick_cnt <= tick_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
