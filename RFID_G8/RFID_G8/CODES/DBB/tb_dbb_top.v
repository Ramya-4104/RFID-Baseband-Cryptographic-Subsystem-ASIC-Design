// =============================================================================
// tb_dbb_top.v  -  self-checking integration testbench for dbb_top
//
// Plusarg-free parameters (override with iverilog -P tb_dbb_top.<name>=<v>):
//   PH    clocks between an oversampler window boundary and the line's
//         half-bit transitions (default 40). For a noise-free line every
//         value works (a different PH only delays the stream by up to one
//         half-bit); run_all.sh sweeps several values.
//   IDLE  idle level of rfid_rx_bit in Mode 0 (0 or 1)
//
// Scenarios
//   T1  Mode 0, full 8-byte frame, good parity -> exactly one cipher_data_valid
//       pulse, cipher_data_in == payload, frame_parity_error = 0, data_ready = 0
//   T2  Mode 0, 8-byte frame with corrupted parity on one byte
//       -> cipher_data_valid pulse with frame_parity_error = 1
//   T3  Mode 0, short (3-byte) frame -> NO cipher_data_valid; the receiver
//       recovers and the following full frame is intact (auto-ack worked)
//   T4  Mode 1 (DBB loopback), several random 4-byte patterns
//       -> data_ready, frame_data_out0 == {B3,B2,B1,B0}, no parity error,
//          data_read_ack clears data_ready, cipher_data_valid stays 0
//   T5  Mode 0 -> Mode 1 switch in the middle of a live frame: the receive path
//       is flushed, the loopback frame that follows is decoded correctly, and a
//       Mode 0 frame afterwards is also fine
//   T6  Mode 2: nothing is produced (data_ready = 0, no cipher pulse) even
//       while the line toggles
//
// NOTE on alignment: in Mode 0 the oversampler is free-running (no edge
// re-synchronisation), so the testbench first locks to the oversampler window
// boundary (dut.os_shreg_full) and then places every half-bit transition PH
// clocks after a boundary.
// =============================================================================
`timescale 1ns/1ps
module tb_dbb_top;

    parameter PH   = 40;
    parameter IDLE = 0;

    localparam HALF = 236;                       // dbb_top default HALF_BIT_CYCLES

    reg         clk = 0, rst_n = 0;
    reg  [1:0]  mode_sel = 2'd0;
    reg         rfid_rx_bit = IDLE;
    reg  [31:0] lb_data0 = 0, lb_data1 = 0;
    reg         lb_load = 0, data_read_ack = 0;

    wire [31:0] frame_data_out0, frame_data_out1;
    wire        data_ready;
    wire [63:0] cipher_data_in;
    wire        cipher_data_valid, frame_parity_error, rfid_tx_bit;

    dbb_top dut (
        .clk(clk), .rst_n(rst_n), .mode_sel(mode_sel),
        .rfid_rx_bit(rfid_rx_bit),
        .lb_data0(lb_data0), .lb_data1(lb_data1), .lb_load(lb_load),
        .frame_data_out0(frame_data_out0), .frame_data_out1(frame_data_out1),
        .data_ready(data_ready), .data_read_ack(data_read_ack),
        .cipher_data_in(cipher_data_in), .cipher_data_valid(cipher_data_valid),
        .frame_parity_error(frame_parity_error), .rfid_tx_bit(rfid_tx_bit));

    always #10 clk = ~clk;                       // 50 MHz

    integer errors = 0;

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %0s", $time, msg);
            end
        end
    endtask

    // ---------------- monitors ---------------------------------------------
    integer     cdv_cnt = 0;                     // cipher_data_valid pulses
    reg  [63:0] cdv_data = 0;
    reg         cdv_perr = 0;
    reg         cdv_prev = 0;
    integer     dr_high_cycles_mode0 = 0;        // data_ready seen while mode_sel==0/2
    integer     tx_activity = 0;

    always @(posedge clk) begin
        if (cipher_data_valid) begin
            cdv_cnt  <= cdv_cnt + 1;
            cdv_data <= cipher_data_in;
            cdv_perr <= frame_parity_error;
            if (cdv_prev) begin errors = errors + 1; $display("[%0t] FAIL: cipher_data_valid wider than 1 clock", $time); end
        end
        cdv_prev <= cipher_data_valid;
        if (data_ready && mode_sel[0] == 1'b0) dr_high_cycles_mode0 <= dr_high_cycles_mode0 + 1;
        if (rfid_tx_bit) tx_activity <= tx_activity + 1;
    end

    // ---------------- live line generation ------------------------------------
    task live_half(input lvl);
        begin
            rfid_rx_bit = lvl;
            repeat (HALF) @(posedge clk);
            #1;
        end
    endtask

    task live_bit(input v);                      // Manchester: 1 -> "10", 0 -> "01"
        begin live_half(v); live_half(~v); end
    endtask

    // Lock to an oversampler window boundary, then wait PH more clocks.
    task align_live;
        begin
            @(posedge clk);
            while (!dut.os_shreg_full) @(posedge clk);
            repeat (PH) @(posedge clk);
            #1;
        end
    endtask

    // full frame: idle, SOF, nbytes x (8 data LSB first + odd parity), idle (EOF)
    task live_frame(input integer nbytes, input [63:0] by, input [7:0] bad_mask);
        integer b, j;
        reg [7:0] B;
        begin
            repeat (2) live_half(IDLE);
            live_half(1'b1); live_half(1'b0);                       // SOF
            for (b = 0; b < nbytes; b = b + 1) begin
                B = by[8*b +: 8];
                for (j = 0; j < 8; j = j + 1) live_bit(B[j]);
                live_bit(~(^B) ^ bad_mask[b]);                      // odd parity (optionally corrupted)
            end
            repeat (8) live_half(IDLE);                             // EOF / idle
        end
    endtask

    // frame that stops abruptly (no EOF): SOF + nbits data bits
    task live_partial(input integer nbits);
        integer j;
        begin
            repeat (2) live_half(IDLE);
            live_half(1'b1); live_half(1'b0);
            for (j = 0; j < nbits; j = j + 1) live_bit(j[0] ^ j[1]);
            rfid_rx_bit = IDLE;
        end
    endtask

    task set_mode(input [1:0] m);
        begin
            @(negedge clk);
            mode_sel = m;
            repeat (6) @(negedge clk);
        end
    endtask

    // ---------------- loopback helper ----------------------------------------
    function [15:0] enc(input [7:0] b);
        integer j;
        begin
            for (j = 0; j < 8; j = j + 1) begin
                enc[2*j]     = b[j];
                enc[2*j + 1] = ~b[j];
            end
        end
    endfunction

    task loopback_frame(input [31:0] by);        // by = {B3,B2,B1,B0}
        integer n;
        begin
            @(negedge clk);
            lb_data0 = {enc(by[15:8]),  enc(by[7:0])};
            lb_data1 = {enc(by[31:24]), enc(by[23:16])};
            lb_load  = 1;
            @(negedge clk);
            lb_load  = 0;
            n = 0;
            while (!data_ready && n < 60000) begin @(posedge clk); n = n + 1; end
            check(data_ready === 1'b1, "loopback: data_ready timeout");
            check(frame_data_out0 === by, "loopback: frame_data_out0 mismatch");
            check(frame_parity_error === 1'b0, "loopback: unexpected parity error");
            if (frame_data_out0 !== by)
                $display("        expected %h got %h", by, frame_data_out0);
            @(negedge clk);
            data_read_ack = 1;
            @(negedge clk);
            data_read_ack = 0;
            @(negedge clk);
            check(data_ready === 1'b0, "loopback: data_read_ack must clear data_ready");
            check(frame_parity_error === 1'b0, "loopback: parity flag must clear");
            repeat (4) @(negedge clk);
        end
    endtask

    // ---------------- test body ----------------------------------------------
    reg [63:0] P;
    integer    k, c0;

    initial begin
        if ($test$plusargs("dump")) begin $dumpfile("tb_dbb_top.vcd"); $dumpvars(0, tb_dbb_top); end

        rfid_rx_bit = IDLE;
        repeat (6) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        check(rfid_tx_bit === 1'b0, "rfid_tx_bit must be 0");

        // ================= T1: Mode 0, good frame =============================
        $display("T1: Mode 0 good 8-byte frame");
        align_live;
        P = 64'h1122_3344_5566_7788;
        live_frame(8, P, 8'h00);
        check(cdv_cnt == 1, "T1: expected exactly one cipher_data_valid pulse");
        check(cdv_data === P, "T1: cipher_data_in mismatch");
        check(cdv_perr === 1'b0, "T1: unexpected parity error");
        if (cdv_data !== P) $display("        exp %h got %h", P, cdv_data);

        // ================= T2: Mode 0, corrupted parity ==========================
        $display("T2: Mode 0 frame with a parity error");
        P = 64'hA5C3_0FF0_9669_81E7;
        live_frame(8, P, 8'b0001_0000);
        check(cdv_cnt == 2, "T2: expected 2nd cipher_data_valid pulse");
        check(cdv_data === P, "T2: cipher_data_in mismatch");
        check(cdv_perr === 1'b1, "T2: frame_parity_error must be set");

        // ================= T3: short frame, then a good one ========================
        $display("T3: Mode 0 short frame (3 bytes)");
        c0 = cdv_cnt;
        live_frame(3, 64'h00000000_00C0FFEE, 8'h00);
        check(cdv_cnt == c0, "T3: short frame must not produce cipher_data_valid");
        P = 64'hFEDC_BA98_7654_3210;
        live_frame(8, P, 8'h00);
        check(cdv_cnt == c0 + 1, "T3: full frame after short frame missing");
        check(cdv_data === P, "T3: data after short frame corrupted (auto-ack/count reset?)");
        check(cdv_perr === 1'b0, "T3: stale parity error");
        if (cdv_data !== P) $display("        exp %h got %h", P, cdv_data);
        check(dr_high_cycles_mode0 == 0, "data_ready must stay low in Mode 0");

        // ================= T4: Mode 1 loopback ====================================
        $display("T4: Mode 1 loopback");
        c0 = cdv_cnt;
        set_mode(2'd1);
        loopback_frame(32'hA55A_3CC3);
        loopback_frame(32'h0000_0000);
        loopback_frame(32'hFFFF_FFFF);
        for (k = 0; k < 4; k = k + 1) loopback_frame($urandom);
        check(cdv_cnt == c0, "T4: no cipher_data_valid expected in Mode 1");

        // ================= T5: mode switch in the middle of a live frame ===========
        $display("T5: Mode 0 -> 1 switch mid-frame");
        set_mode(2'd0);
        align_live;
        live_partial(21);                         // SOF + 21 bits, no EOF
        set_mode(2'd1);                           // flush
        loopback_frame(32'h1357_9BDF);
        loopback_frame(32'h2468_ACE0);
        c0 = cdv_cnt;
        set_mode(2'd0);
        align_live;
        P = 64'h0123_4567_89AB_CDEF;
        live_frame(8, P, 8'h00);
        check(cdv_cnt == c0 + 1, "T5: Mode 0 frame after switching back missing");
        check(cdv_data === P, "T5: data mismatch after switching back");
        if (cdv_data !== P) $display("        exp %h got %h", P, cdv_data);

        // ================= T6: Mode 2 idle ========================================
        $display("T6: Mode 2 produces nothing");
        c0 = cdv_cnt;
        set_mode(2'd2);
        live_frame(8, 64'hDEAD_BEEF_0BAD_F00D, 8'h00);
        check(cdv_cnt == c0, "T6: cipher_data_valid in Mode 2");
        check(data_ready === 1'b0, "T6: data_ready in Mode 2");
        check(dr_high_cycles_mode0 == 0, "T6: data_ready leaked outside Mode 1");

        check(tx_activity == 0, "rfid_tx_bit toggled");

        if (errors == 0) $display("TB_DBB_TOP: PASS (PH=%0d IDLE=%0d)", PH, IDLE);
        else             $display("TB_DBB_TOP: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #80000000;
        $display("TB_DBB_TOP: FAIL (timeout)");
        $finish;
    end
endmodule
