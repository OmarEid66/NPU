module req_unit #(
    parameter SA_SIZE = 4,
    parameter B_WIDTH = 32,
    parameter C_WIDTH = 5
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,        // From sa_start (used to reset write address)
    input  logic valid_in,     // From bias_adder
    input  logic [SA_SIZE-1:0][31:0] data_in,

    input  logic [B_WIDTH-1:0] b,
    input  logic [C_WIDTH-1:0] c,

    output logic valid_out,
    output logic [$clog2(SA_SIZE)-1:0] preq_wr_addr,
    output logic [SA_SIZE-1:0][7:0] data_out  
);

    logic [$clog2(SA_SIZE)-1:0] wr_addr;

    // Yosys-safe Combinational logic arrays
    logic signed [63:0] mul_result [SA_SIZE-1:0];
    logic signed [63:0] shifted    [SA_SIZE-1:0];
    logic [7:0]         clipped    [SA_SIZE-1:0];

    always_comb begin
        for (int col = 0; col < SA_SIZE; col++) begin
            mul_result[col] = $signed(data_in[col]) * $signed(b);
            shifted[col]    = mul_result[col] >>> c;
            
            clipped[col]    = (shifted[col][63] == 1'b0) ?
                              ( (|shifted[col][62:7])  ? 8'sh7F : shifted[col][7:0] ) : 
                              ( (~&shifted[col][62:7]) ? 8'sh80 : shifted[col][7:0] );
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            wr_addr   <= '0;
            data_out  <= '0;
        end else begin
            valid_out <= valid_in;
            
            // Auto-increment the preq_buffer write address
            if (start) wr_addr <= '0;
            else if (valid_out) wr_addr <= wr_addr + 1'b1;

            // Pipeline register for the math
            if (valid_in) begin
                for (int col = 0; col < SA_SIZE; col++) begin
                    data_out[col] <= clipped[col];
                end
            end
        end
    end

    assign preq_wr_addr = wr_addr;

endmodule