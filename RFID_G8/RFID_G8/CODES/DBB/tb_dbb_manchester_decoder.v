// =============================================================================
// tb_dbb_manchester_decoder.v  -  self-checking testbench for
// dbb_manchester_decoder
//
// Half-bit samples arrive on (bit_out, bit_out_valid). The decoder pairs them:
//     "10" -> bit_value=1, bit_valid=1, unit_done=1
//     "01" -> bit_value=0, bit_valid=1, unit_done=1
//     "11"/"00" -> bit_valid=0, unit_done=1   (invalid pair, used for EOF)
// Outputs are registered: they appear the cycle AFTER the 2nd half is applied
// and drop back the cycle after that. align_load (with bit_out_valid) forces the
// current sample to become half1 of a fresh pair.
//
// Checks
//   1. All four pairs, exact output values and 1-cycle pulse widths
//   2. Idle cycles (valid=0) clear bit_valid/unit_done and do not disturb phase
//   3. align_load re-alignment mid-pair, and align_load ignored w/o valid
//   4. Asynchronous reset in the middle of a pair
//   5. 500 random pairs with random idle gaps between halves
// =============================================================================
`timescale 1ns/1ps
module tb_dbb_manchester_decoder;

    reg  clk = 0, rst_n = 0;
    reg  bit_out = 0, bit_out_valid = 0, align_load = 0;
    wire bit_value, bit_valid, unit_done;

    dbb_manchester_decoder dut (
        .clk(clk), .rst_n(rst_n),
        .bit_out(bit_out), .bit_out_valid(bit_out_valid), .align_load(align_load),
        .bit_value(bit_value), .bit_valid(bit_valid), .unit_done(unit_done));

    always #10 clk = ~clk;

    integer errors = 0;
    integer i, g;
    reg h1, h2;

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %0s", $time, msg);
            end
        end
    endtask

    // Apply one cycle of input, then check outputs one clock later.
    //   e_bv/e_ud : expected bit_valid / unit_done
    //   e_val     : expected bit_value (only checked if e_bv)
    task step(input b, input v, input al, input e_val, input e_bv, input e_ud);
        begin
            @(negedge clk);
            bit_out = b; bit_out_valid = v; align_load = al;
            @(posedge clk); #1;
            check(bit_valid === e_bv, "bit_valid mismatch");
            check(unit_done === e_ud, "unit_done mismatch");
            if (e_bv) check(bit_value === e_val, "bit_value mismatch");
            if (bit_valid !== e_bv || unit_done !== e_ud || (e_bv && bit_value !== e_val))
                $display("        in: b=%b v=%b al=%b | exp val=%b bv=%b ud=%b | got val=%b bv=%b ud=%b",
                         b, v, al, e_val, e_bv, e_ud, bit_value, bit_valid, unit_done);
        end
    endtask

    task idle(input integer n);
        integer q;
        begin
            for (q = 0; q < n; q = q + 1) step(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        end
    endtask

    initial begin
        if ($test$plusargs("dump")) begin $dumpfile("tb_dbb_manchester_decoder.vcd"); $dumpvars(0, tb_dbb_manchester_decoder); end

        repeat (3) @(negedge clk);
        check(bit_valid === 0 && unit_done === 0 && bit_value === 0, "reset values");
        rst_n = 1;

        // ---- 1. the four pairs -------------------------------------------
        step(1, 1, 0,  0, 0, 0);        // half1 = 1, no output yet
        step(0, 1, 0,  1, 1, 1);        // "10" -> 1
        step(0, 1, 0,  0, 0, 0);        // half1 = 0
        step(1, 1, 0,  0, 1, 1);        // "01" -> 0
        step(1, 1, 0,  0, 0, 0);
        step(1, 1, 0,  0, 0, 1);        // "11" -> unit_done, no bit
        step(0, 1, 0,  0, 0, 0);
        step(0, 1, 0,  0, 0, 1);        // "00" -> unit_done, no bit

        // ---- 2. idle clears the pulses and keeps phase --------------------
        step(1, 1, 0,  0, 0, 0);        // half1 = 1  (phase = 1)
        idle(4);                        // no valid -> nothing changes
        step(0, 1, 0,  1, 1, 1);        // still "10" -> 1
        idle(2);
        check(unit_done === 0 && bit_valid === 0, "pulses must clear when idle");

        // ---- 3. align_load ------------------------------------------------
        // Without align: 1,1 -> "11".   With align on the 2nd 1: it becomes
        // the new half1, so a following 0 completes "10".
        step(1, 1, 0,  0, 0, 0);
        step(1, 1, 1,  0, 0, 0);        // align_load: reload half1 = 1, no unit_done
        step(0, 1, 0,  1, 1, 1);        // "10" -> 1
        // align_load without valid must be ignored
        step(0, 0, 1,  0, 0, 0);
        step(1, 1, 0,  0, 0, 0);        // half1 = 1
        step(0, 1, 0,  1, 1, 1);        // "10"
        // align_load while phase = 0 behaves like a normal first half
        step(0, 1, 1,  0, 0, 0);        // half1 = 0 (via align)
        step(1, 1, 0,  0, 1, 1);        // "01" -> 0

        // ---- 4. async reset mid-pair --------------------------------------
        step(1, 1, 0,  0, 0, 0);        // half1 = 1
        #3 rst_n = 0;
        #1 check(bit_valid === 0 && unit_done === 0, "async reset outputs");
        #20 rst_n = 1;
        bit_out_valid = 0;
        // phase must have been cleared: next two samples form a fresh pair
        step(0, 1, 0,  0, 0, 0);        // half1 = 0
        step(1, 1, 0,  0, 1, 1);        // "01" -> 0   (if phase had survived this would be "10")

        // ---- 5. random pairs with random gaps ----------------------------
        for (i = 0; i < 500; i = i + 1) begin
            h1 = $urandom; h2 = $urandom;
            g = $urandom_range(0, 3);  idle(g);
            step(h1, 1, 0,  1'b0, 1'b0, 1'b0);
            g = $urandom_range(0, 3);  idle(g);
            step(h2, 1, 0,  h1, (h1 != h2), 1'b1);
        end

        idle(2);
        if (errors == 0) $display("TB_DBB_MANCHESTER_DECODER: PASS");
        else             $display("TB_DBB_MANCHESTER_DECODER: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
