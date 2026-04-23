
module CU #(
    parameter INST_DATA_W = 32,
    parameter INST_ADDR_W = 5,
    parameter SA_SIZE     = 8
)(
input logic clk,
input logic rst_n,
input logic start,

input logic [INST_DATA_W-1:0] inst_data,
output logic inst_rd_en,
output logic [INST_ADDR_W-1:0] PC,

// SRAM Port 0 (RW — CU reads for LOAD_ACT / LOAD_ACT_WGT)
output logic                        sram_en0,
output logic [7:0]                  sram_a0,
input  logic [31:0]                 sram_do0,

// SRAM Port 1 (Read-only — CU reads for LOAD_WGT / LOAD_ACT_WGT)
output logic                        sram_en1,
output logic [7:0]                  sram_a1,
input  logic [31:0]                 sram_do1,

// ACT Ping-Pong Buffer — write port
output logic                        act_wr_en,
output logic [3:0]                  act_wr_byte_addr,
output logic [31:0]                 act_wr_data,
output logic                        act_swap,
input  logic                        act_fill_done,

// WGT Ping-Pong Buffer — write port
output logic                        wgt_wr_en,
output logic [3:0]                  wgt_wr_byte_addr,
output logic [31:0]                 wgt_wr_data,
output logic                        wgt_swap,
input  logic                        wgt_fill_done,

// PP Buffer read rows (to SA)
output logic [$clog2(SA_SIZE)-1:0]  act_rd_row,
output logic [$clog2(SA_SIZE)-1:0]  wgt_rd_row,

// SA
input  logic sa_valid_out ,
input  logic sa_busy ,
input  logic sa_done,
output logic sa_start ,
output logic sa_valid_in ,
output logic sa_transpose_en ,

output logic npu_done

);

localparam LOAD_ACT = 6'b000000 ;
localparam LOAD_WGT = 6'b000001 ;
localparam LOAD_BIAS = 6'b000010 ;
localparam LOAD_SCL = 6'b000011 ;
localparam CONV = 6'b000100 ;
localparam ADD_BIAS = 6'b000101 ;
localparam RELU = 6'b000111 ;
localparam POOL = 6'b001000 ;
localparam STORE = 6'b001001 ;
localparam LOAD_ACT_WGT = 6'b010000 ;
localparam NOP = 6'b111110 ;
localparam HALT = 6'b111111 ;

localparam CV_CNT_W = $clog2(SA_SIZE) + 1;
localparam N_ROW_PP   = $clog2(SA_SIZE);


logic [INST_DATA_W-1:0] instr_r;

// LOAD/STORE Instructions
logic [5:0] opcode ;
logic [3:0] buf_sel ;
logic [7:0] ext_Addr ;
logic [7:0] tile_addr_b;
logic [7:0] tile_addr_a;

// Computation Instructions
logic w_transpose;
logic [4:0] n_scale ;
logic  bypass_bias ;

// ── Counter ──────────────────────────────────────────────────
logic [CV_CNT_W-1:0] conv_cnt;
logic              conv_cnt_en;
logic              conv_cnt_rst;

logic unit_done;


// ── FSM States ────────────────────────────────────
typedef enum logic [2:0] {
    IDLE    = 3'd0,
    FETCH   = 3'd1,
    DECODE  = 3'd2,
    EXECUTE = 3'd3,
    NEXT    = 3'd4,
    HALTED  = 3'd5
} state_t;

// Sub-phase for CONV execution
typedef enum logic [2:0] {
    CP_IDLE   = 3'd0,  // 1-cycle
    CP_START  = 3'd1,   // 1-cycle: pulse sa_start
    CP_LOAD_W = 3'd2,   // N cycles: feed weights row-by-row
    CP_FEED_A = 3'd3,   // N cycles: feed activations row-by-row
    CP_WAIT   = 3'd4    // wait for sa_done (DRAIN+OUTPUT run autonomously in SA)
} conv_phase_t;

state_t state, next_state;
conv_phase_t conv_phase, next_conv_phase;


// Fetch Instr and Main FSM

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        instr_r <= '0;
    else if (state == FETCH)
        instr_r <= inst_data;
end


// ── DECODE: combinational ─────────────────────────
always_comb begin
    opcode      = instr_r[31:26];

    // LOAD/STORE Instructions
    buf_sel     = instr_r[25:22];
    ext_Addr    = instr_r[21:16];
    tile_addr_b = instr_r[15:8];
    tile_addr_a = instr_r[7:0];

    // Computation Instructions
    w_transpose = instr_r[6];
    n_scale     = instr_r[5:1];
    bypass_bias = instr_r[0];
end

always_comb begin
    unit_done = 1'b0;

    case (opcode)

        LOAD_ACT: begin
            unit_done = act_fill_done;
        end

        LOAD_WGT: begin
            unit_done = wgt_fill_done;
        end

        LOAD_BIAS: begin
        end

        LOAD_SCL: begin
        end

        CONV: begin
            unit_done = sa_done ;
        end

        ADD_BIAS: begin
        end

        RELU: begin
        end

        POOL: begin
        end

        STORE: begin
        end

        LOAD_ACT_WGT: begin
        end

        NOP: begin
            unit_done = 1'b1;
        end

        HALT: begin
            unit_done = 1'b1;
        end

        default: begin
            unit_done = 1'b0;
        end

    endcase
end

always_comb begin
    next_state = state;

    case (state)

        IDLE: begin
            if (start)
                next_state = FETCH;
        end

        FETCH: begin
            next_state = DECODE;
        end

        DECODE: begin
            next_state = EXECUTE;
        end

        EXECUTE: begin
            if (opcode == HALT)
                next_state = HALTED;
            else if (unit_done)
                next_state = NEXT;
        end

        NEXT: begin
            next_state = FETCH;
        end

        HALTED: begin
            next_state = HALTED;
        end

        default: next_state = IDLE;

    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        PC <= 5'd0;
    else if (state == NEXT)
        PC <= PC + 1;
end

assign npu_done = (state == HALTED);
assign inst_rd_en = (state == FETCH);


// ================================================================
//  LOAD Engine
//
//  ld_cnt   : 4-bit, counts 0..15  (16 SRAM words = 64 bytes)
//  ld_base_r: tile_addr_a captured at DECODE
//  ld_active: HIGH while EXECUTE and opcode is a LOAD
//
//  Port assignment:
//    LOAD_ACT     → Port 0 only  (en0/a0/do0) → act PP
//    LOAD_WGT     → Port 1 only  (en1/a1/do1) → wgt PP
//    LOAD_ACT_WGT → Port 0 + Port 1 in parallel
//                   do0 → act PP
//                   do1 → wgt PP
//
//  1-cycle pipeline:
//    wr_pend_r = delayed "was a read issued this cycle"
//    wr_addr_r = delayed ld_cnt (= PP wr_byte_addr)
// ================================================================
// ── Opcode group helpers ──────────────────────────────────────
//  is_load_act : this instruction writes the ACT ping-pong buffer
//  is_load_wgt : this instruction writes the WGT ping-pong buffer
//  is_load_any : any of the above
logic is_load_act, is_load_wgt, is_load_any;
 
assign is_load_act = (opcode == LOAD_ACT) || (opcode == LOAD_ACT_WGT);
assign is_load_wgt = (opcode == LOAD_WGT) || (opcode == LOAD_ACT_WGT);
assign is_load_a_w = (opcode == LOAD_ACT_WGT);
assign is_load_any = (opcode == LOAD_ACT) || (opcode == LOAD_WGT) ||
                     (opcode == LOAD_ACT_WGT);

logic [3:0] ld_cnt;
logic [7:0] ld_base_r_a;
logic [7:0] ld_base_r_b;
logic       ld_active;
 
assign ld_active = (state == EXECUTE) && is_load_any;

// Capture tile base address at DECODE
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ld_base_r_a <= '0;
        ld_base_r_b <= '0;
    else if (state == DECODE && is_load_any)
        ld_base_r_a <= tile_addr_a;
        ld_base_r_b <= tile_addr_b;
end

// ld_cnt: free-running 0..15 while ld_active, resets otherwise
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ld_cnt <= '0;
    else if (!ld_active)
        ld_cnt <= '0;
    else if (ld_cnt <= 4'd15)
        ld_cnt <= ld_cnt + 1'b1;
end

// 1-cycle pipeline registers for write-back
logic       wr_pend_r;
logic [3:0] wr_addr_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_pend_r <= 1'b0;
        wr_addr_r <= '0;
    end else begin
        wr_pend_r <= ld_active && (ld_cnt <= 4'd15);
        wr_addr_r <= ld_cnt;
    end
end

// ================================================================
//  SRAM Port 0 — LOAD_ACT and LOAD_ACT_WGT
// ================================================================
always_comb begin
    sram_en0 = 1'b0;
    sram_a0  = '0;
    if (ld_active && is_load_act && (ld_cnt <= 4'd15)) begin
        sram_en0 = 1'b1;
        sram_a0  = ld_base_r_a + {4'b0, ld_cnt};
    end
end
 
// ================================================================
//  SRAM Port 1 — LOAD_WGT and LOAD_ACT_WGT
// ================================================================
always_comb begin
    sram_en1 = 1'b0;
    sram_a1  = '0;
    if (ld_active && is_load_wgt && (ld_cnt <= 4'd15)) begin
        sram_en1 = 1'b1;
        if (!is_load_a_w) begin
            sram_a1  = ld_base_r_a + {4'b0, ld_cnt};
        end else begin
            sram_a1  = ld_base_r_b + {4'b0, ld_cnt};
        end
    end
end

/ ================================================================
//  ACT Ping-Pong write  ← data comes from sram_do0 (Port 0)
// ================================================================
always_comb begin
    act_wr_en        = 1'b0;
    act_wr_byte_addr = '0;
    act_wr_data      = '0;
    act_swap         = 1'b0;
 
    if (wr_pend_r && is_load_act) begin
        act_wr_en        = 1'b1;
        act_wr_byte_addr = wr_addr_r;
        act_wr_data      = sram_do0;   // ← Port 0
    end
 
    // Swap so SA immediately gets the new tile
    if (state == NEXT && is_load_act)
        act_swap = 1'b1;
end
 
// ================================================================
//  WGT Ping-Pong write  ← data comes from sram_do1 (Port 1)
// ================================================================
always_comb begin
    wgt_wr_en        = 1'b0;
    wgt_wr_byte_addr = '0;
    wgt_wr_data      = '0;
    wgt_swap         = 1'b0;
 
    if (wr_pend_r && is_load_wgt) begin
        wgt_wr_en        = 1'b1;
        wgt_wr_byte_addr = wr_addr_r;
        wgt_wr_data      = sram_do1;   // ← Port 1
    end
 
    if (state == NEXT && is_load_wgt)
        wgt_swap = 1'b1;
end
 



// CONV Engine
// ── Counter register ─────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       conv_cnt <= '0;
    else if (conv_cnt_rst) conv_cnt <= '0;
    else if (conv_cnt_en)  conv_cnt <= conv_cnt + 1'b1;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        conv_phase <= CP_IDLE;
    else
        conv_phase <= next_conv_phase;
end

always_comb begin
    next_conv_phase = conv_phase;
    conv_cnt_rst    = 1'b0;
    conv_cnt_en     = 1'b0;

    case(conv_phase)
        CP_IDLE: begin
            if (opcode == CONV && state == EXECUTE) begin
                next_conv_phase = CP_START ;
            end
        end

        CP_START: begin
            next_conv_phase = CP_LOAD_W ;
        end

        CP_LOAD_W: begin
            conv_cnt_en = 1'b1;
            if (conv_cnt == N_SIZE - 1) begin
                conv_cnt_rst    = 1'b1;
                conv_cnt_en     = 1'b0;
                next_conv_phase = CP_FEED_A;
            end
        end

        CP_FEED_A: begin
            conv_cnt_en = 1'b1;
            if (conv_cnt == N_SIZE - 1) begin
                conv_cnt_rst    = 1'b1;
                conv_cnt_en     = 1'b0;
                next_conv_phase = CP_WAIT;
            end
        end

        CP_WAIT: begin
            if (sa_done) begin
                next_conv_phase = CP_IDLE ;
            end
            
        end

    endcase
end

assign sa_transpose_en = w_transpose  ;
assign sa_start = (conv_phase==CP_START) ;
assign sa_valid_in = (conv_phase == CP_LOAD_W) || (conv_phase == CP_FEED_A) ;

// conv_cnt selects row — phases are mutually exclusive so one signal is fine
assign wgt_rd_row = conv_cnt[N_ROW_PP-1:0];  // valid during CP_LOAD_W
assign act_rd_row = conv_cnt[N_ROW_PP-1:0];  // valid during CP_FEED_A

endmodule