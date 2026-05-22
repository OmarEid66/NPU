module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,       // 16x baud rate tick
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);

    localparam IDLE  = 2'd0,
               START = 2'd1,
               DATA  = 2'd2,
               STOP  = 2'd3;

    reg [1:0] state;
    reg [3:0] tick_cnt;
    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;
    reg       rx_sync1, rx_sync2;

    // Double-flop synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            tick_cnt  <= 4'd0;
            bit_cnt   <= 3'd0;
            shift_reg <= 8'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (~rx_sync2) begin
                        state    <= START;
                        tick_cnt <= 4'd0;
                    end
                end

                START: begin
                    if (tick) begin
                        if (tick_cnt == 4'd7) begin
                            if (~rx_sync2) begin
                                state    <= DATA;
                                tick_cnt <= 4'd0;
                                bit_cnt  <= 3'd0;
                            end else begin
                                state <= IDLE;
                            end
                        end else begin
                            tick_cnt <= tick_cnt + 1;
                        end
                    end
                end

                DATA: begin
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin
                            tick_cnt  <= 4'd0;
                            shift_reg <= {rx_sync2, shift_reg[7:1]};
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
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin
                            state <= IDLE;
                            if (rx_sync2) begin
                                data  <= shift_reg;
                                valid <= 1'b1;
                            end
                        end else begin
                            tick_cnt <= tick_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
