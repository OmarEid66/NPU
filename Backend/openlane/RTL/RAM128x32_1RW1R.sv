// ================================================================
//  RAM128x32_1RW1R — Data SRAM (128 words × 32-bit)  →  0.5 KB
//  Dual-Port: 1 Read-Write + 1 Read-Only
// ================================================================

module RAM128x32_1RW1R (
    input  logic        CLK,

    // Port 0 — Read-Write
    input  logic [3:0]  WE0,
    input  logic        EN0,
    input  logic [6:0]  A0,          // 7-bit: 2^7 = 128 words
    input  logic [31:0] Di0,
    output logic [31:0] Do0,

    // Port 1 — Read-Only
    input  logic        EN1,
    input  logic [6:0]  A1,          // 7-bit
    output logic [31:0] Do1
);

    logic [31:0] mem [0:127];

    always_ff @(posedge CLK) begin
        if (EN1)
            Do1 <= mem[A1];

        if (EN0) begin
            if (WE0[0]) mem[A0][ 7: 0] <= Di0[ 7: 0];
            if (WE0[1]) mem[A0][15: 8] <= Di0[15: 8];
            if (WE0[2]) mem[A0][23:16] <= Di0[23:16];
            if (WE0[3]) mem[A0][31:24] <= Di0[31:24];
            Do0 <= mem[A0];
        end
    end

endmodule