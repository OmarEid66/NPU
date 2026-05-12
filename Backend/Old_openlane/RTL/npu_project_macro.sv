// SPDX-License-Identifier: Apache-2.0
// =============================================================================
//  npu_project_macro.sv (4x4 SA Version)
//
//  Wraps npu_system_top to fit the openframe_project_wrapper project-macro
//  port convention (identical to project_macro.v port list).
//
//  GPIO Pin Assignment
//  ─────────────────────────────────────────────────────────────────────────
//  Bottom GPIOs [14:0]  →  Right chip pads via bottom orange → Right Purple
//
//    BOT Pin  Dir     Signal
//    ───────  ───     ──────────────────────────────────────────────────────
//      [0]    IN      uart_rx          (host UART → NPU)
//      [1]    OUT     uart_tx          (NPU → host UART)
//      [2]    OUT     locked           (APB bus locked status)
//      [3]    OUT     npu_done         (NPU reached HALT)
//      [4]    OUT     done_processing  (all instructions processed)
//    [14:5]   ---     unused, safe high-Z
//
//  Right GPIOs [8:0]   →  Top chip pads via right orange → Top Purple
//    [8:0]    ---     unused, safe high-Z
//
//  Top GPIOs [13:0]    →  Left chip pads via top orange → Left Purple
//    [13:0]   ---     unused, safe high-Z
//
//  Drive Mode Encoding (Sky130 OpenFrame, 3 bits per pad):
//    3'b001  = input, no pull
//    3'b110  = strong push-pull output
//
//  Clock & Reset:
//    clk     ← proj_clk_out     from green_macro (gated sys_clk via ICG)
//    reset_n ← proj_reset_n_out from green_macro (sys_reset_n & proj_en)
//    The NPU is clock-gated and held in reset when its scan slot is disabled.
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module npu_project_macro
  //import /* nothing */; // no packages needed
#(
    // ── NPU / UART parameters (must match npu_system_top defaults) ──────────
    parameter int unsigned CLK_FREQ_HZ     = 8_000_000,
    parameter logic [15:0] DEFAULT_DIVISOR = 16'd87,      // ~115200 @ 8 MHz
    parameter logic [31:0] LOCK_ADDR       = 32'hFFFF_FFF0,
    parameter logic [31:0] LOCK_KEY        = 32'hDEAD_10CC,
    parameter int unsigned TIMEOUT_CYCLES  = 32'd5_000_000,
    parameter int unsigned SA_SIZE         = 4,           // FIXED: 4x4 Array
    parameter int unsigned DATA_W          = 8,
    parameter int unsigned DATA_W_PATH     = 32,
    parameter int unsigned INST_ADDR_W     = 5,
    parameter int unsigned INST_DATA_W     = 32,
    parameter int unsigned SRAM_DATA_W     = 32,
    parameter int unsigned SRAM_ADDR_W     = 6           
)(
`ifdef USE_POWER_PINS
    inout  logic vccd1,
    inout  logic vssd1,
`endif
    // ── Standard project-macro interface ──────────────────────────────────
    input  logic        clk,      // gated system clock from green_macro
    input  logic        reset_n,  // project reset (held low when slot disabled)
    input  logic        por_n,    // power-on-reset (unused by NPU directly)

    // ── Bottom GPIOs (15 bits) → Right chip pads ──────────────────────────
    input  logic [14:0] gpio_bot_in,
    output logic [14:0] gpio_bot_out,
    output logic [14:0] gpio_bot_oeb,  // 0 = project drives pad, 1 = high-Z
    output logic [44:0] gpio_bot_dm,   // drive mode [2:0] per pin, LSB-first

    // ── Right GPIOs (9 bits) → Top chip pads ──────────────────────────────
    input  logic  [8:0] gpio_rt_in,
    output logic  [8:0] gpio_rt_out,
    output logic  [8:0] gpio_rt_oeb,
    output logic [26:0] gpio_rt_dm,

    // ── Top GPIOs (14 bits) → Left chip pads ──────────────────────────────
    input  logic [13:0] gpio_top_in,
    output logic [13:0] gpio_top_out,
    output logic [13:0] gpio_top_oeb,
    output logic [41:0] gpio_top_dm
);

    // =========================================================================
    // 1. Internal NPU signals
    // =========================================================================
    logic uart_rx_w;
    logic uart_tx_w;
    logic locked_w;
    logic npu_done_w;
    logic done_processing_w;

    // =========================================================================
    // 2. npu_system_top instance
    // =========================================================================
    npu_system_top #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .DEFAULT_DIVISOR (DEFAULT_DIVISOR),
        .LOCK_ADDR       (LOCK_ADDR),
        .LOCK_KEY        (LOCK_KEY),
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
        .SA_SIZE         (SA_SIZE),
        .DATA_W          (DATA_W),
        .DATA_W_PATH     (DATA_W_PATH),
        .INST_ADDR_W     (INST_ADDR_W),
        .INST_DATA_W     (INST_DATA_W),
        .SRAM_DATA_W     (SRAM_DATA_W),
        .SRAM_ADDR_W     (SRAM_ADDR_W)
    ) u_npu_sys (
        .clk             (clk),
        .rst_n           (reset_n),
        .uart_rx         (uart_rx_w),
        .uart_tx         (uart_tx_w),
        .locked          (locked_w),
        .npu_done        (npu_done_w),
        .done_processing (done_processing_w)
    );

    // =========================================================================
    // 3. Bottom GPIO mapping
    //
    //   pin  oeb    dm        signal / direction
    //   ───  ─────  ────────  ──────────────────────────────────────────────
    //    0    1'b1  3'b001    uart_rx  : pad drives NPU  (input)
    //    1    1'b0  3'b110    uart_tx  : NPU drives pad  (output)
    //    2    1'b0  3'b110    locked                     (output)
    //    3    1'b0  3'b110    npu_done                   (output)
    //    4    1'b0  3'b110    done_processing            (output)
    //  14:5   1'b1  3'b001    unused                     (high-Z input)
    // =========================================================================

    // Receive uart_rx from BOT pad [0]
    assign uart_rx_w = gpio_bot_in[0];

    // Data driven onto pads
    always_comb begin
        gpio_bot_out        = '0;
        gpio_bot_out[1]     = uart_tx_w;
        gpio_bot_out[2]     = locked_w;
        gpio_bot_out[3]     = npu_done_w;
        gpio_bot_out[4]     = done_processing_w;
        // [14:5] stay 0 — unused outputs are safe low
    end

    // Output-enable bar (0 = project drives, 1 = high-Z / input)
    assign gpio_bot_oeb[0]    = 1'b1;               // uart_rx : pad drives
    assign gpio_bot_oeb[4:1]  = 4'b0000;            // uart_tx/locked/done : project drives
    assign gpio_bot_oeb[14:5] = 10'b1111111111;     // unused : high-Z

    // Drive modes — 3 bits per pad, packed [pin*3 +: 3]
    assign gpio_bot_dm[ 2: 0] = 3'b001;   // BOT[0]  : input, no pull
    assign gpio_bot_dm[ 5: 3] = 3'b110;   // BOT[1]  : uart_tx  strong output
    assign gpio_bot_dm[ 8: 6] = 3'b110;   // BOT[2]  : locked   strong output
    assign gpio_bot_dm[11: 9] = 3'b110;   // BOT[3]  : npu_done
    assign gpio_bot_dm[14:12] = 3'b110;   // BOT[4]  : done_processing

    for (genvar i = 5; i < 15; i++) begin : gen_bot_dm_unused
        assign gpio_bot_dm[i*3 +: 3] = 3'b001;   // unused: input, no pull
    end

    // =========================================================================
    // 4. Right GPIOs — all unused, safe high-Z inputs
    // =========================================================================
    assign gpio_rt_out = '0;
    assign gpio_rt_oeb = '1;
    for (genvar i = 0; i < 9; i++) begin : gen_rt_dm
        assign gpio_rt_dm[i*3 +: 3] = 3'b001;
    end

    // =========================================================================
    // 5. Top GPIOs — all unused, safe high-Z inputs
    // =========================================================================
    assign gpio_top_out = '0;
    assign gpio_top_oeb = '1;
    for (genvar i = 0; i < 14; i++) begin : gen_top_dm
        assign gpio_top_dm[i*3 +: 3] = 3'b001;
    end

endmodule : npu_project_macro

`default_nettype wire