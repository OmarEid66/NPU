

module acc_buffer #(parameter DATA_W = 256, ADDR = 3 )(
    input logic clk ,

    input logic wr_en,
    input logic [ADDR-1:0] wr_addr,
    input logic [DATA_W-1:0] wr_data,

    input logic [ADDR-1:0] rd_addr,
    output logic [DATA_W-1:0] rd_data
);


logic [DATA_W-1:0] mem [0:2**ADDR-1];

// ── Write ─────────────────────────────────────────
    always @(posedge clk) begin
            if (wr_en) begin
                mem[wr_addr] <= wr_data;
            end
    end

    // ── Read (1 cycle latency) ────────────────────────
    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end



endmodule