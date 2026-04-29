module Clk_Gating_Cell (
    input logic clk,       // Input clock
    input logic enable,       // Clock enable signal
    output logic gated_clk     // Gated clock output
);

    // Internal register to hold the gated clock state
    logic Latch_Out;

    always @ (posedge clk or enable) begin
        if (!clk) begin
            Latch_Out <= enable ;
        end
    end

    assign gated_clk = clk && Latch_Out;

endmodule
