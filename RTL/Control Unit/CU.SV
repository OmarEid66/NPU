// ================================================================
//  CU — Control Unit (Complete)
//
//  Main FSM: IDLE→FETCH→STALL→DECODE→EXECUTE→NEXT→HALTED
//
//  Key design pattern:
//    exec_pulse : 1-cycle HIGH on first cycle of EXECUTE
//                 Used to trigger all single-shot units cleanly.
//
//  Opcode map (from ISA):
//    000000 LOAD_ACT     000001 LOAD_WGT     000010 LOAD_BIAS
//    000011 LOAD_SCL     000100 CONV         000101 ADD_BIAS
//    000110 REQ          000111 RELU         001001 STORE
//    010000 LOAD_ACT_WGT 111110 NOP          111111 HALT
//
// ================================================================

module CU #(
    parameter INST_DATA_W = 32,
    parameter INST_ADDR_W = 5,
    parameter SA_SIZE     = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,

    // ── Host memory load controls ─────────────────────────────
    input  logic load_imem,
    input  logic load_dmem,
    input  logic dmem_rd_host,

    // ── IMEM / SRAM mux controls ──────────────────────────────
    output logic        imem_rd_wr,
    output logic        select_apb_npu,
    output logic [1:0]  select_apb_npu_addr,

    // ── Instruction memory ────────────────────────────────────
    input  logic [INST_DATA_W-1:0] inst_data,
    output logic                   inst_rd_en,
    output logic [INST_ADDR_W-1:0] PC,



    // ── SRAM Port 0 ───────────────────────────────────────────
    output logic        sram_en0,
    output logic [7:0]  sram_a0,
    input  logic [31:0] sram_do0,

    // ── SRAM Port 1 ───────────────────────────────────────────
    output logic        sram_en1,
    output logic [7:0]  sram_a1,
    input  logic [31:0] sram_do1,

    // ── ACT Ping-Pong ─────────────────────────────────────────
    output logic        act_wr_en,
    output logic [3:0]  act_wr_byte_addr,
    output logic [31:0] act_wr_data,
    output logic        act_swap,
    input  logic        act_fill_done,

    // ── WGT Ping-Pong ─────────────────────────────────────────
    output logic        wgt_wr_en,
    output logic [3:0]  wgt_wr_byte_addr,
    output logic [31:0] wgt_wr_data,
    output logic        wgt_swap,
    input  logic        wgt_fill_done,

    // ── PP row selects ────────────────────────────────────────
    output logic [$clog2(SA_SIZE)-1:0] act_rd_row,
    output logic [$clog2(SA_SIZE)-1:0] wgt_rd_row,

    // ── Scale register ────────────────────────────────────────
    output logic scale_wr_en,

    // ── SA ────────────────────────────────────────────────────
    input  logic sa_valid_out,
    input  logic sa_busy,
    input  logic sa_done,
    output logic sa_start,
    output logic sa_valid_in,
    output logic sa_transpose_en,

    // ── acc_buffer ────────────────────────────────────────────
    output logic                        bacc_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]  bacc_addr,

    // ── bias_adder ────────────────────────────────────────────
    output logic ba_start,
    input  logic ba_done,

    // ── bias_buffer ───────────────────────────────────────────
    output logic                        bb_wr_en,
    output logic [$clog2(SA_SIZE)-1:0]  bb_wr_addr,

    // ── req_unit ──────────────────────────────────────────────
    output logic       req_start,
    input  logic       req_done,
    output logic [4:0] n_scale,

    // ── relu_unit ─────────────────────────────────────────────
    output logic relu_start,
    input  logic relu_done,

    output logic addr_st_rel,

    // ── store_engine ──────────────────────────────────────────
    output logic       st_start,
    input  logic       st_done,
    output logic       st_buf_sel,
    output logic [7:0] st_tile_addr, 

    // ── Status ────────────────────────────────────────────────
    output logic done_processing,
    output logic npu_done
);

// ── Opcode localparams ────────────────────────────────────────
localparam LOAD_ACT     = 6'b000000;
localparam LOAD_WGT     = 6'b000001;
localparam LOAD_BIAS    = 6'b000010;
localparam LOAD_SCL     = 6'b000011;
localparam CONV         = 6'b000100;
localparam ADD_BIAS     = 6'b000101;
localparam REQ_OP       = 6'b000110;
localparam RELU_OP      = 6'b000111;
localparam POOL         = 6'b001000;
localparam STORE_OP     = 6'b001001;
localparam LOAD_ACT_WGT = 6'b010000;
localparam NOP          = 6'b111110;
localparam HALT         = 6'b111111;

localparam CV_CNT_W = $clog2(SA_SIZE) + 1;
localparam N_ROW_PP = $clog2(SA_SIZE);

// ── Main FSM ──────────────────────────────────────────────────
typedef enum logic [2:0] {
    IDLE    = 3'd0,
    FETCH   = 3'd1,
    STALL   = 3'd2,
    DECODE  = 3'd3,
    EXECUTE = 3'd4,
    NEXT    = 3'd5,
    HALTED  = 3'd6
} state_t;

// ── CONV sub-phase ────────────────────────────────────────────
typedef enum logic [2:0] {
    CP_IDLE   = 3'd0,
    CP_START  = 3'd1,
    CP_LOAD_W = 3'd2,
    CP_FEED_A = 3'd3,
    CP_WAIT   = 3'd4
} conv_phase_t;

// ── RELU sub-phase ────────────────────────────────────────────
typedef enum logic [1:0] {
    RP_IDLE  = 2'd0,
    RP_PULSE = 2'd1,
    RP_WAIT  = 2'd2
} relu_phase_t;

// ── Instruction register & decode ────────────────────────────
logic [INST_DATA_W-1:0] instr_r;

// LOAD/STORE Instructions
logic [5:0] opcode;
logic [3:0] buf_sel;
logic [7:0] ext_Addr ;
logic [7:0] tile_addr_b, tile_addr_a;

// Computation Instructions
logic       w_transpose;
logic [4:0] n_scale_dec;
logic       bypass_bias;

logic [4:0] ld_cnt;
logic [7:0] ld_base_r_a, ld_base_r_b;
logic       ld_active;
logic is_load_act, is_load_wgt, is_load_a_w, is_load_bias, is_load_scl, is_load_any;

logic       wr_pend_r;
logic [4:0] wr_addr_r;
logic [7:0] st_tile_addr_r;
logic       st_buf_sel_r;
logic [$clog2(SA_SIZE)-1:0] acc_wr_cnt;

logic [CV_CNT_W-1:0] conv_cnt;
logic conv_cnt_en, conv_cnt_rst;

logic exec_pulse;
logic [$clog2(SA_SIZE)-1:0] relu_cnt;
logic unit_done;
logic st_active;

state_t state, next_state;
conv_phase_t conv_phase, next_conv_phase;
relu_phase_t relu_phase, next_relu_phase;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              instr_r <= '0;
    else if (state == STALL) instr_r <= inst_data;
end

always_comb begin
    opcode      = instr_r[31:26];
    buf_sel     = instr_r[25:22];
    ext_Addr    = instr_r[21:16];
    tile_addr_b = instr_r[15:8];
    tile_addr_a = instr_r[7:0];
    w_transpose = instr_r[6];
    n_scale_dec = instr_r[5:1];
    bypass_bias = instr_r[0];
end

assign n_scale = n_scale_dec;


// ── exec_pulse: 1-cycle HIGH on FIRST cycle of EXECUTE ────────
// Registered: state==DECODE is sampled at posedge → output is HIGH
// exactly when state transitions to EXECUTE the following cycle.
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) exec_pulse <= 1'b0;
    else        exec_pulse <= (state == DECODE);
end


always_comb begin
    unit_done = 1'b0;
    case (opcode)
        LOAD_ACT:     unit_done = act_fill_done;
        LOAD_WGT:     unit_done = wgt_fill_done;
        LOAD_ACT_WGT: unit_done = act_fill_done && wgt_fill_done;
        LOAD_BIAS:    unit_done = (ld_cnt >= 5'd8);
        LOAD_SCL:     unit_done = (ld_cnt >= 5'd1);
        CONV:         unit_done = sa_done;
        ADD_BIAS:     unit_done = ba_done;
        REQ_OP:       unit_done = req_done;
        RELU_OP:      unit_done = relu_done;
        STORE_OP:     unit_done = st_done;
        NOP:          unit_done = 1'b1;
        HALT:         unit_done = 1'b1;
        default:      unit_done = 1'b0;
    endcase
end

// ── Main FSM ──────────────────────────────────────────────────
always_comb begin
    next_state = state;
    case (state)
        IDLE:    if (start)     next_state = FETCH;
        FETCH:                  next_state = STALL;
        STALL:                  next_state = DECODE;
        DECODE:                 next_state = EXECUTE;
        EXECUTE: begin
            if (opcode == HALT) next_state = HALTED;
            else if (unit_done) next_state = NEXT;
        end
        NEXT:                   next_state = FETCH;
        HALTED:                 next_state = HALTED;
        default:                next_state = IDLE;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
end

// ── PC ────────────────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             PC <= '0;
    else if (state == NEXT) PC <= PC + 1'b1;
end

// ── Static outputs ────────────────────────────────────────────
assign inst_rd_en     = (state == FETCH);
assign npu_done       = (state == HALTED);

// Assert done_processing when the PC reaches the end of IMEM (31) 
// AND the final instruction has finished executing (state moves to NEXT).
// This acts as an interrupt to the Host CPU to load the next 32 instructions.
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        done_processing <= 1'b0;
    else if (state == NEXT && PC == 5'd31) // 5'd31 is the max address of a 32-word IMEM
        done_processing <= 1'b1;
    else if (start || load_imem) // Clear the flag when the host starts a new run or loads new instructions
        done_processing <= 1'b0;
end

// ── IMEM / SRAM mux controls ──────────────────────────────────
assign imem_rd_wr      = ~load_imem;    // 0=host writes, 1=CU reads
assign select_apb_npu  = load_dmem;     // 1=host drives sram_di0

always_comb begin
    if (load_dmem)
        select_apb_npu_addr = 2'b11;    // host write addr
    else if (dmem_rd_host)
        select_apb_npu_addr = 2'b01;    // host read addr
    else if (st_active)
        select_apb_npu_addr = 2'b00;    // store engine addr
    else
        select_apb_npu_addr = 2'b10;    // CU addr
end

// ================================================================
//  LOAD Engine
// ================================================================

assign is_load_act  = (opcode == LOAD_ACT)  || (opcode == LOAD_ACT_WGT);
assign is_load_wgt  = (opcode == LOAD_WGT)  || (opcode == LOAD_ACT_WGT);
assign is_load_a_w  = (opcode == LOAD_ACT_WGT);
assign is_load_bias = (opcode == LOAD_BIAS);
assign is_load_scl  = (opcode == LOAD_SCL);
assign is_load_any  = is_load_act || (opcode == LOAD_WGT) ||
                      is_load_bias || is_load_scl;

assign ld_active = (state == EXECUTE) && is_load_any;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ld_base_r_a <= '0;
        ld_base_r_b <= '0;
    end else if (state == DECODE && is_load_any) begin
        ld_base_r_a <= tile_addr_a;
        ld_base_r_b <= tile_addr_b;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ld_cnt <= '0;
    else if (!ld_active)
        ld_cnt <= '0;
    else if (ld_cnt < 5'd16)
        ld_cnt <= ld_cnt + 1'b1;
end


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_pend_r <= 1'b0;
        wr_addr_r <= '0;
    end else begin
        wr_pend_r <= ld_active && (ld_cnt < 5'd16);
        wr_addr_r <= ld_cnt;
    end
end

// ── SRAM Port 0 (ACT reads) ───────────────────────────────────
always_comb begin
    sram_en0 = 1'b0;
    sram_a0  = '0;
    if (ld_active && is_load_act && (ld_cnt < 5'd16)) begin
        sram_en0 = 1'b1;
        sram_a0  = ld_base_r_a + {3'b0, ld_cnt};
    end
end

// ── SRAM Port 1 (WGT / BIAS / SCL reads) ─────────────────────
always_comb begin
    sram_en1 = 1'b0;
    sram_a1  = '0;
    if (ld_active && (ld_cnt < 5'd16)) begin
        if (is_load_wgt) begin
            sram_en1 = 1'b1;
            sram_a1  = is_load_a_w ? ld_base_r_b + {3'b0, ld_cnt}
                                   : ld_base_r_a + {3'b0, ld_cnt};
        end else if (is_load_bias && (ld_cnt < 5'd8)) begin
            sram_en1 = 1'b1;
            sram_a1  = ld_base_r_a + {3'b0, ld_cnt};
        end else if (is_load_scl && (ld_cnt == 5'd0)) begin
            sram_en1 = 1'b1;
            sram_a1  = ld_base_r_a;
        end
    end
end

// ── ACT PP write ──────────────────────────────────────────────
always_comb begin
    act_wr_en        = 1'b0;
    act_wr_byte_addr = '0;
    act_wr_data      = '0;
    act_swap         = 1'b0;
    if (wr_pend_r && is_load_act) begin
        act_wr_en        = 1'b1;
        act_wr_byte_addr = wr_addr_r[3:0];
        act_wr_data      = sram_do0;
    end
    if (state == NEXT && is_load_act)
        act_swap = 1'b1;
end

// ── WGT PP write ──────────────────────────────────────────────
always_comb begin
    wgt_wr_en        = 1'b0;
    wgt_wr_byte_addr = '0;
    wgt_wr_data      = '0;
    wgt_swap         = 1'b0;
    if (wr_pend_r && is_load_wgt) begin
        wgt_wr_en        = 1'b1;
        wgt_wr_byte_addr = wr_addr_r[3:0];
        wgt_wr_data      = sram_do1;
    end
    if (state == NEXT && is_load_wgt)
        wgt_swap = 1'b1;
end

// ── bias_buffer write (LOAD_BIAS) ─────────────────────────────
always_comb begin
    bb_wr_en   = 1'b0;
    bb_wr_addr = '0;
    if (wr_pend_r && is_load_bias && (wr_addr_r < 5'd8)) begin
        bb_wr_en   = 1'b1;
        bb_wr_addr = wr_addr_r[$clog2(SA_SIZE)-1:0];
    end
end

// ── scale_reg write (LOAD_SCL) ────────────────────────────────
assign scale_wr_en = wr_pend_r && is_load_scl && (wr_addr_r == 5'd0);

// ================================================================
//  CONV Engine
// ================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            conv_cnt <= '0;
    else if (conv_cnt_rst) conv_cnt <= '0;
    else if (conv_cnt_en)  conv_cnt <= conv_cnt + 1'b1;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) conv_phase <= CP_IDLE;
    else        conv_phase <= next_conv_phase;
end

always_comb begin
    next_conv_phase = conv_phase;
    conv_cnt_rst    = 1'b0;
    conv_cnt_en     = 1'b0;
    case (conv_phase)
        CP_IDLE: begin
            if (opcode == CONV && state == EXECUTE)
                next_conv_phase = CP_START;
        end
        CP_START: next_conv_phase = CP_LOAD_W;
        CP_LOAD_W: begin
            conv_cnt_en = 1'b1;
            if (conv_cnt == CV_CNT_W'(SA_SIZE - 1)) begin
                conv_cnt_rst    = 1'b1;
                conv_cnt_en     = 1'b0;
                next_conv_phase = CP_FEED_A;
            end
        end
        CP_FEED_A: begin
            conv_cnt_en = 1'b1;
            if (conv_cnt == CV_CNT_W'(SA_SIZE - 1)) begin
                conv_cnt_rst    = 1'b1;
                conv_cnt_en     = 1'b0;
                next_conv_phase = CP_WAIT;
            end
        end
        CP_WAIT: begin
            if (sa_done) next_conv_phase = CP_IDLE;
        end
        default: next_conv_phase = CP_IDLE;
    endcase
end

assign sa_transpose_en = w_transpose;
assign sa_start        = (conv_phase == CP_START);
assign sa_valid_in     = (conv_phase == CP_LOAD_W) || (conv_phase == CP_FEED_A);
assign wgt_rd_row      = conv_cnt[N_ROW_PP-1:0];
assign act_rd_row      = conv_cnt[N_ROW_PP-1:0];

// ── acc_buffer write (capture SA output row by row) ───────────

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        acc_wr_cnt <= '0;
    else if (sa_valid_out)
        acc_wr_cnt <= acc_wr_cnt + 1'b1;
    else if (!sa_busy)
        acc_wr_cnt <= '0;
end

assign bacc_wr_en = sa_valid_out;
assign bacc_addr  = acc_wr_cnt;

// ================================================================
//  ADD_BIAS — single-pulse start on EXECUTE entry
// ================================================================
assign ba_start = exec_pulse && (opcode == ADD_BIAS);

// ================================================================
//  REQ — SA_SIZE pulses (one per row) then wait for req_done
// ================================================================
typedef enum logic [1:0] {
    RQ_IDLE  = 2'd0,
    RQ_PULSE = 2'd1,
    RQ_WAIT  = 2'd2
} req_phase_t;

req_phase_t req_phase, next_req_phase;
logic [$clog2(SA_SIZE)-1:0] req_cnt;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) req_phase <= RQ_IDLE;
    else        req_phase <= next_req_phase;
end

always_comb begin
    next_req_phase = req_phase;
    case (req_phase)
        RQ_IDLE:  if (opcode == REQ_OP && state == EXECUTE)
                      next_req_phase = RQ_PULSE;
        RQ_PULSE: if (req_cnt == $clog2(SA_SIZE)'(SA_SIZE - 1))
                      next_req_phase = RQ_WAIT;
        RQ_WAIT:  if (req_done)
                      next_req_phase = RQ_IDLE;
        default:  next_req_phase = RQ_IDLE;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        req_cnt <= '0;
    else if (req_phase == RQ_IDLE)
        req_cnt <= '0;
    else if (req_phase == RQ_PULSE)
        req_cnt <= req_cnt + 1'b1;
end

assign req_start = (req_phase == RQ_PULSE);

// ================================================================
//  RELU — SA_SIZE pulses then wait
// ================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) relu_phase <= RP_IDLE;
    else        relu_phase <= next_relu_phase;
end

always_comb begin
    next_relu_phase = relu_phase;
    case (relu_phase)
        RP_IDLE:  if (opcode == RELU_OP && state == EXECUTE)
                      next_relu_phase = RP_PULSE;
        RP_PULSE: if (relu_cnt == $clog2(SA_SIZE)'(SA_SIZE - 1))
                      next_relu_phase = RP_WAIT;
        RP_WAIT:  if (relu_done)
                      next_relu_phase = RP_IDLE;
        default:  next_relu_phase = RP_IDLE;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        relu_cnt <= '0;
    else if (relu_phase == RP_IDLE)
        relu_cnt <= '0;
    else if (relu_phase == RP_PULSE)
        relu_cnt <= relu_cnt + 1'b1;
end

assign relu_start = (relu_phase == RP_PULSE);

// ================================================================
//  STORE — capture fields at DECODE, pulse start at EXECUTE
// ================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st_tile_addr_r <= '0;
        st_buf_sel_r   <= 1'b0;
    end else if (state == DECODE && (opcode == STORE_OP)) begin
        st_tile_addr_r <= tile_addr_a;
        st_buf_sel_r   <= buf_sel[0];
    end
end

// ── st_active: HIGH from st_start until st_done ───────────────
// Needed so sram_en0/we0 route store_engine for the full EXECUTE
// duration, not just during DECODE (which was wrong).

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        st_active <= 1'b0;
    else if (st_start) st_active <= 1'b1;
    else if (st_done)  st_active <= 1'b0;
end

assign addr_st_rel = (opcode == STORE_OP);
assign st_tile_addr = st_tile_addr_r;
assign st_buf_sel   = st_buf_sel_r;
assign st_start     = exec_pulse && (opcode == STORE_OP);

endmodule