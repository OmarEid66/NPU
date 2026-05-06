// ================================================================
//  RAM32 — Instruction Memory (32 words × 32-bit)
//  Single-Port: 1 Read-Write
// ================================================================

module RAM32_ (
    input  logic        CLK,
    input  logic [3:0]  WE0,
    input  logic        EN0,
    input  logic [4:0]  A0,
    input  logic [31:0] Di0,
    output logic [31:0] Do0
);

    logic [31:0] mem [0:31];

    always_ff @(posedge CLK) begin
        if (EN0) begin
            if (WE0[0]) mem[A0][ 7: 0] <= Di0[ 7: 0];
            if (WE0[1]) mem[A0][15: 8] <= Di0[15: 8];
            if (WE0[2]) mem[A0][23:16] <= Di0[23:16];
            if (WE0[3]) mem[A0][31:24] <= Di0[31:24];
            Do0 <= mem[A0];
        end
    end

endmodule