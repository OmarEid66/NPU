// SPDX-License-Identifier: Apache-2.0
// openframe_project_wrapper — Top-level Caravel OpenFrame Multi-Project Chip
//
// Parameterized COLS x ROWS grid of user projects with:
//   - 2D orange MUX tree network (bottom/right/top chains)
//   - 3 purple aggregators at chip edges (right, top, left)
//   - Green macro column chains for clock/reset distribution
//   - Row-major serpentine scan chain with magic-word security
//
// All scan macros have dual-sided scan ports (in+out on both short sides).
// The wrapper selects scan direction by connecting the appropriate side's
// in/out and tying the unused side's inputs to 0.
//
// Pad assignment:
//   [14:0]  = Right pads  (15) via Right Purple  <- bottom orange row chains
//   [23:15] = Top pads    (9)  via Top Purple    <- right orange column chains
//   [37:24] = Left pads   (14) via Left Purple   <- top orange row chains
//   37      = POR input
//   38      = sys_clk input
//   39      = sys_reset_n input
//   40      = scan_clk input
//   41      = scan_din input
//   42      = scan_latch input
//   43      = scan_dout output

`default_nettype none

`ifndef OPENFRAME_IO_PADS
    `define OPENFRAME_IO_PADS 44
`endif

module openframe_project_wrapper #(
    parameter COLS = 3,
    parameter ROWS = 4,
    parameter [7:0] MAGIC_WORD = 8'hA5
)(
`ifdef USE_POWER_PINS
    inout vdda,
    inout vdda1,
    inout vdda2,
    inout vssa,
    inout vssa1,
    inout vssa2,
    inout vccd,
    inout vccd1,
    inout vccd2,
    inout vssd,
    inout vssd1,
    inout vssd2,
    inout vddio,
    inout vssio,
`endif

    input  porb_h,
    input  porb_l,
    input  por_l,
    input  resetb_h,
    input  resetb_l,
    input  [31:0] mask_rev,

    input  [`OPENFRAME_IO_PADS-1:0] gpio_in,
    input  [`OPENFRAME_IO_PADS-1:0] gpio_in_h,
    output [`OPENFRAME_IO_PADS-1:0] gpio_out,
    output [`OPENFRAME_IO_PADS-1:0] gpio_oeb,
    output [`OPENFRAME_IO_PADS-1:0] gpio_inp_dis,

    output [`OPENFRAME_IO_PADS-1:0] gpio_ib_mode_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_vtrip_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_slow_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_holdover,
    output [`OPENFRAME_IO_PADS-1:0] gpio_analog_en,
    output [`OPENFRAME_IO_PADS-1:0] gpio_analog_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_analog_pol,
    output [`OPENFRAME_IO_PADS-1:0] gpio_dm2,
    output [`OPENFRAME_IO_PADS-1:0] gpio_dm1,
    output [`OPENFRAME_IO_PADS-1:0] gpio_dm0,

    inout  [`OPENFRAME_IO_PADS-1:0] analog_io,
    inout  [`OPENFRAME_IO_PADS-1:0] analog_noesd_io,

    input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_one,
    input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_zero
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam PADS = 15;  // Orange/Purple always 15-wide

    // Scan chain: 4 nodes per project cell (green + 3 oranges) + 3 purples
    localparam NUM_PROJECTS     = COLS * ROWS;
    localparam NODES_PER_PROJ   = 4;
    localparam TOTAL_PROJ_NODES = NUM_PROJECTS * NODES_PER_PROJ;
    localparam TOTAL_SCAN_NODES = TOTAL_PROJ_NODES + 3;

    // =========================================================================
    // 1. Pad Configuration Tie-offs
    // =========================================================================
    assign gpio_analog_en   = gpio_loopback_zero;
    assign gpio_analog_pol  = gpio_loopback_zero;
    assign gpio_analog_sel  = gpio_loopback_zero;
    assign gpio_holdover    = gpio_loopback_zero;
    assign gpio_ib_mode_sel = gpio_loopback_zero;
    assign gpio_vtrip_sel   = gpio_loopback_zero;
    assign gpio_slow_sel    = gpio_loopback_zero;
    assign gpio_inp_dis     = gpio_loopback_zero;

    // =========================================================================
    // 2. System Signals
    // =========================================================================
    wire por_n       = porb_l;
    wire sys_clk     = gpio_in[38];
    wire sys_reset_n = gpio_in[39];

    // =========================================================================
    // 3. Scan Controller
    // =========================================================================
    wire chain_scan_clk, chain_scan_din, chain_scan_latch, chain_scan_dout;
    wire scan_dout_wire;

    scan_controller_macro #(.MAGIC_WORD(MAGIC_WORD)) u_scan_ctrl (
        .por_n           (por_n),
        .sys_reset_n     (sys_reset_n),
        .pad_scan_clk    (gpio_in[40]),
        .pad_scan_din    (gpio_in[41]),
        .pad_scan_latch  (gpio_in[42]),
        .pad_scan_dout   (scan_dout_wire),
        .chain_scan_clk  (chain_scan_clk),
        .chain_scan_din  (chain_scan_din),
        .chain_scan_latch(chain_scan_latch),
        .chain_scan_dout (chain_scan_dout)
    );

    // =========================================================================
    // 4. Scan Chain Wiring
    // =========================================================================
    // Order: Purples first (Left -> Top -> Right), then grid top-down serpentine.
    // This routes naturally: scan ctrl (bottom) -> left edge -> top edge ->
    // right edge -> grid top-right -> serpentine down -> bottom row -> scan ctrl.
    wire [TOTAL_SCAN_NODES:0] sc_clk, sc_lat, sc_dat;

    assign sc_clk[0] = chain_scan_clk;
    assign sc_lat[0] = chain_scan_latch;
    assign sc_dat[0] = chain_scan_din;
    assign chain_scan_dout = sc_dat[TOTAL_SCAN_NODES];

    // =========================================================================
    // 5. Green Column Chains (clock/reset, bottom to top per column)
    // =========================================================================
    wire [ROWS:0] gclk [0:COLS-1];
    wire [ROWS:0] grst [0:COLS-1];

    genvar c, r;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : gen_clk_col_init
            assign gclk[c][0] = sys_clk;
            assign grst[c][0] = sys_reset_n;
        end
    endgenerate

    // =========================================================================
    // 6. Orange Chain Arrays
    // =========================================================================
    // Bottom oranges: per-row L->R (ROWS chains x COLS+1 nodes)
    wire [PADS-1:0]   bot_out [0:ROWS-1][0:COLS];
    wire [PADS-1:0]   bot_oeb [0:ROWS-1][0:COLS];
    wire [PADS*3-1:0] bot_dm  [0:ROWS-1][0:COLS];
    wire [PADS-1:0]   bot_in  [0:ROWS-1][0:COLS];

    // Right oranges: per-column B->T (COLS chains x ROWS+1 nodes)
    wire [PADS-1:0]   rt_out [0:COLS-1][0:ROWS];
    wire [PADS-1:0]   rt_oeb [0:COLS-1][0:ROWS];
    wire [PADS*3-1:0] rt_dm  [0:COLS-1][0:ROWS];
    wire [PADS-1:0]   rt_in  [0:COLS-1][0:ROWS];

    // Top oranges: per-row R->L (ROWS chains x COLS+1 nodes)
    wire [PADS-1:0]   top_out [0:ROWS-1][0:COLS];
    wire [PADS-1:0]   top_oeb [0:ROWS-1][0:COLS];
    wire [PADS*3-1:0] top_dm  [0:ROWS-1][0:COLS];
    wire [PADS-1:0]   top_in  [0:ROWS-1][0:COLS];

    // Chain start tie-offs (node [0] of each chain)
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row_tieoff
            assign bot_out[r][0] = {PADS{1'b0}};
            assign bot_oeb[r][0] = {PADS{1'b1}};
            assign bot_dm[r][0]  = {(PADS*3){1'b0}};
            assign top_out[r][0] = {PADS{1'b0}};
            assign top_oeb[r][0] = {PADS{1'b1}};
            assign top_dm[r][0]  = {(PADS*3){1'b0}};
        end
        for (c = 0; c < COLS; c = c + 1) begin : gen_col_tieoff
            assign rt_out[c][0] = {PADS{1'b0}};
            assign rt_oeb[c][0] = {PADS{1'b1}};
            assign rt_dm[c][0]  = {(PADS*3){1'b0}};
        end
    endgenerate

    // =========================================================================
    // 7. Project Cell Grid
    // =========================================================================
    // Scan chain traverses top-down serpentine (enters grid from Purple Right
    // at top-right corner):
    //   Row ROWS-1 (top):    R->L
    //   Row ROWS-2:          L->R
    //   ...alternating...
    //   Row 0 (bottom):      L->R or R->L depending on ROWS parity
    //
    // Within each cell, scan visits: green -> bot_orange -> rt_orange -> top_orange
    // That is 4 scan nodes per cell.
    //
    // Grid scan indices start at 3 (after 3 purple nodes).
    //
    // Dual-sided scan: each macro has scan_in+scan_out on both short sides.
    // We connect scan_in to one side and read scan_out from the other.
    // The unused side's scan inputs are tied to 0 at the macro level (OR gate).
    // Since the wrapper doesn't drive those inputs, they default to 0 via the
    // generate block's wire declarations (undriven wires = 0 in simulation).

    localparam SC_GRID_BASE = 3; // After Purple Left(0), Top(1), Right(2)

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row
            for (c = 0; c < COLS; c = c + 1) begin : gen_col

                // Row offset from top (row ROWS-1 is traversed first)
                localparam integer ROW_FROM_TOP = ROWS - 1 - r;
                // Serpentine mapping: first row (from top) goes R->L
                localparam integer SERP_C = (ROW_FROM_TOP % 2 == 0)
                                            ? (COLS - 1 - c) : c;
                // Linear project index in scan traversal order
                localparam integer PROJ_IDX = ROW_FROM_TOP * COLS + SERP_C;
                // Scan chain base index for this cell's 4 nodes
                localparam integer SC_BASE = SC_GRID_BASE + PROJ_IDX * NODES_PER_PROJ;

                // Project wires
                wire        proj_clk, proj_rst_n, proj_por_n;
                wire [14:0] proj_bot_in, proj_bot_out, proj_bot_oeb;
                wire [44:0] proj_bot_dm;
                wire [14:0] proj_rt_in_full;
                wire [8:0]  proj_rt_out, proj_rt_oeb;
                wire [26:0] proj_rt_dm;
                wire [14:0] proj_top_in_full;
                wire [13:0] proj_top_out, proj_top_oeb;
                wire [41:0] proj_top_dm;

                // Padded wires for right orange (9 -> 15)
                wire [PADS-1:0]   rt_local_out;
                wire [PADS-1:0]   rt_local_oeb;
                wire [PADS*3-1:0] rt_local_dm;
                assign rt_local_out = {{(PADS-9){1'b0}},  proj_rt_out};
                assign rt_local_oeb = {{(PADS-9){1'b1}},  proj_rt_oeb};
                assign rt_local_dm  = {{((PADS-9)*3){1'b0}}, proj_rt_dm};

                // Padded wires for top orange (14 -> 15)
                wire [PADS-1:0]   top_local_out;
                wire [PADS-1:0]   top_local_oeb;
                wire [PADS*3-1:0] top_local_dm;
                assign top_local_out = {{(PADS-14){1'b0}},  proj_top_out};
                assign top_local_oeb = {{(PADS-14){1'b1}},  proj_top_oeb};
                assign top_local_dm  = {{((PADS-14)*3){1'b0}}, proj_top_dm};

                // =============================================================
                // Green Macro (scan node 0 of this cell)
                // Scan direction: #S -> #N (south to north)
                // =============================================================
                green_macro u_green (
                    .sys_clk_in      (gclk[c][r]),
                    .sys_reset_n_in  (grst[c][r]),
                    .sys_clk_out     (gclk[c][r+1]),
                    .sys_reset_n_out (grst[c][r+1]),
                    .proj_clk_out    (proj_clk),
                    .proj_reset_n_out(proj_rst_n),
                    .proj_por_n_out  (proj_por_n),
                    .por_n           (por_n),
                    // Scan in from south side
                    .scan_clk_s      (sc_clk[SC_BASE]),
                    .scan_latch_s    (sc_lat[SC_BASE]),
                    .scan_in_s       (sc_dat[SC_BASE]),
                    .scan_clk_out_s  (),  // unused output direction
                    .scan_latch_out_s(),
                    .scan_out_s      (),
                    // Scan out from north side
                    .scan_clk_n      (1'b0),  // unused input direction
                    .scan_latch_n    (1'b0),
                    .scan_in_n       (1'b0),
                    .scan_clk_out_n  (sc_clk[SC_BASE+1]),
                    .scan_latch_out_n(sc_lat[SC_BASE+1]),
                    .scan_out_n      (sc_dat[SC_BASE+1])
                );

                // =============================================================
                // Bottom Orange (scan node 1, L->R row chain)
                // Scan direction: #W -> #E (west to east)
                // =============================================================
                orange_macro #(.PADS(PADS)) u_bot_orange (
                    .por_n               (por_n),
                    // Scan in from west side
                    .scan_clk_w          (sc_clk[SC_BASE+1]),
                    .scan_latch_w        (sc_lat[SC_BASE+1]),
                    .scan_in_w           (sc_dat[SC_BASE+1]),
                    .scan_clk_out_w      (),
                    .scan_latch_out_w    (),
                    .scan_out_w          (),
                    // Scan out from east side
                    .scan_clk_e          (1'b0),
                    .scan_latch_e        (1'b0),
                    .scan_in_e           (1'b0),
                    .scan_clk_out_e      (sc_clk[SC_BASE+2]),
                    .scan_latch_out_e    (sc_lat[SC_BASE+2]),
                    .scan_out_e          (sc_dat[SC_BASE+2]),
                    // GPIO
                    .pad_side_gpio_in    (bot_in[r][c+1]),
                    .pad_side_gpio_out   (bot_out[r][c+1]),
                    .pad_side_gpio_oeb   (bot_oeb[r][c+1]),
                    .pad_side_gpio_dm    (bot_dm[r][c+1]),
                    .chain_side_gpio_in  (),
                    .chain_side_gpio_out (bot_out[r][c]),
                    .chain_side_gpio_oeb (bot_oeb[r][c]),
                    .chain_side_gpio_dm  (bot_dm[r][c]),
                    .local_proj_gpio_in  (proj_bot_in),
                    .local_proj_gpio_out (proj_bot_out),
                    .local_proj_gpio_oeb (proj_bot_oeb),
                    .local_proj_gpio_dm  (proj_bot_dm)
                );

                // =============================================================
                // Right Orange (scan node 2, B->T column chain)
                // Scan direction: #W -> #E (using W=bottom, E=top for vertical)
                // =============================================================
                orange_macro #(.PADS(PADS)) u_rt_orange (
                    .por_n               (por_n),
                    // Scan in from west/south side
                    .scan_clk_w          (sc_clk[SC_BASE+2]),
                    .scan_latch_w        (sc_lat[SC_BASE+2]),
                    .scan_in_w           (sc_dat[SC_BASE+2]),
                    .scan_clk_out_w      (),
                    .scan_latch_out_w    (),
                    .scan_out_w          (),
                    // Scan out from east/north side
                    .scan_clk_e          (1'b0),
                    .scan_latch_e        (1'b0),
                    .scan_in_e           (1'b0),
                    .scan_clk_out_e      (sc_clk[SC_BASE+3]),
                    .scan_latch_out_e    (sc_lat[SC_BASE+3]),
                    .scan_out_e          (sc_dat[SC_BASE+3]),
                    // GPIO
                    .pad_side_gpio_in    (rt_in[c][r+1]),
                    .pad_side_gpio_out   (rt_out[c][r+1]),
                    .pad_side_gpio_oeb   (rt_oeb[c][r+1]),
                    .pad_side_gpio_dm    (rt_dm[c][r+1]),
                    .chain_side_gpio_in  (),
                    .chain_side_gpio_out (rt_out[c][r]),
                    .chain_side_gpio_oeb (rt_oeb[c][r]),
                    .chain_side_gpio_dm  (rt_dm[c][r]),
                    .local_proj_gpio_in  (proj_rt_in_full),
                    .local_proj_gpio_out (rt_local_out),
                    .local_proj_gpio_oeb (rt_local_oeb),
                    .local_proj_gpio_dm  (rt_local_dm)
                );

                // =============================================================
                // Top Orange (scan node 3, R->L row chain)
                // Scan direction: #E -> #W (east to west, reverse)
                // =============================================================
                localparam integer TOP_CP = COLS - 1 - c;

                orange_macro #(.PADS(PADS)) u_top_orange (
                    .por_n               (por_n),
                    // Scan in from east side (R->L: predecessor on right)
                    .scan_clk_w          (1'b0),
                    .scan_latch_w        (1'b0),
                    .scan_in_w           (1'b0),
                    .scan_clk_out_w      (sc_clk[SC_BASE+4]),
                    .scan_latch_out_w    (sc_lat[SC_BASE+4]),
                    .scan_out_w          (sc_dat[SC_BASE+4]),
                    // Scan out from west side
                    .scan_clk_e          (sc_clk[SC_BASE+3]),
                    .scan_latch_e        (sc_lat[SC_BASE+3]),
                    .scan_in_e           (sc_dat[SC_BASE+3]),
                    .scan_clk_out_e      (),
                    .scan_latch_out_e    (),
                    .scan_out_e          (),
                    // GPIO
                    .pad_side_gpio_in    (top_in[r][TOP_CP+1]),
                    .pad_side_gpio_out   (top_out[r][TOP_CP+1]),
                    .pad_side_gpio_oeb   (top_oeb[r][TOP_CP+1]),
                    .pad_side_gpio_dm    (top_dm[r][TOP_CP+1]),
                    .chain_side_gpio_in  (),
                    .chain_side_gpio_out (top_out[r][TOP_CP]),
                    .chain_side_gpio_oeb (top_oeb[r][TOP_CP]),
                    .chain_side_gpio_dm  (top_dm[r][TOP_CP]),
                    .local_proj_gpio_in  (proj_top_in_full),
                    .local_proj_gpio_out (top_local_out),
                    .local_proj_gpio_oeb (top_local_oeb),
                    .local_proj_gpio_dm  (top_local_dm)
                );

                // =============================================================
                // Project Macro
                // =============================================================
                 
`define PROJ_PORTS \
                `ifdef USE_POWER_PINS \
                    .vccd1       (vccd1),        \
                    .vssd1       (vssd1),        \
                `endif \
                    .clk         (proj_clk),          \
                    .reset_n     (proj_rst_n),         \
                    .por_n       (proj_por_n),         \
                    .gpio_bot_in (proj_bot_in),        \
                    .gpio_bot_out(proj_bot_out),       \
                    .gpio_bot_oeb(proj_bot_oeb),       \
                    .gpio_bot_dm (proj_bot_dm),        \
                    .gpio_rt_in  (proj_rt_in_full[8:0]),\
                    .gpio_rt_out (proj_rt_out),        \
                    .gpio_rt_oeb (proj_rt_oeb),        \
                    .gpio_rt_dm  (proj_rt_dm),         \
                    .gpio_top_in (proj_top_in_full[13:0]),\
                    .gpio_top_out(proj_top_out),       \
                    .gpio_top_oeb(proj_top_oeb),       \
                    .gpio_top_dm (proj_top_dm)
                    
                                     
            begin : gen_proj
            case ({2'(r), 2'(c)}) 
                    {2'd0, 2'd0}: project_macro_0_0 u_proj (`PROJ_PORTS);
                    {2'd0, 2'd1}: project_macro_0_1 u_proj (`PROJ_PORTS);
                    {2'd0, 2'd2}: project_macro_0_2 u_proj (`PROJ_PORTS);
                    
                    {2'd1, 2'd0}: project_macro_1_0 u_proj (`PROJ_PORTS);
                    {2'd1, 2'd1}: project_macro_1_1 u_proj (`PROJ_PORTS);
                    {2'd1, 2'd2}: project_macro_1_2 u_proj (`PROJ_PORTS);
                    
                    {2'd2, 2'd0}: project_macro_2_0 u_proj (`PROJ_PORTS);
                    {2'd2, 2'd1}: project_macro_2_1 u_proj (`PROJ_PORTS);
                    {2'd2, 2'd2}: project_macro_2_2 u_proj (`PROJ_PORTS);
                    
                    {2'd3, 2'd0}: project_macro_3_0 u_proj (`PROJ_PORTS);
                    {2'd3, 2'd1}: project_macro_3_1 u_proj (`PROJ_PORTS);
                    {2'd3, 2'd2}: project_macro_3_2 u_proj (`PROJ_PORTS); 
        default: ;
    endcase
end
            end // gen_col
        end // gen_row
    endgenerate

    // =========================================================================
    // 8. Purple Macros (at chip edges)
    // =========================================================================
    // Purples are FIRST in the scan chain (positions 0, 1, 2):
    //   sc[0] -> Purple Left -> sc[1] -> Purple Top -> sc[2] -> Purple Right -> sc[3]
    // Then the grid starts at sc[3].

    // -----------------------------------------------------------------
    // Right Purple: PORTS=ROWS, 15 GPIOs -> Caravel gpio[14:0]
    // Receives bottom orange chain endpoints (bot_*[r][COLS])
    // Scan direction: side_a -> side_b
    // -----------------------------------------------------------------
    wire [ROWS*PADS-1:0]     rp_tree_in;
    wire [ROWS*PADS-1:0]     rp_tree_out;
    wire [ROWS*PADS-1:0]     rp_tree_oeb;
    wire [ROWS*PADS*3-1:0]   rp_tree_dm;
    wire [PADS-1:0]          rp_pad_out, rp_pad_oeb;
    wire [PADS*3-1:0]        rp_pad_dm;

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_rp
            assign rp_tree_out[r*PADS +: PADS]         = bot_out[r][COLS];
            assign rp_tree_oeb[r*PADS +: PADS]         = bot_oeb[r][COLS];
            assign rp_tree_dm [r*(PADS*3) +: (PADS*3)] = bot_dm [r][COLS];
            assign bot_in[r][COLS] = rp_tree_in[r*PADS +: PADS];
        end
    endgenerate

    purple_macro #(.PADS(PADS), .PORTS(ROWS)) u_purple_right (
        .por_n          (por_n),
        .scan_clk_a     (sc_clk[2]),
        .scan_latch_a   (sc_lat[2]),
        .scan_in_a      (sc_dat[2]),
        .scan_clk_out_a (),
        .scan_latch_out_a(),
        .scan_out_a     (),
        .scan_clk_b     (1'b0),
        .scan_latch_b   (1'b0),
        .scan_in_b      (1'b0),
        .scan_clk_out_b (sc_clk[3]),
        .scan_latch_out_b(sc_lat[3]),
        .scan_out_b     (sc_dat[3]),
        .pad_gpio_in    (gpio_in[14:0]),
        .pad_gpio_out   (rp_pad_out),
        .pad_gpio_oeb   (rp_pad_oeb),
        .pad_gpio_dm    (rp_pad_dm),
        .tree_gpio_in   (rp_tree_in),
        .tree_gpio_out  (rp_tree_out),
        .tree_gpio_oeb  (rp_tree_oeb),
        .tree_gpio_dm   (rp_tree_dm)
    );

    // -----------------------------------------------------------------
    // Top Purple: PORTS=COLS, 9 of 15 GPIOs -> Caravel gpio[23:15]
    // Receives right orange chain endpoints (rt_*[c][ROWS])
    // -----------------------------------------------------------------
    wire [COLS*PADS-1:0]     tp_tree_in;
    wire [COLS*PADS-1:0]     tp_tree_out;
    wire [COLS*PADS-1:0]     tp_tree_oeb;
    wire [COLS*PADS*3-1:0]   tp_tree_dm;
    wire [PADS-1:0]          tp_pad_out, tp_pad_oeb;
    wire [PADS*3-1:0]        tp_pad_dm;

    generate
        for (c = 0; c < COLS; c = c + 1) begin : gen_tp
            assign tp_tree_out[c*PADS +: PADS]         = rt_out[c][ROWS];
            assign tp_tree_oeb[c*PADS +: PADS]         = rt_oeb[c][ROWS];
            assign tp_tree_dm [c*(PADS*3) +: (PADS*3)] = rt_dm [c][ROWS];
            assign rt_in[c][ROWS] = tp_tree_in[c*PADS +: PADS];
        end
    endgenerate

    purple_macro #(.PADS(PADS), .PORTS(COLS)) u_purple_top (
        .por_n          (por_n),
        .scan_clk_a     (sc_clk[1]),
        .scan_latch_a   (sc_lat[1]),
        .scan_in_a      (sc_dat[1]),
        .scan_clk_out_a (),
        .scan_latch_out_a(),
        .scan_out_a     (),
        .scan_clk_b     (1'b0),
        .scan_latch_b   (1'b0),
        .scan_in_b      (1'b0),
        .scan_clk_out_b (sc_clk[2]),
        .scan_latch_out_b(sc_lat[2]),
        .scan_out_b     (sc_dat[2]),
        .pad_gpio_in    ({6'b0, gpio_in[23:15]}),
        .pad_gpio_out   (tp_pad_out),
        .pad_gpio_oeb   (tp_pad_oeb),
        .pad_gpio_dm    (tp_pad_dm),
        .tree_gpio_in   (tp_tree_in),
        .tree_gpio_out  (tp_tree_out),
        .tree_gpio_oeb  (tp_tree_oeb),
        .tree_gpio_dm   (tp_tree_dm)
    );

    // -----------------------------------------------------------------
    // Left Purple: PORTS=ROWS, 14 of 15 GPIOs -> Caravel gpio[37:24]
    // Receives top orange chain endpoints (top_*[r][COLS])
    // -----------------------------------------------------------------
    wire [ROWS*PADS-1:0]     lp_tree_in;
    wire [ROWS*PADS-1:0]     lp_tree_out;
    wire [ROWS*PADS-1:0]     lp_tree_oeb;
    wire [ROWS*PADS*3-1:0]   lp_tree_dm;
    wire [PADS-1:0]          lp_pad_out, lp_pad_oeb;
    wire [PADS*3-1:0]        lp_pad_dm;

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_lp
            assign lp_tree_out[r*PADS +: PADS]         = top_out[r][COLS];
            assign lp_tree_oeb[r*PADS +: PADS]         = top_oeb[r][COLS];
            assign lp_tree_dm [r*(PADS*3) +: (PADS*3)] = top_dm [r][COLS];
            assign top_in[r][COLS] = lp_tree_in[r*PADS +: PADS];
        end
    endgenerate

    purple_macro #(.PADS(PADS), .PORTS(ROWS)) u_purple_left (
        .por_n          (por_n),
        .scan_clk_a     (sc_clk[0]),
        .scan_latch_a   (sc_lat[0]),
        .scan_in_a      (sc_dat[0]),
        .scan_clk_out_a (),
        .scan_latch_out_a(),
        .scan_out_a     (),
        .scan_clk_b     (1'b0),
        .scan_latch_b   (1'b0),
        .scan_in_b      (1'b0),
        .scan_clk_out_b (sc_clk[1]),
        .scan_latch_out_b(sc_lat[1]),
        .scan_out_b     (sc_dat[1]),
        .pad_gpio_in    ({1'b0, gpio_in[37:24]}),
        .pad_gpio_out   (lp_pad_out),
        .pad_gpio_oeb   (lp_pad_oeb),
        .pad_gpio_dm    (lp_pad_dm),
        .tree_gpio_in   (lp_tree_in),
        .tree_gpio_out  (lp_tree_out),
        .tree_gpio_oeb  (lp_tree_oeb),
        .tree_gpio_dm   (lp_tree_dm)
    );

    // =========================================================================
    // 9. GPIO Output Assignments
    // =========================================================================
    // The OpenFrame interface splits dm into 3 separate bit-per-pad buses:
    //   gpio_dm2[i] = dm[(i*3)+2], gpio_dm1[i] = dm[(i*3)+1], gpio_dm0[i] = dm[(i*3)]

    // --- Right pads [14:0]: all 15 from Right Purple ---
    assign gpio_out[14:0] = rp_pad_out;
    assign gpio_oeb[14:0] = rp_pad_oeb;

    genvar p;
    generate
        for (p = 0; p < 15; p = p + 1) begin : gen_rp_dm
            assign gpio_dm0[p] = rp_pad_dm[p*3];
            assign gpio_dm1[p] = rp_pad_dm[p*3+1];
            assign gpio_dm2[p] = rp_pad_dm[p*3+2];
        end
    endgenerate

    // --- Top pads [23:15]: lower 9 of 15 from Top Purple ---
    assign gpio_out[23:15] = tp_pad_out[8:0];
    assign gpio_oeb[23:15] = tp_pad_oeb[8:0];

    generate
        for (p = 0; p < 9; p = p + 1) begin : gen_tp_dm
            assign gpio_dm0[15+p] = tp_pad_dm[p*3];
            assign gpio_dm1[15+p] = tp_pad_dm[p*3+1];
            assign gpio_dm2[15+p] = tp_pad_dm[p*3+2];
        end
    endgenerate

    // --- Left pads [37:24]: lower 14 of 15 from Left Purple ---
    assign gpio_out[37:24] = lp_pad_out[13:0];
    assign gpio_oeb[37:24] = lp_pad_oeb[13:0];

    generate
        for (p = 0; p < 14; p = p + 1) begin : gen_lp_dm
            assign gpio_dm0[24+p] = lp_pad_dm[p*3];
            assign gpio_dm1[24+p] = lp_pad_dm[p*3+1];
            assign gpio_dm2[24+p] = lp_pad_dm[p*3+2];
        end
    endgenerate

    // --- System pads [42:38]: inputs only ---
    assign gpio_out[42:38] = 5'b0;
    assign gpio_oeb[42:38] = 5'b11111;
    // Drive mode 3'b010 = input mode
    assign gpio_dm0[42:38] = 5'b0;
    assign gpio_dm1[42:38] = 5'b11111;
    assign gpio_dm2[42:38] = 5'b0;

    // --- Scan dout pad [43]: output ---
    assign gpio_out[43] = scan_dout_wire;
    assign gpio_oeb[43] = 1'b0;
    // Drive mode 3'b110 = strong output
    assign gpio_dm0[43] = 1'b0;
    assign gpio_dm1[43] = 1'b1;
    assign gpio_dm2[43] = 1'b1;

    // =========================================================================
    // 10. Power Connections
    // =========================================================================
    (* keep *) vccd1_connection vccd1_connection ();
    (* keep *) vssd1_connection vssd1_connection ();

endmodule
