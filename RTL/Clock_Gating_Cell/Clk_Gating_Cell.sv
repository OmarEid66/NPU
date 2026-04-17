module Clk_Gating_Cell (
    input logic clk_in,       // Input clock
    input logic enable,       // Clock enable signal
    output logic gated_clk     // Gated clock output
);

    // Internal register to hold the gated clock state
    logic Latch_Out;

    always @ (posedge clk_in or enable) begin
        if (!clk) begin
            Latch_Out <= enable ;
        end
    end

    assign gated_clk = clk_in && Latch_Out;

endmodule
