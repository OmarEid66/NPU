module Req #(
    parameter B_WIDTH = 32,
    parameter C_WIDTH = 5
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic signed  [31:0]       qa,    // from acc/pb buffer
    input  logic         [B_WIDTH-1:0] b,    // M0 from register
    input  logic         [C_WIDTH-1:0] c,    // n from instruction
    output logic signed  [7:0]        qo
);
    logic signed [B_WIDTH+32:0] mul_result; // extra bit for safety
    logic signed [B_WIDTH+32:0] shifted;
    logic signed [7:0]          clipped;

    assign mul_result = qa * $signed({1'b0, b});
    assign shifted    = mul_result >>> c;

    always_comb begin
        if      (shifted > 64'sh000000000000007F)
            clipped = 8'sh7F;
        else if (shifted < 64'shFFFFFFFFFFFFFF80)
            clipped = 8'sh80;
        else
            clipped = shifted[7:0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) qo <= 8'sh00;
        else        qo <= clipped;
    end
endmodule