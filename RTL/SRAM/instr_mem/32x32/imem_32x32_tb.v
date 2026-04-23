`timescale 1ns/1ps

module RAM32_tb;

    reg                     CLK;
    reg  [3:0]          WE0;
    reg                     EN0;
    reg  [4:0]         A0;
    reg  [31:0]  Di0;
    wire [31:0]  Do0;

    integer i, errors;
    reg [31:0] expected;
    reg [31:0] mem_shadow [0:31];

    // Clock: 50 MHz (20 ns period)
    initial CLK = 0;
    always #10 CLK = ~CLK;

    // DUT
    RAM32 dut (
        .CLK(CLK),
        .WE0(WE0),
        .EN0(EN0),

        .A0(A0),
        .Di0(Di0),
        .Do0(Do0)
    );

    task write_word(input [4:0] addr, input [31:0] data);
        begin
            @(posedge CLK);
            EN0 = 1;
            WE0 = ~(4'h0);
            A0  = addr;
            Di0 = data;
            @(posedge CLK);
            EN0 = 0;
            WE0 = 0;
        end
    endtask

    task read_word(input [4:0] addr);
        begin
            @(posedge CLK);
            EN0 = 1;
            WE0 = 0;
            A0  = addr;
            @(posedge CLK);
            EN0 = 0;
        end
    endtask

    initial begin
        $dumpfile("RAM32_tb.vcd");
        $dumpvars(0, RAM32_tb);

        errors = 0;
        EN0 = 0; WE0 = 0; A0 = 0; Di0 = 0;


        repeat(5) @(posedge CLK);

        // --- Test 1: Sequential Write/Read ---
        $display("--- Test 1: Sequential Write/Read ---");
        for (i = 0; i < 16; i = i + 1) begin
            mem_shadow[i] = $random;
            write_word(i, mem_shadow[i]);
        end

        for (i = 0; i < 16; i = i + 1) begin
            read_word(i);
            @(posedge CLK);
            expected = mem_shadow[i];
            if (Do0 !== expected) begin
                $display("  FAIL: Addr %0d: expected 0x%08h, got 0x%08h", i, expected, Do0);
                errors = errors + 1;
            end else begin
                $display("  PASS: Addr %0d: 0x%08h", i, Do0);
            end
        end

        // --- Test 2: Byte Write Enable ---
        $display("\n--- Test 2: Byte Write Enable ---");
        write_word(0, 32'h0);
        @(posedge CLK);
        EN0 = 1;
        WE0 = 4'b1;  // only byte 0
        A0  = 0;
        Di0 = ~(32'h0);
        @(posedge CLK);
        EN0 = 0; WE0 = 0;

        read_word(0);
        @(posedge CLK);
        expected = 32'h0000_00FF;
        if (Do0 !== expected) begin
            $display("  FAIL: Byte-write: expected 0x%08h, got 0x%08h", expected, Do0);
            errors = errors + 1;
        end else begin
            $display("  PASS: Byte-write: 0x%08h", Do0);
        end

        // --- Test 3: Overwrite ---
        $display("\n--- Test 3: Overwrite ---");
        write_word(0, 32'hA5);
        read_word(0);
        @(posedge CLK);
        if (Do0 !== 32'hA5) begin
            $display("  FAIL: expected 0x000000A5, got 0x%08h", Do0);
            errors = errors + 1;
        end else begin
            $display("  PASS: 0x%08h", Do0);
        end
        write_word(0, 32'h5A);
        read_word(0);
        @(posedge CLK);
        if (Do0 !== 32'h5A) begin
            $display("  FAIL: expected 0x0000005A, got 0x%08h", Do0);
            errors = errors + 1;
        end else begin
            $display("  PASS: 0x%08h", Do0);
        end

        // --- Summary ---
        repeat(5) @(posedge CLK);
        $display("\n===================================");
        if (errors == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  FAILED: %0d errors", errors);
        $display("===================================\n");
        $finish;
    end

endmodule
