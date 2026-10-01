// ============================================================================
// tb_crypto_rfid_top_final.sv
//
// Final self-checking testbench for crypto_rfid_top (APB wrapper + DBB +
// PRESENT-80).  Simulation source only.
//
// >>> BEFORE YOU RUN <<<
//   DBB_IS_STUB = 1 : DUT contains the fake dbb_top from dut_stub_models.sv.
//                     Mode 0 and Mode 1 are checked by VALUE.
//   DBB_IS_STUB = 0 : DUT contains the REAL dbb_top.  Mode 1 is checked by
//                     handshake only (the expected decoded value of raw
//                     oversampled bits is the DBB owner's to define), and the
//                     Mode 0 end-to-end test is SKIPPED, because it needs a
//                     properly framed Manchester waveform (SOF / D-E-F
//                     sequences / parity / EOF at OSR=8, 236 clk per half-bit)
//                     whose exact format only the DBB owner can specify.
//   Default is 0 (real DBB). Change the parameter below or override it.
//   POST_ACK_GAP_CYCLES / DEBUG_DBB_TRACE are diagnostic knobs, see below.
//
// Clock is 50 MHz (20 ns) because dbb_top's HALF_BIT_CYCLES=236 assumes it.
//
// Tests
//   T0  reset values
//   T1  spec golden vector, literal stimulus from the project document
//   T2  four published PRESENT-80 vectors (also checks KEY_2 upper 16 bits
//       are ignored, by writing garbage into them)
//   T3  STATUS.DONE is sticky and clears on read
//   T4  register access rules: W/O reads 0, R/O writes ignored, unmapped
//   T5  write locks while PRESENT-80 busy (KEY, DATA, CTRL) + lock release
//   T6  Mode 0 end-to-end                       (stub only)
//   T7  Mode 1 handshake / value / ack, cipher not started in Mode 1
//   T8  write locks while DBB replay busy (DATA, CTRL)
//   T9  CTRL_REG read-back
//   plus continuous runtime protocol checks on internal wrapper signals.
// ============================================================================

`timescale 1ns/1ps

module tb_crypto_rfid_top;

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    parameter DBB_IS_STUB         = 0;        // 1 = fake DBB, 0 = REAL DBB (default)
    parameter POST_ACK_GAP_CYCLES = 0;        // idle cycles after each Mode 1 ack; raise (e.g. 3000)
                                              //   to test whether the DBB needs time to re-arm
    parameter DEBUG_DBB_TRACE     = 0;        // 1 = print lb_load/data_ready/busy/pready changes
    parameter CLK_HALF_PERIOD_NS  = 10;       // 50 MHz
    parameter STALL_LIMIT         = 1000000;  // max wait-state cycles per APB write
    parameter DBB_POLL_LIMIT      = 200000;   // max STATUS polls waiting on the DBB
    parameter WATCHDOG_NS         = 500000000;

    // ------------------------------------------------------------------
    // Clock / signals
    // ------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF_PERIOD_NS) clk = ~clk;

    reg         psel, penable, pwrite;
    reg  [31:0] paddr, pwdata;
    wire [31:0] prdata;
    wire        pready;
    reg         rfid_rx_bit;
    wire        rfid_tx_bit;

    localparam ADDR_CTRL_REG    = 32'h00;
    localparam ADDR_STATUS_REG  = 32'h04;
    localparam ADDR_KEY_0       = 32'h08;
    localparam ADDR_KEY_1       = 32'h0C;
    localparam ADDR_KEY_2       = 32'h10;
    localparam ADDR_DATA_0      = 32'h14;
    localparam ADDR_DATA_1      = 32'h18;
    localparam ADDR_DATA_OUT_0  = 32'h1C;
    localparam ADDR_DATA_OUT_1  = 32'h20;
    localparam ADDR_UNMAPPED    = 32'h24;

    localparam MODE_LIVE            = 2'd0;
    localparam MODE_DBB_LOOPBACK    = 2'd1;
    localparam MODE_CRYPTO_LOOPBACK = 2'd2;

    integer pass_count       = 0;
    integer fail_count       = 0;
    integer skip_count       = 0;
    integer proto_violations = 0;

    integer    wc;
    reg [31:0] rdata, rdata2, rdata3;
    reg [63:0] ct;
    reg        ok;

    crypto_rfid_top dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .psel        (psel),
        .penable     (penable),
        .pwrite      (pwrite),
        .paddr       (paddr),
        .pwdata      (pwdata),
        .prdata      (prdata),
        .pready      (pready),
        .rfid_rx_bit (rfid_rx_bit),
        .rfid_tx_bit (rfid_tx_bit)
    );

    // ------------------------------------------------------------------
    // APB bus functional model
    // ------------------------------------------------------------------
    // Inputs are driven 1 ns AFTER the clock edge with blocking assignments
    // (not `<=` straight at the edge). This is race-free in every simulator
    // (Xcelium, Questa, VCS, XSim, Icarus, Verilator) because the DUT always
    // samples the previous, stable value at the edge itself.
    // wait_cycles = number of cycles pready stayed low (0 = zero-wait access).
    task apb_write(input [31:0] addr, input [31:0] data, output integer wait_cycles);
        begin
            wait_cycles = 0;
            @(posedge clk); #1;
            psel    = 1'b1;
            pwrite  = 1'b1;
            paddr   = addr;
            pwdata  = data;
            penable = 1'b0;
            @(posedge clk); #1;
            penable = 1'b1;
            @(negedge clk);
            while ((pready !== 1'b1) && (wait_cycles < STALL_LIMIT)) begin
                wait_cycles = wait_cycles + 1;
                @(posedge clk);
                @(negedge clk);
            end
            if (pready !== 1'b1) begin
                proto_violations = proto_violations + 1;
                $display("[FAIL] apb_write to %h still stalled after %0d cycles", addr, STALL_LIMIT);
            end
            @(posedge clk); #1;
            psel    = 1'b0;
            penable = 1'b0;
            pwrite  = 1'b0;
        end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk); #1;
            psel    = 1'b1;
            pwrite  = 1'b0;
            paddr   = addr;
            penable = 1'b0;
            @(posedge clk); #1;
            penable = 1'b1;
            @(negedge clk);
            data = prdata;
            @(posedge clk); #1;
            psel    = 1'b0;
            penable = 1'b0;
        end
    endtask

    // Poll STATUS_REG until bit `bit_idx` is set, or give up after max_polls.
    task apb_poll_status(input integer bit_idx, input integer max_polls, output success);
        reg [31:0] status;
        integer n;
        begin
            success = 1'b0;
            n = 0;
            while (!success && n < max_polls) begin
                apb_read(ADDR_STATUS_REG, status);
                if (status[bit_idx]) success = 1'b1;
                n = n + 1;
            end
        end
    endtask

    task check(input logic cond, input string msg);
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $display("[PASS] %s", msg);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %s", msg);
            end
        end
    endtask

    task skip(input string msg);
        begin
            skip_count = skip_count + 1;
            $display("[SKIP] %s", msg);
        end
    endtask


    // One Mode 1 replay plus a lock probe. Writes DATA_0/DATA_1 (DATA_1 starts
    // the replay), then immediately attempts another DATA_0 write, which the
    // wrapper must stall until the DBB is done. `completed` is 1 only if the
    // DBB really raised DATA_READY; if the wrapper had to release the bus via
    // its replay timeout instead, completed = 0 (the DBB never answered).
    task mode1_replay(input [31:0] d0, input [31:0] d1,
                      output integer lock_wait, output completed);
        integer w;
        begin
            apb_write(ADDR_DATA_0, d0, w);
            apb_write(ADDR_DATA_1, d1, w);              // lb_load: replay starts
            apb_write(ADDR_DATA_0, d0, lock_wait);      // attempted mid-replay
            completed = dut.dbb_data_ready && !dut.dbb_replay_timed_out;
        end
    endtask

    // Read both halves of DATA_OUT (reading DATA_OUT_1 acks the DBB), then idle.
    task mode1_drain;
        reg [31:0] a, b;
        begin
            apb_read(ADDR_DATA_OUT_0, a);
            apb_read(ADDR_DATA_OUT_1, b);
            repeat (POST_ACK_GAP_CYCLES) @(posedge clk);
        end
    endtask

    // Full crypto operation in Mode 2 (mode must already be Mode 2).
    // KEY_2 upper 16 bits are deliberately filled with garbage: the spec says
    // only the lower 16 are used, so the result must be unaffected.
    task run_vector(input [79:0] key, input [63:0] pt, input [63:0] expected, input string name);
        integer w;
        reg [31:0] lo, hi;
        reg        done_ok;
        begin
            apb_write(ADDR_KEY_0, key[31:0],              w);
            apb_write(ADDR_KEY_1, key[63:32],             w);
            apb_write(ADDR_KEY_2, {16'hA5A5, key[79:64]}, w);
            apb_write(ADDR_DATA_0, pt[31:0],              w);
            apb_write(ADDR_DATA_1, pt[63:32],             w); // triggers the cipher
            apb_poll_status(0, 300, done_ok);
            apb_read(ADDR_DATA_OUT_0, lo);
            apb_read(ADDR_DATA_OUT_1, hi);
            check(done_ok, {name, ": DONE asserted"});
            check({hi, lo} === expected,
                  $sformatf("%s: ciphertext %h (expected %h)", name, {hi, lo}, expected));
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    initial begin
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        rfid_rx_bit = 1'b0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("==== tb_crypto_rfid_top_final  (DBB_IS_STUB=%0d) ====", DBB_IS_STUB);

        // ================= T0: reset values =================
        apb_read(ADDR_CTRL_REG, rdata);
        check(rdata === 32'd0, "T0: CTRL_REG resets to 0 (Live mode)");
        apb_read(ADDR_STATUS_REG, rdata);
        check(rdata[0] === 1'b0 && rdata[31:3] === 29'd0,
              "T0: STATUS_REG DONE=0 and reserved bits [31:3]=0 after reset");
        check(rfid_tx_bit === 1'b0, "T0: rfid_tx_bit tied low");

        // ================= T1: spec golden vector, literal stimulus =================
        // Key 0, PT 0 -> CT 5579C1387B228445, exactly as written in the spec.
        apb_write(ADDR_CTRL_REG, {30'd0, MODE_CRYPTO_LOOPBACK}, wc);
        apb_write(ADDR_KEY_0,  32'h00000000, wc);
        apb_write(ADDR_KEY_1,  32'h00000000, wc);
        apb_write(ADDR_KEY_2,  32'h00000000, wc);
        apb_write(ADDR_DATA_0, 32'h00000000, wc);
        apb_write(ADDR_DATA_1, 32'h00000000, wc);
        apb_poll_status(0, 300, ok);
        check(ok, "T1: DONE asserted");
        apb_read(ADDR_DATA_OUT_0, rdata);
        apb_read(ADDR_DATA_OUT_1, rdata2);
        ct = {rdata2, rdata};
        check(ct === 64'h5579C1387B228445,
              $sformatf("T1: Test Vector 1 golden match (got %h)", ct));

        // ================= T2: the four published PRESENT-80 vectors =================
        run_vector(80'h0000_0000_0000_0000_0000, 64'h0000_0000_0000_0000, 64'h5579C1387B228445, "T2 key=0  pt=0 ");
        run_vector(80'hFFFF_FFFF_FFFF_FFFF_FFFF, 64'h0000_0000_0000_0000, 64'hE72C46C0F5945049, "T2 key=F  pt=0 ");
        run_vector(80'h0000_0000_0000_0000_0000, 64'hFFFF_FFFF_FFFF_FFFF, 64'hA112FFC72F68417B, "T2 key=0  pt=F ");
        run_vector(80'hFFFF_FFFF_FFFF_FFFF_FFFF, 64'hFFFF_FFFF_FFFF_FFFF, 64'h3333DCD3213210D2, "T2 key=F  pt=F ");

        // ================= T3: STATUS.DONE sticky, clear-on-read =================
        apb_write(ADDR_KEY_0, 32'h0, wc);
        apb_write(ADDR_KEY_1, 32'h0, wc);
        apb_write(ADDR_KEY_2, 32'h0, wc);
        apb_write(ADDR_DATA_0, 32'h0, wc);
        apb_write(ADDR_DATA_1, 32'h0, wc);
        repeat (60) @(posedge clk);            // long after the 1-cycle done pulse
        apb_read(ADDR_STATUS_REG, rdata);      // first read: DONE still visible
        apb_read(ADDR_STATUS_REG, rdata2);     // second read: cleared by the first
        check(rdata[0] === 1'b1,  "T3: DONE still set long after the 1-cycle pulse (sticky)");
        check(rdata2[0] === 1'b0, "T3: DONE cleared by reading STATUS_REG");
        check(rdata[31:3] === 29'd0, "T3: STATUS reserved bits [31:3] read as 0");

        // ================= T4: register access rules =================
        apb_write(ADDR_KEY_0,  32'hA5A5A5A5, wc);
        check(wc === 0, "T4: idle write to KEY_0 completes with zero wait states");
        apb_read(ADDR_KEY_0, rdata);
        check(rdata === 32'd0, "T4: KEY_0 (W/O) reads back 0");
        apb_write(ADDR_DATA_0, 32'h5A5A5A5A, wc);
        apb_read(ADDR_DATA_0, rdata);
        check(rdata === 32'd0, "T4: DATA_0 (W/O) reads back 0");
        apb_read(ADDR_DATA_OUT_0, rdata);      // last result is still in DATA_OUT
        apb_write(ADDR_DATA_OUT_0, 32'hFFFFFFFF, wc);   // R/O: write must be ignored
        apb_read(ADDR_DATA_OUT_0, rdata2);
        check(rdata2 === rdata, "T4: write to DATA_OUT_0 (R/O) ignored");
        apb_write(ADDR_STATUS_REG, 32'hFFFFFFFF, wc);   // R/O: write must be ignored
        apb_read(ADDR_STATUS_REG, rdata);
        check(rdata[31:3] === 29'd0, "T4: write to STATUS_REG (R/O) ignored");
        apb_write(ADDR_UNMAPPED, 32'hDEADBEEF, wc);
        check(wc === 0, "T4: write to unmapped address completes without stalling");
        apb_read(ADDR_UNMAPPED, rdata);
        check(rdata === 32'd0, "T4: read of unmapped address returns 0");

        // ================= T5: locks while PRESENT-80 busy (Mode 2) =================
        apb_write(ADDR_KEY_0, 32'h0, wc);
        apb_write(ADDR_KEY_1, 32'h0, wc);
        apb_write(ADDR_KEY_2, 32'h0, wc);
        apb_write(ADDR_DATA_0, 32'h0, wc);
        apb_write(ADDR_DATA_1, 32'h0, wc);              // cipher busy for ~32 cycles
        apb_write(ADDR_KEY_0, 32'hFFFFFFFF, wc);        // attempted while busy
        check(wc > 0, $sformatf("T5: KEY_0 write stalled while cipher busy (wait=%0d)", wc));
        apb_poll_status(0, 300, ok);
        check(ok, "T5: cipher completes after stalled key write");
        apb_read(ADDR_DATA_OUT_0, rdata);
        apb_read(ADDR_DATA_OUT_1, rdata2);
        check({rdata2, rdata} === 64'h5579C1387B228445,
              "T5: in-flight result not corrupted by attempted key overwrite");
        apb_write(ADDR_KEY_0, 32'h0, wc);
        check(wc === 0, "T5: KEY_0 write proceeds normally once cipher is idle again");

        apb_write(ADDR_DATA_1, 32'h0, wc);              // start again (key back to 0)
        apb_write(ADDR_DATA_0, 32'h12345678, wc);       // DATA_0 while busy (Mode 2)
        check(wc > 0, $sformatf("T5: DATA_0 write stalled while cipher busy in Mode 2 (wait=%0d)", wc));
        apb_poll_status(0, 300, ok);
        check(ok, "T5: cipher completes after stalled data write");

        apb_write(ADDR_DATA_0, 32'h0, wc);
        apb_write(ADDR_DATA_1, 32'h0, wc);              // start again
        apb_write(ADDR_CTRL_REG, {30'd0, MODE_DBB_LOOPBACK}, wc); // mode switch mid-op
        check(wc > 0, $sformatf("T5: CTRL_REG (mode) write stalled while cipher busy (wait=%0d)", wc));
        apb_poll_status(0, 300, ok);
        check(ok, "T5: cipher completes after stalled mode switch");
        apb_read(ADDR_DATA_OUT_0, rdata);
        apb_read(ADDR_DATA_OUT_1, rdata2);
        check({rdata2, rdata} === 64'h5579C1387B228445,
              "T5: result intact after stalled mode-switch attempt");
        // The stalled write landed after completion, so we are now in Mode 1.
        apb_read(ADDR_CTRL_REG, rdata);
        check(rdata[1:0] === MODE_DBB_LOOPBACK, "T5: stalled CTRL write landed after the cipher finished");

        // ================= T6: Mode 0 end-to-end (stub only) =================
        if (DBB_IS_STUB) begin
            apb_write(ADDR_CTRL_REG, {30'd0, MODE_CRYPTO_LOOPBACK}, wc);
            // Prime DATA_OUT with a result different from the golden vector so a
            // stale value can never make the Mode 0 check pass by accident.
            run_vector(80'hFFFF_FFFF_FFFF_FFFF_FFFF, 64'hFFFF_FFFF_FFFF_FFFF,
                       64'h3333DCD3213210D2, "T6 priming ");
            apb_write(ADDR_KEY_0, 32'h0, wc);
            apb_write(ADDR_KEY_1, 32'h0, wc);
            apb_write(ADDR_KEY_2, 32'h0, wc);
            // Stub DBB: one raw bit per clock, 64 bits per word. rx is held HIGH
            // before entering Mode 0 so every 64-bit window is all ones. Plaintext
            // FFFF_FFFF_FFFF_FFFF with key 0 must give A112FFC72F68417B. A NON-zero
            // plaintext is deliberate: an all-zero one could not detect a wrapper
            // that hands the cipher a stale or zeroed word.
            #1 rfid_rx_bit = 1'b1;
            apb_write(ADDR_CTRL_REG, {30'd0, MODE_LIVE}, wc);
            apb_read(ADDR_STATUS_REG, rdata);           // clear any stale sticky DONE
            apb_poll_status(0, 400, ok);
            check(ok, "T6: Mode 0 DONE asserted after DBB hands a word to the cipher");
            apb_read(ADDR_DATA_OUT_0, rdata);
            apb_read(ADDR_DATA_OUT_1, rdata2);
            check({rdata2, rdata} === 64'hA112FFC72F68417B,
                  $sformatf("T6: Mode 0 end-to-end ciphertext for pt=F (got %h)", {rdata2, rdata}));
            #1 rfid_rx_bit = 1'b0;
            apb_write(ADDR_CTRL_REG, {30'd0, MODE_DBB_LOOPBACK}, wc);
        end else begin
            skip("T6: Mode 0 end-to-end needs a framed Manchester waveform from the DBB owner's spec");
        end

        // ================= T7: Mode 1 =================
        apb_write(ADDR_CTRL_REG, {30'd0, MODE_DBB_LOOPBACK}, wc);
        apb_write(ADDR_DATA_0, 32'hDEADBEEF, wc);
        apb_write(ADDR_DATA_1, 32'hCAFEF00D, wc);       // lb_load
        repeat (4) @(posedge clk);
        check(dut.cipher_busy === 1'b0, "T7: cipher is NOT started by a DATA_1 write in Mode 1");
        apb_poll_status(1, DBB_POLL_LIMIT, ok);         // bit 1 = DATA_READY
        check(ok, "T7: Mode 1 DATA_READY asserted");
        apb_read(ADDR_DATA_OUT_0, rdata);
        apb_read(ADDR_DATA_OUT_1, rdata2);              // reading DATA_OUT_1 acks the DBB
        if (DBB_IS_STUB)
            check({rdata2, rdata} === 64'hCAFEF00DDEADBEEF,
                  $sformatf("T7: Mode 1 word echoed correctly (got %h)", {rdata2, rdata}));
        else
            skip("T7: Mode 1 decoded value check (needs expected decode from DBB owner)");
        repeat (4) @(posedge clk);
        apb_read(ADDR_STATUS_REG, rdata3);
        check(rdata3[1] === 1'b0, "T7: DATA_READY cleared after DATA_OUT_1 read (ack)");
        repeat (POST_ACK_GAP_CYCLES) @(posedge clk);

        // ================= T8: locks while DBB replay busy =================
        // Uses the SAME pattern as T7 (known to complete on the real DBB) so a
        // failure here is about the handshake, not about a pattern the DBB
        // cannot frame. Every stall is bounded by the wrapper's replay timeout,
        // so a DBB that never answers can no longer hang the bus or cascade.
        mode1_replay(32'hDEADBEEF, 32'hCAFEF00D, wc, ok);
        check(wc > 0, $sformatf("T8: DATA_0 write stalled while DBB busy (wait=%0d)", wc));
        check(ok, "T8: DBB completed the replay (DATA_READY rose) and released the stalled write");
        if (!ok)
            $display("[DIAG] T8: replay produced no DATA_READY; wrapper timed out (timed_out=%b) - DBB ignored the load or never framed it. Try POST_ACK_GAP_CYCLES=3000 and DEBUG_DBB_TRACE=1",
                     dut.dbb_replay_timed_out);
        else mode1_drain;

        // A new DATA write while the previous Mode 1 result is still UNREAD must be allowed.
        mode1_replay(32'hDEADBEEF, 32'hCAFEF00D, wc, ok);
        check(ok, "T8: second replay completed (result left unread)");
        if (ok) begin
            apb_write(ADDR_DATA_0, 32'h88888888, wc);
            check(wc === 0, "T8: DATA write allowed while previous Mode 1 result is unread");
            mode1_drain;
        end else skip("T8: unread-result write check needs a completed replay");

        // CTRL_REG lock while the DBB is busy.
        apb_write(ADDR_DATA_0, 32'hDEADBEEF, wc);
        apb_write(ADDR_DATA_1, 32'hCAFEF00D, wc);
        apb_write(ADDR_CTRL_REG, {30'd0, MODE_CRYPTO_LOOPBACK}, wc);   // mode switch mid-replay
        check(wc > 0, $sformatf("T8: CTRL_REG write stalled while DBB busy (wait=%0d)", wc));
        apb_write(ADDR_CTRL_REG, {30'd0, MODE_DBB_LOOPBACK}, wc);      // back to Mode 1
        if (dut.dbb_data_ready) mode1_drain;

        // Informational probe: a pattern that may not form a valid frame.
        mode1_replay(32'h33333333, 32'h44444444, wc, ok);
        if (ok) begin
            check(1'b1, "T8: probe pattern 33333333/44444444 also completed on the DBB");
            mode1_drain;
        end else if (DBB_IS_STUB) begin
            check(1'b0, "T8: probe pattern should complete on the stub DBB");
        end else begin
            skip("T8: probe pattern 33333333/44444444 gave no DATA_READY on the real DBB (wrapper released the bus by timeout) - DBB owner to define valid Mode 1 patterns");
        end

        // ================= T9: CTRL_REG read-back =================
        apb_write(ADDR_CTRL_REG, 32'hFFFFFFFD, wc);     // upper bits ignored, mode = 1
        apb_read(ADDR_CTRL_REG, rdata);
        check(rdata === 32'd1, $sformatf("T9: CTRL_REG reads back mode only, upper bits 0 (got %h)", rdata));
        apb_write(ADDR_CTRL_REG, {30'd0, MODE_CRYPTO_LOOPBACK}, wc);
        apb_read(ADDR_CTRL_REG, rdata);
        check(rdata === 32'd2, "T9: CTRL_REG read-back = Crypto Loopback");

        // ================= Summary =================
        repeat (5) @(posedge clk);
        $display("----------------------------------------------------------");
        $display("RESULT: %0d passed, %0d failed, %0d skipped, %0d protocol violations",
                 pass_count, fail_count, skip_count, proto_violations);
        if (fail_count == 0 && proto_violations == 0)
            $display("ALL CHECKS PASSED");
        else
            $display("*** THERE WERE FAILURES ***");
        $display("----------------------------------------------------------");
        $finish;
    end


    // ------------------------------------------------------------------
    // Optional DBB handshake trace (set DEBUG_DBB_TRACE = 1)
    // Prints only when one of the tracked signals CHANGES.
    // ------------------------------------------------------------------
    reg [6:0] trace_prev = 7'd0;
    always @(posedge clk) begin
        if (DEBUG_DBB_TRACE && rst_n) begin
            if ({dut.lb_load, dut.dbb_data_ready, dut.dbb_data_ready_rise,
                 dut.dbb_replay_busy, dut.dbb_replay_timed_out, pready, dut.data_read_ack} !== trace_prev) begin
                $display("[TRACE] t=%0t lb_load=%b data_ready=%b rise=%b replay_busy=%b timed_out=%b pready=%b ack=%b",
                         $time, dut.lb_load, dut.dbb_data_ready, dut.dbb_data_ready_rise,
                         dut.dbb_replay_busy, dut.dbb_replay_timed_out, pready, dut.data_read_ack);
                trace_prev = {dut.lb_load, dut.dbb_data_ready, dut.dbb_data_ready_rise,
                              dut.dbb_replay_busy, dut.dbb_replay_timed_out, pready, dut.data_read_ack};
            end
        end
    end

    // ------------------------------------------------------------------
    // Watchdog: never hang the simulator
    // ------------------------------------------------------------------
    initial begin
        #(WATCHDOG_NS);
        $display("[FATAL] watchdog expired after %0d ns - simulation aborted", WATCHDOG_NS);
        $finish;
    end

    // ------------------------------------------------------------------
    // Runtime protocol checks on internal wrapper signals
    // ------------------------------------------------------------------
    // Immediate-style checks so they run on any simulator (Icarus / XSim).
    // On Questa/VCS/Xcelium these can be upgraded to assert property.
    reg prev_cipher_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_cipher_busy <= 1'b0;
        end else begin
            prev_cipher_busy <= dut.cipher_busy;

            if (dut.cipher_busy && (dut.wen_key0 || dut.wen_key1 || dut.wen_key2)) begin
                proto_violations = proto_violations + 1;
                $error("PROTOCOL: KEY register written while cipher_busy");
            end
            if (dut.ctrl_locked && dut.wen_ctrl) begin
                proto_violations = proto_violations + 1;
                $error("PROTOCOL: CTRL_REG written while a block was busy");
            end
            if (dut.data_locked && (dut.wen_data0 || dut.wen_data1)) begin
                proto_violations = proto_violations + 1;
                $error("PROTOCOL: DATA register written while its owning block was busy");
            end
            if (dut.cipher_start && prev_cipher_busy) begin
                proto_violations = proto_violations + 1;
                $error("PROTOCOL: cipher_start pulsed while cipher was already busy");
            end
            if (psel && penable && (pready === 1'bx)) begin
                proto_violations = proto_violations + 1;
                $error("PROTOCOL: pready is X during a valid APB access");
            end
        end
    end

endmodule