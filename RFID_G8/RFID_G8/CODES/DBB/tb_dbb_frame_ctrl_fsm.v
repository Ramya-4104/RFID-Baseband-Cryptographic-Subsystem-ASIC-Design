// =============================================================================
// tb_dbb_frame_ctrl_fsm.v  -  self-checking testbench for dbb_frame_ctrl_fsm
//
// The FSM watches two things:
//   * RAW half-bit samples (bit_out / bit_out_valid) - only in IDLE, to find SOF
//     ("1" then "0"), regardless of whether the line idles at 0 or 1.
//   * DECODED units (dec_unit_done / dec_bit_valid) - while receiving.
//
// The TB reproduces the real timing: the decoder's registered outputs appear
// ONE clock after the raw sample that completes the pair, so for the SOF pair
// the decoded pulse lands while the FSM is in SOF_WAIT and must be ignored.
//
// Parameters:  EOFU (EOF_CONFIRM_UNITS, 2 or 3)   MAXB (MAX_FRAME_BITS)
//
// Scenarios
//   S0  no SOF: idle zeros and stray decoded pulses do nothing
//   S1  idle-0 line, normal frame, raw samples during frame ignored
//   S2  idle-1 line (armed re-latches on every idle '1'), normal frame
//   S3  back-to-back frame; solitary '0' after a frame is not a SOF
//   S4  EOF_CONFIRM interrupted by a valid unit -> back to RECEIVING
//   S5  MAXB-th valid unit aborts; FSM recovers to IDLE and takes a new frame
//   S6  abort taken through the EOF_CONFIRM->RECEIVING branch
//   S7  async reset in the middle of a frame
// Global monitors: frame_done / frame_abort are 1-clock pulses, never together.
// =============================================================================
`timescale 1ns/1ps
module tb_dbb_frame_ctrl_fsm;

    parameter EOFU = 2;
    parameter MAXB = 16;

    reg  clk = 0, rst_n = 0;
    reg  bit_out = 0, bit_out_valid = 0;
    reg  dec_unit_done = 0, dec_bit_valid = 0, dec_bit_value = 0;
    wire align_load, frame_active, frame_done, frame_abort;

    dbb_frame_ctrl_fsm #(.EOF_CONFIRM_UNITS(EOFU), .MAX_FRAME_BITS(MAXB)) dut (
        .clk(clk), .rst_n(rst_n),
        .bit_out(bit_out), .bit_out_valid(bit_out_valid),
        .dec_unit_done(dec_unit_done), .dec_bit_valid(dec_bit_valid), .dec_bit_value(dec_bit_value),
        .align_load(align_load), .frame_active(frame_active),
        .frame_done(frame_done), .frame_abort(frame_abort));

    always #10 clk = ~clk;

    integer errors = 0;
    integer i;

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %0s", $time, msg);
            end
        end
    endtask

    // ---------------- global pulse monitors ---------------------------------
    integer done_cnt = 0, abort_cnt = 0;
    reg     pd = 0, pa = 0;
    always @(negedge clk) begin
        if (frame_done)  done_cnt  = done_cnt  + 1;
        if (frame_abort) abort_cnt = abort_cnt + 1;
        if (frame_done  && pd) check(0, "frame_done wider than 1 clock");
        if (frame_abort && pa) check(0, "frame_abort wider than 1 clock");
        if (frame_done && frame_abort) check(0, "done and abort together");
        pd = frame_done; pa = frame_abort;
    end

    task expect_counts(input integer d, input integer a);
        begin
            check(done_cnt  == d, "frame_done pulse count");
            check(abort_cnt == a, "frame_abort pulse count");
            if (done_cnt != d || abort_cnt != a)
                $display("        done=%0d (exp %0d)  abort=%0d (exp %0d)", done_cnt, d, abort_cnt, a);
        end
    endtask

    // ---------------- stimulus tasks ---------------------------------------
    // one raw half-bit sample; check combinational align_load in the same cycle
    task raw(input b, input exp_al);
        begin
            @(negedge clk);
            bit_out = b; bit_out_valid = 1; #1;
            check(align_load === exp_al, "align_load mismatch");
            @(negedge clk);
            bit_out_valid = 0; bit_out = 0;
        end
    endtask

    // last raw sample of the SOF ("0"), followed one clock later by the
    // decoder's pulse for the SOF pair (which decodes as a valid '1')
    task raw_last_sof;
        begin
            @(negedge clk);
            bit_out = 0; bit_out_valid = 1; #1;
            check(align_load === 1'b0, "align_load must be 0 on the SOF-completing '0'");
            @(negedge clk);                                   // FSM now in SOF_WAIT
            bit_out_valid = 0;
            dec_unit_done = 1; dec_bit_valid = 1; dec_bit_value = 1;
            @(negedge clk);                                   // FSM now in RECEIVING
            dec_unit_done = 0; dec_bit_valid = 0; dec_bit_value = 0;
            check(frame_active === 1'b0, "frame_active must still be low (SOF pulse absorbed)");
        end
    endtask

    task sof_idle0;                     // line idles low: 0 0 1 0
        begin
            raw(0, 0); raw(0, 0); raw(1, 1); raw_last_sof;
        end
    endtask

    task sof_idle1;                     // line idles high: 1 1 1 1 0
        begin
            raw(1, 1); raw(1, 1); raw(1, 1); raw(1, 1); raw_last_sof;
        end
    endtask

    task after_sof;                     // frame_active rises one clock later
        begin
            @(negedge clk);
            check(frame_active === 1'b1, "frame_active must be high once receiving");
        end
    endtask

    // one decoded unit (unit_done pulse), bit_valid = bv
    task unit(input bv, input val, input integer gap);
        begin
            @(negedge clk);
            dec_unit_done = 1; dec_bit_valid = bv; dec_bit_value = val;
            @(negedge clk);
            dec_unit_done = 0; dec_bit_valid = 0; dec_bit_value = 0;
            repeat (gap) @(negedge clk);
        end
    endtask

    task data_units(input integer n);
        integer q;
        begin
            for (q = 0; q < n; q = q + 1) begin
                unit(1'b1, q[0], 2);
                check(frame_active === 1'b1, "frame_active dropped during data");
                check(frame_abort === 1'b0,  "unexpected abort during data");
            end
        end
    endtask

    // EOF: EOFU invalid units. After the last one, frame_active falls at once
    // and frame_done pulses one clock later.
    task eof_units;
        integer q;
        begin
            for (q = 0; q < EOFU - 1; q = q + 1) begin
                unit(1'b0, 1'b0, 2);
                check(frame_active === 1'b1, "frame_active must stay high during EOF_CONFIRM");
                check(frame_done   === 1'b0, "frame_done too early");
            end
            unit(1'b0, 1'b0, 0);
            check(frame_active === 1'b0, "frame_active must fall on confirmed EOF");
            check(frame_done   === 1'b0, "frame_done must trail EOF by one clock");
            @(negedge clk);
            check(frame_done   === 1'b1, "frame_done pulse missing");
            @(negedge clk);
            check(frame_done   === 1'b0, "frame_done must be 1 clock wide");
        end
    endtask

    // ------------------------------------------------------------------------
    initial begin
        if ($test$plusargs("dump")) begin $dumpfile("tb_dbb_frame_ctrl_fsm.vcd"); $dumpvars(0, tb_dbb_frame_ctrl_fsm); end

        repeat (3) @(negedge clk);
        check(frame_active === 0 && frame_done === 0 && frame_abort === 0, "reset values");
        rst_n = 1;
        repeat (2) @(negedge clk);

        // ---- S0: nothing happens without SOF -----------------------------
        $display("S0: no SOF");
        raw(0, 0); raw(0, 0); raw(0, 0);
        unit(1'b1, 1'b1, 2);                       // stray decoded pulses in IDLE
        unit(1'b0, 1'b0, 2);
        repeat (4) @(negedge clk);
        check(frame_active === 1'b0, "S0: frame_active without SOF");
        expect_counts(0, 0);

        // ---- S1: idle-0 frame --------------------------------------------
        $display("S1: idle-0 frame");
        sof_idle0;
        after_sof;
        data_units(3);
        raw(1, 1'b0);                              // raw sample mid-frame: align_load must be 0
        raw(0, 1'b0);
        data_units(2);
        eof_units;
        expect_counts(1, 0);

        // ---- S2: idle-1 frame --------------------------------------------
        $display("S2: idle-1 frame");
        repeat (3) @(negedge clk);
        sof_idle1;
        after_sof;
        data_units(4);
        eof_units;
        expect_counts(2, 0);

        // ---- S3: back-to-back, lone zeros are no SOF ----------------------
        $display("S3: back-to-back");
        raw(0, 0); raw(0, 0);
        repeat (4) @(negedge clk);
        check(frame_active === 1'b0, "S3: lone zeros started a frame");
        sof_idle0;
        after_sof;
        data_units(1);
        eof_units;
        expect_counts(3, 0);

        // ---- S4: EOF interrupted -----------------------------------------
        $display("S4: EOF_CONFIRM interrupted by data");
        sof_idle0;
        after_sof;
        data_units(2);
        for (i = 0; i < EOFU - 1; i = i + 1) begin
            unit(1'b0, 1'b0, 2);
            check(frame_active === 1'b1, "S4: active during partial EOF");
        end
        unit(1'b1, 1'b1, 2);                       // valid unit resumes the frame
        check(frame_active === 1'b1, "S4: frame must resume");
        check(frame_done === 1'b0,   "S4: no done after interrupted EOF");
        data_units(1);
        eof_units;
        expect_counts(4, 0);

        // ---- S5: abort on MAXB-th valid unit ------------------------------
        $display("S5: abort at MAX_FRAME_BITS");
        sof_idle0;
        after_sof;
        for (i = 0; i < MAXB - 1; i = i + 1) begin
            unit(1'b1, i[0], 2);
            check(frame_abort === 1'b0 && frame_active === 1'b1, "S5: aborted too early");
        end
        unit(1'b1, 1'b0, 0);                       // the MAXB-th valid unit
        check(frame_abort  === 1'b1, "S5: frame_abort must pulse on MAXB-th valid unit");
        check(frame_active === 1'b0, "S5: frame_active must drop on abort");
        repeat (3) @(negedge clk);
        expect_counts(4, 1);
        // FSM is back in IDLE and accepts a fresh frame
        sof_idle0;
        after_sof;
        data_units(3);
        eof_units;
        expect_counts(5, 1);

        // ---- S6: abort through EOF_CONFIRM branch -------------------------
        $display("S6: abort via EOF_CONFIRM -> RECEIVING");
        sof_idle0;
        after_sof;
        for (i = 0; i < MAXB - 1; i = i + 1) unit(1'b1, i[0], 2);
        for (i = 0; i < EOFU - 1; i = i + 1) unit(1'b0, 1'b0, 2);   // partial EOF
        check(frame_active === 1'b1, "S6: still active in EOF_CONFIRM");
        unit(1'b1, 1'b1, 0);
        check(frame_abort  === 1'b1, "S6: abort expected");
        check(frame_active === 1'b0, "S6: active must drop");
        repeat (3) @(negedge clk);
        expect_counts(5, 2);

        // ---- S7: async reset in the middle of a frame ---------------------
        $display("S7: async reset mid-frame");
        sof_idle0;
        after_sof;
        data_units(2);
        #3 rst_n = 0;
        #1 check(frame_active === 1'b0 && frame_done === 1'b0 && frame_abort === 1'b0,
                 "S7: async reset outputs");
        #30 rst_n = 1;
        repeat (3) @(negedge clk);
        check(frame_active === 1'b0, "S7: idle after reset");
        sof_idle0;
        after_sof;
        data_units(2);
        eof_units;
        expect_counts(6, 2);

        if (errors == 0) $display("TB_DBB_FRAME_CTRL_FSM: PASS (EOFU=%0d MAXB=%0d)", EOFU, MAXB);
        else             $display("TB_DBB_FRAME_CTRL_FSM: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("TB_DBB_FRAME_CTRL_FSM: FAIL (timeout)");
        $finish;
    end
endmodule
