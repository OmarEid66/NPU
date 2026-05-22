module baud_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] divisor,    // clk_freq / baud_rate
    output reg         tick
);

    reg [15:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 16'd0;
            tick    <= 1'b0;
        end else begin
            if (counter == divisor - 1) begin
                counter <= 16'd0;
                tick    <= 1'b1;
            end else begin
                counter <= counter + 1;
                tick    <= 1'b0;
            end
        end
    end

endmodule
