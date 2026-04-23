
module CU #(parameter INST_DATA_W = 32, INST_ADDR_W = 5)(
input logic clk,
input logic rst_n,
input logic start,

input logic [INST_DATA_W-1:0] inst_data,
output logic inst_rd_en,
output logic [INST_ADDR_W-1:0] PC,

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

localparam CNT_W = $clog2(N_SIZE) + 1;


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
logic [CNT_W-1:0] cnt;
logic              cnt_en;
logic              cnt_rst;

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

state_t state, next_state;

// Sub-phase for CONV execution
typedef enum logic [2:0] {
    CP_IDLE   = 3'd0  // 1-cycle
    CP_START  = 3'd1,   // 1-cycle: pulse sa_start
    CP_LOAD_W = 3'd2,   // N cycles: feed weights row-by-row
    CP_FEED_A = 3'd3,   // N cycles: feed activations row-by-row
    CP_WAIT   = 3'd4    // wait for sa_done (DRAIN+OUTPUT run autonomously in SA)
} conv_phase_t;

conv_phase_t conv_phase, next_conv_phase;





assign instr = inst_data;

always_comb begin
    inst_rd_en = 1'b0;

    case (state)

        FETCH: begin
            inst_rd_en = 1'b1;
        end

        default: begin
            inst_rd_en = 1'b0;
        end

    endcase
end

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
        end

        LOAD_WGT: begin
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

// ── Counter register ─────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       cnt <= '0;
    else if (cnt_rst) cnt <= '0;
    else if (cnt_en)  cnt <= cnt + 1'b1;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        conv_phase <= CP_IDLE;
    else
        conv_phase <= next_conv_phase;
end

always_comb begin
    next_conv_phase = conv_phase;
    case(conv_phase)
        CP_IDLE: begin
            if (opcode == CONV && state == EXECUTE) begin
                next_conv_phase = CP_START ;
            end
        end

        CP_START: begin
            next_conv_phase == CP_LOAD_W ;
        end

        CP_LOAD_W: begin
            cnt_en = 1'b1;
            if (cnt == N_SIZE - 1) begin
                cnt_rst    = 1'b1;
                cnt_en     = 1'b0;
                next_conv_phase = CP_FEED_A;
            end
        end

        CP_FEED_A: begin
            cnt_en = 1'b1;
            if (cnt == N_SIZE - 1) begin
                cnt_rst    = 1'b1;
                cnt_en     = 1'b0;
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

assign sa_start = (conv_phase==CP_START) ;
assign sa_valid_in = (conv_phase == CP_LOAD_W) || (conv_phase == CP_FEED_A) ;


assign npu_done = (state == HALTED);

endmodule