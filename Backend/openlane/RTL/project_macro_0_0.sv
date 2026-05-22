// SPDX-License-Identifier: Apache-2.0
// =============================================================================
//  project_macro_0_0.sv
//
//  Grid slot: row=0, col=0  →  NPU System
//
//  Thin shell required because openframe_project_wrapper selects project
//  modules by name (project_macro_R_C) in a generate-case statement.
//  All ports are forwarded verbatim to npu_project_macro.
//
//  Chip pad connections (Bottom orange row-0 → Right Purple → gpio[14:0]):
//    gpio[0]  ← uart_rx   (input  — host UART transmit to NPU)
//    gpio[1]  → uart_tx   (output — NPU transmit to host)
//    gpio[2]  → locked    (output — APB bus lock status)
//    gpio[3]  → npu_done  (output — NPU reached HALT)
//    gpio[4]  → done_processing (output)
//
//  Shared system signals:
//    gpio[38] → sys_clk    → green_macro → clk
//    gpio[39] → sys_reset_n → green_macro → reset_n
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module project_macro_0_0 (
`ifdef USE_POWER_PINS
    inout  logic vccd1,
    inout  logic vssd1,
`endif
    input  logic        clk,
    input  logic        reset_n,
    input  logic        por_n,

    input  logic [14:0] gpio_bot_in,
    output logic [14:0] gpio_bot_out,
    output logic [14:0] gpio_bot_oeb,
    output logic [44:0] gpio_bot_dm,

    input  logic  [8:0] gpio_rt_in,
    output logic  [8:0] gpio_rt_out,
    output logic  [8:0] gpio_rt_oeb,
    output logic [26:0] gpio_rt_dm,

    input  logic [13:0] gpio_top_in,
    output logic [13:0] gpio_top_out,
    output logic [13:0] gpio_top_oeb,
    output logic [41:0] gpio_top_dm
);

    npu_project_macro u_npu_proj (
`ifdef USE_POWER_PINS
        .vccd1        (vccd1),
        .vssd1        (vssd1),
`endif
        .clk          (clk),
        .reset_n      (reset_n),
        .por_n        (por_n),

        .gpio_bot_in  (gpio_bot_in),
        .gpio_bot_out (gpio_bot_out),
        .gpio_bot_oeb (gpio_bot_oeb),
        .gpio_bot_dm  (gpio_bot_dm),

        .gpio_rt_in   (gpio_rt_in),
        .gpio_rt_out  (gpio_rt_out),
        .gpio_rt_oeb  (gpio_rt_oeb),
        .gpio_rt_dm   (gpio_rt_dm),

        .gpio_top_in  (gpio_top_in),
        .gpio_top_out (gpio_top_out),
        .gpio_top_oeb (gpio_top_oeb),
        .gpio_top_dm  (gpio_top_dm)
    );

endmodule : project_macro_0_0

`default_nettype wire
