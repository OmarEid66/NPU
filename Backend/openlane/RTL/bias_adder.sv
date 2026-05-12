module bias_adder #(
    parameter SA_SIZE    = 4,
    parameter DATA_W_OUT = 32
)(
    input  logic clk,
    input  logic rst_n,

    input  logic valid_in,
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0] psum_in,
    input  logic [SA_SIZE-1:0][DATA_W_OUT-1:0] bias_in,

    output logic valid_out,
    output logic [SA_SIZE-1:0][DATA_W_OUT-1:0] data_out
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            data_out  <= '0;
        end else begin
            valid_out <= valid_in;
            // Add bias and register it for the next pipeline stage
            for (int i = 0; i < SA_SIZE; i++) begin
                data_out[i] <= psum_in[i] + bias_in[i];
            end
        end
    end

endmodule