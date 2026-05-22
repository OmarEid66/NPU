// APB Master FSM
// Executes single-word read/write transactions on the APB bus
module apb_master (
    input  wire        clk,
    input  wire        rst_n,
    // Command interface
    input  wire [31:0] cmd_addr,
    input  wire [31:0] cmd_wdata,
    input  wire        cmd_write,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    // Response interface
    output reg  [31:0] resp_data,
    output reg         resp_error,
    output reg         resp_is_read,
    output reg         resp_valid,
    input  wire        resp_ready,
    // APB Master signals
    output reg  [31:0] PADDR,
    output reg         PSEL,
    output reg         PENABLE,
    output reg         PWRITE,
    output reg  [31:0] PWDATA,
    input  wire [31:0] PRDATA,
    input  wire        PREADY,
    input  wire        PSLVERR
);

    localparam S_IDLE   = 2'd0,
               S_SETUP  = 2'd1,
               S_ACCESS = 2'd2,
               S_RESP   = 2'd3;

    reg [1:0] state;

    assign cmd_ready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            PADDR       <= 32'd0;
            PSEL        <= 1'b0;
            PENABLE     <= 1'b0;
            PWRITE      <= 1'b0;
            PWDATA      <= 32'd0;
            resp_data   <= 32'd0;
            resp_error  <= 1'b0;
            resp_is_read<= 1'b0;
            resp_valid  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    resp_valid <= 1'b0;
                    if (cmd_valid) begin
                        PADDR  <= cmd_addr;
                        PWRITE <= cmd_write;
                        PWDATA <= cmd_wdata;
                        PSEL   <= 1'b1;
                        state  <= S_SETUP;
                    end
                end

                S_SETUP: begin
                    PENABLE <= 1'b1;
                    state   <= S_ACCESS;
                end

                S_ACCESS: begin
                    if (PREADY) begin
                        resp_data    <= PRDATA;
                        resp_error   <= PSLVERR;
                        resp_is_read <= ~PWRITE;
                        PSEL         <= 1'b0;
                        PENABLE      <= 1'b0;
                        state        <= S_RESP;
                    end
                end

                S_RESP: begin
                    if (resp_ready) begin
                        resp_valid <= 1'b1;
                        state      <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
