// Command Parser
// Protocol: SYNC0(0xDE) SYNC1(0xAD) CMD ADDR[3:0] DATA[3:0](write only)
// CMD: 0xA5 = write, 0x5A = read
// Includes a timeout: resets to SYNC0 if no byte arrives within TIMEOUT_CYCLES
module cmd_parser #(
    parameter TIMEOUT_CYCLES = 32'd5_000_000  // ~312ms at 16MHz
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output reg  [31:0] cmd_addr,
    output reg  [31:0] cmd_wdata,
    output reg         cmd_write,
    output reg         cmd_valid
);

    localparam S_SYNC0 = 3'd0,
               S_SYNC1 = 3'd1,
               S_CMD   = 3'd2,
               S_ADDR  = 3'd3,
               S_DATA  = 3'd4;

    reg [2:0]  state;
    reg [1:0]  byte_cnt;
    reg        is_write;
    reg [31:0] timeout_cnt;

    // Timeout: reset parser if stuck mid-frame
    wire timeout = (state != S_SYNC0) && (timeout_cnt == TIMEOUT_CYCLES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timeout_cnt <= 32'd0;
        end else begin
            if (rx_valid || state == S_SYNC0)
                timeout_cnt <= 32'd0;
            else
                timeout_cnt <= timeout_cnt + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_SYNC0;
            byte_cnt  <= 2'd0;
            cmd_addr  <= 32'd0;
            cmd_wdata <= 32'd0;
            cmd_write <= 1'b0;
            cmd_valid <= 1'b0;
            is_write  <= 1'b0;
        end else begin
            cmd_valid <= 1'b0;

            if (timeout) begin
                state <= S_SYNC0;
            end else if (rx_valid) begin
                case (state)
                    S_SYNC0: begin
                        if (rx_data == 8'hDE)
                            state <= S_SYNC1;
                    end

                    S_SYNC1: begin
                        if (rx_data == 8'hAD)
                            state <= S_CMD;
                        else if (rx_data == 8'hDE)
                            state <= S_SYNC1;
                        else
                            state <= S_SYNC0;
                    end

                    S_CMD: begin
                        if (rx_data == 8'hA5) begin
                            is_write <= 1'b1;
                            state    <= S_ADDR;
                            byte_cnt <= 2'd0;
                        end else if (rx_data == 8'h5A) begin
                            is_write <= 1'b0;
                            state    <= S_ADDR;
                            byte_cnt <= 2'd0;
                        end else begin
                            state <= S_SYNC0;
                        end
                    end

                    S_ADDR: begin
                        cmd_addr <= {cmd_addr[23:0], rx_data};
                        if (byte_cnt == 2'd3) begin
                            if (is_write) begin
                                state    <= S_DATA;
                                byte_cnt <= 2'd0;
                            end else begin
                                cmd_write <= 1'b0;
                                cmd_valid <= 1'b1;
                                state     <= S_SYNC0;
                            end
                        end else begin
                            byte_cnt <= byte_cnt + 1;
                        end
                    end

                    S_DATA: begin
                        cmd_wdata <= {cmd_wdata[23:0], rx_data};
                        if (byte_cnt == 2'd3) begin
                            cmd_write <= 1'b1;
                            cmd_valid <= 1'b1;
                            state     <= S_SYNC0;
                        end else begin
                            byte_cnt <= byte_cnt + 1;
                        end
                    end

                    default: state <= S_SYNC0;
                endcase
            end
        end
    end

endmodule
