// SPDX-License-Identifier: Apache-2.0
// project_macro_2_0.v — Reserved slot stub (safe tie-off)
// All pads configured as high-Z inputs. Replace with user logic as needed.
`default_nettype none

module project_macro_2_0 (
`ifdef USE_POWER_PINS
    inout  vccd1,
    inout  vssd1,
`endif
    input  wire        clk,
    input  wire        reset_n,
    input  wire        por_n,

    input  wire [14:0] gpio_bot_in,
    output wire [14:0] gpio_bot_out,
    output wire [14:0] gpio_bot_oeb,
    output wire [44:0] gpio_bot_dm,

    input  wire  [8:0] gpio_rt_in,
    output wire  [8:0] gpio_rt_out,
    output wire  [8:0] gpio_rt_oeb,
    output wire [26:0] gpio_rt_dm,

    input  wire [13:0] gpio_top_in,
    output wire [13:0] gpio_top_out,
    output wire [13:0] gpio_top_oeb,
    output wire [41:0] gpio_top_dm
);
    project_macro u_stub (
`ifdef USE_POWER_PINS
        .vccd1       (vccd1),
        .vssd1       (vssd1),
`endif
        .clk         (clk),
        .reset_n     (reset_n),
        .por_n       (por_n),
        .gpio_bot_in (gpio_bot_in),
        .gpio_bot_out(gpio_bot_out),
        .gpio_bot_oeb(gpio_bot_oeb),
        .gpio_bot_dm (gpio_bot_dm),
        .gpio_rt_in  (gpio_rt_in),
        .gpio_rt_out (gpio_rt_out),
        .gpio_rt_oeb (gpio_rt_oeb),
        .gpio_rt_dm  (gpio_rt_dm),
        .gpio_top_in (gpio_top_in),
        .gpio_top_out(gpio_top_out),
        .gpio_top_oeb(gpio_top_oeb),
        .gpio_top_dm (gpio_top_dm)
    );
endmodule
`default_nettype wire
