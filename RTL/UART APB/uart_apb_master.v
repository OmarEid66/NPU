// UART-to-APB Master Bridge (Debug Backdoor)
// Protocol: SYNC(0xDEAD) + CMD + ADDR[31:0] + DATA[31:0](write only)
// Response: STATUS + DATA[31:0](read only)
//
// Lock register: writing 0xDEAD10CC to address 0xFFFFFFF0 permanently
// disables the bridge until the next reset. All subsequent commands
// receive an error (0xEE) response.
module uart_apb_master #(
    parameter DEFAULT_DIVISOR  = 16'd87,       // clk_freq / (baud * 16)
    parameter LOCK_ADDR        = 32'hFFFF_FFF0,
    parameter LOCK_KEY         = 32'hDEAD_10CC,
    parameter TIMEOUT_CYCLES   = 32'd5_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    // UART interface
    input  wire        uart_rx,
    output wire        uart_tx,
    // APB Master interface
    output wire [31:0] PADDR,
    output wire        PSEL,
    output wire        PENABLE,
    output wire        PWRITE,
    output wire [31:0] PWDATA,
    input  wire [31:0] PRDATA,
    input  wire        PREADY,
    input  wire        PSLVERR,
    // Status
    output wire        locked
);

    // Internal signals
    wire        baud_tick;
    wire [7:0]  rx_data;
    wire        rx_valid;
    wire [7:0]  tx_data;
    wire        tx_start;
    wire        tx_busy;
    wire [31:0] cmd_addr;
    wire [31:0] cmd_wdata;
    wire        cmd_write;
    wire        cmd_valid;
    wire        cmd_ready;
    wire [31:0] resp_data;
    wire        resp_error;
    wire        resp_is_read;
    wire        resp_valid;
    wire        resp_ready;

    // Lock register: two-stage so the lock command itself completes normally.
    // lock_armed latches immediately; lock_reg activates once the APB master
    // returns to idle, ensuring the lock command's own response is sent first.
    reg lock_armed;
    reg lock_reg;
    assign locked = lock_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_armed <= 1'b0;
            lock_reg   <= 1'b0;
        end else begin
            if (cmd_valid && cmd_write && cmd_addr == LOCK_ADDR && cmd_wdata == LOCK_KEY)
                lock_armed <= 1'b1;
            if (lock_armed && cmd_ready)
                lock_reg <= 1'b1;
        end
    end

    // Gate: when locked, block commands from reaching APB master and
    // inject an error response directly.
    wire        gated_cmd_valid;
    wire        locked_cmd_valid;

    assign gated_cmd_valid  = cmd_valid & ~lock_reg;
    assign locked_cmd_valid = cmd_valid &  lock_reg;

    // Mux response: from APB master normally, or error when locked
    wire [31:0] mux_resp_data;
    wire        mux_resp_error;
    wire        mux_resp_is_read;
    wire        mux_resp_valid;

    assign mux_resp_data    = lock_reg ? 32'd0       : resp_data;
    assign mux_resp_error   = lock_reg ? 1'b1        : resp_error;
    assign mux_resp_is_read = lock_reg ? ~cmd_write  : resp_is_read;
    assign mux_resp_valid   = lock_reg ? (locked_cmd_valid & resp_ready) : resp_valid;

    baud_gen u_baud_gen (
        .clk     (clk),
        .rst_n   (rst_n),
        .divisor (DEFAULT_DIVISOR[15:0]),
        .tick    (baud_tick)
    );

    uart_rx u_uart_rx (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (baud_tick),
        .rx    (uart_rx),
        .data  (rx_data),
        .valid (rx_valid)
    );

    uart_tx u_uart_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (baud_tick),
        .data  (tx_data),
        .start (tx_start),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );

    cmd_parser #(
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES)
    ) u_cmd_parser (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .cmd_addr (cmd_addr),
        .cmd_wdata(cmd_wdata),
        .cmd_write(cmd_write),
        .cmd_valid(cmd_valid)
    );

    apb_master u_apb_master (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_addr    (cmd_addr),
        .cmd_wdata   (cmd_wdata),
        .cmd_write   (cmd_write),
        .cmd_valid   (gated_cmd_valid),
        .cmd_ready   (cmd_ready),
        .resp_data   (resp_data),
        .resp_error  (resp_error),
        .resp_is_read(resp_is_read),
        .resp_valid  (resp_valid),
        .resp_ready  (resp_ready),
        .PADDR       (PADDR),
        .PSEL        (PSEL),
        .PENABLE     (PENABLE),
        .PWRITE      (PWRITE),
        .PWDATA      (PWDATA),
        .PRDATA      (PRDATA),
        .PREADY      (PREADY),
        .PSLVERR     (PSLVERR)
    );

    resp_builder u_resp_builder (
        .clk         (clk),
        .rst_n       (rst_n),
        .resp_data   (mux_resp_data),
        .resp_error  (mux_resp_error),
        .resp_is_read(mux_resp_is_read),
        .resp_valid  (mux_resp_valid),
        .tx_busy     (tx_busy),
        .tx_data     (tx_data),
        .tx_start    (tx_start),
        .resp_ready  (resp_ready)
    );

endmodule
