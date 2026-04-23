
module CU #()(

);

// ── FSM States ────────────────────────────────────
typedef enum logic [2:0] {
    IDLE    = 3'd0,
    FETCH   = 3'd1,
    DECODE  = 3'd2,
    EXECUTE = 3'd3,
    NEXT    = 3'd4,
    HALTED  = 3'd5
} state_t;

endmodule