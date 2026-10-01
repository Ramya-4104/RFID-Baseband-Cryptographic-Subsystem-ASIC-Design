`timescale 1ns/1ps
module tb_present_core;

    // ================================================================
    // Testbench signals
    // ================================================================
    reg         clk;
    reg         rst_n;
    reg         start;

    reg  [63:0] plaintext;
    reg  [79:0] key;

    wire [63:0] ciphertext;
    wire        done;
    wire        busy;


    // ================================================================
    // DUT
    // ================================================================
    present_core dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .plaintext  (plaintext),
        .key        (key),
        .ciphertext (ciphertext),
        .done        (done),
        .busy        (busy)
    );


    // ================================================================
    // Clock: 100 MHz
    // ================================================================
    always #5 clk = ~clk;


    // ================================================================
    // PRESENT-80 test task
    // ================================================================
    task run_test;

        input [63:0] pt;
        input [79:0] test_key;
        input [63:0] expected_ct;

        begin

            $display("");
            $display("============================================================");
            $display("STARTING PRESENT-80 TEST");
            $display("Plaintext : %016h", pt);
            $display("Key       : %020h", test_key);
            $display("Expected  : %016h", expected_ct);
            $display("============================================================");


            // --------------------------------------------------------
            // Apply inputs
            // --------------------------------------------------------
            plaintext = pt;
            key       = test_key;
            start     = 1'b0;


            // Make sure previous encryption has finished.
            if (busy) begin
                wait (!busy);
            end


            // --------------------------------------------------------
            // Generate a clean one-cycle START pulse
            // --------------------------------------------------------
            @(negedge clk);
            start = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;


            // --------------------------------------------------------
            // Wait for encryption to complete
            //
            // PRESENT-80 core:
            //
            // Start
            //   |
            //   +-- Round 1  -> K1
            //   +-- Round 2  -> K2
            //   ...
            //   +-- Round 31 -> K31
            //   +-- Final whitening -> K32
            //                    |
            //                   done
            // --------------------------------------------------------
            wait (done == 1'b1);

            #1;


            // --------------------------------------------------------
            // Check result
            // --------------------------------------------------------
            if (ciphertext !== expected_ct) begin

                $display("");
                $display("****************************************************");
                $display("FAIL");
                $display("Plaintext : %016h", pt);
                $display("Key       : %020h", test_key);
                $display("Expected  : %016h", expected_ct);
                $display("Got       : %016h", ciphertext);
                $display("****************************************************");

                $fatal(1);

            end
            else begin

                $display("");
                $display("PASS");
                $display("Plaintext : %016h", pt);
                $display("Key       : %020h", test_key);
                $display("Ciphertext: %016h", ciphertext);
                $display("============================================================");

            end


            // Allow done to return low before the next test.
            @(posedge clk);
            #1;

        end

    endtask


    // ================================================================
    // Waveform dump
    // ================================================================
    initial begin

        $dumpfile("present80.vcd");
        $dumpvars(0, tb_present_core);

    end


    // ================================================================
    // Cycle-by-cycle debug output
    // ================================================================
    always @(posedge clk) begin

        if (busy || done) begin

            $display(
                "T=%0t | CORE_ROUND=%0d | KEY_ROUND=%0d | KEY=%016h | STATE=%016h | BUSY=%b | DONE=%b",
                $time,
                dut.round_ctr,
                dut.u_key_schedule.round_count,
                dut.u_key_schedule.round_key_out,
                dut.state_reg,
                busy,
                done
            );

        end

    end


    // ================================================================
    // Main test sequence
    // ================================================================
    initial begin

        // ------------------------------------------------------------
        // Initial values
        // ------------------------------------------------------------
        clk       = 1'b0;
        rst_n     = 1'b0;
        start     = 1'b0;
        plaintext = 64'b0;
        key       = 80'b0;


        // ------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------
        repeat (2) @(posedge clk);

        rst_n = 1'b1;

        @(posedge clk);
        #1;


        // ============================================================
        // OFFICIAL PRESENT-80 TEST VECTORS
        // ============================================================

        // ------------------------------------------------------------
        // Test 1
        // P = 0000000000000000
        // K = 00000000000000000000
        // C = 5579C1387B228445
        // ------------------------------------------------------------
        run_test(
            64'h0000000000000000,
            80'h00000000000000000000,
            64'h5579C1387B228445
        );


        // ------------------------------------------------------------
        // Test 2
        // P = 0000000000000000
        // K = FFFFFFFFFFFFFFFFFFFF
        // C = E72C46C0F5945049
        // ------------------------------------------------------------
        run_test(
            64'h0000000000000000,
            80'hFFFFFFFFFFFFFFFFFFFF,
            64'hE72C46C0F5945049
        );


        // ------------------------------------------------------------
        // Test 3
        // P = FFFFFFFFFFFFFFFF
        // K = 00000000000000000000
        // C = A112FFC72F68417B
        // ------------------------------------------------------------
        run_test(
            64'hFFFFFFFFFFFFFFFF,
            80'h00000000000000000000,
            64'hA112FFC72F68417B
        );


        // ------------------------------------------------------------
        // Test 4
        // P = FFFFFFFFFFFFFFFF
        // K = FFFFFFFFFFFFFFFFFFFF
        // C = 3333DCD3213210D2
        // ------------------------------------------------------------
        run_test(
            64'hFFFFFFFFFFFFFFFF,
            80'hFFFFFFFFFFFFFFFFFFFF,
            64'h3333DCD3213210D2
        );


        // ============================================================
        // ALL TESTS COMPLETE
        // ============================================================
        $display("");
        $display("============================================================");
        $display("ALL PRESENT-80 CORE TESTS PASSED");
        $display("============================================================");
        $display("");

        #20;

        $finish;

    end

endmodule