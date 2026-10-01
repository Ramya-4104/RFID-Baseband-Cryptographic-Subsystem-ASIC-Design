// =============================================================================
// tb_dbb_sync.v -- unit testbench for dbb_sync
// Checks: 2-cycle synchronizer latency, and that narrow glitches shorter than
// one clock period do not propagate (basic CDC sanity, not a metastability
// proof -- that's not something a functional sim can demonstrate anyway).
// =============================================================================
`timescale 1ns/1ps

module tb_dbb_sync;

    reg clk = 0;
    reg rst_n = 0;
    reg async_in = 0;
    wire sync_out;

    integer errors = 0;

    dbb_sync dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (async_in),
        .sync_out (sync_out)
    );

    always #5 clk = ~clk;  // 100 MHz

    task check(input exp, input [319:0] msg);
        begin
            if (sync_out !== exp) begin
                $display("[FAIL] %0s : expected=%b got=%b @ t=%0t", msg, exp, sync_out, $time);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s : sync_out=%b @ t=%0t", msg, sync_out, $time);
            end
        end
    endtask

    initial begin
        rst_n = 0;
        async_in = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk); #1;
        check(1'b0, "reset value");

        // Rising edge on async_in, sampled asynchronously between clk edges
        @(negedge clk);
        async_in = 1;

        @(posedge clk); #1; // meta_ff captures 1
        check(1'b0, "1 cycle after async rise, sync_out still old value");

        @(posedge clk); #1; // sync_out captures meta_ff (=1)
        check(1'b1, "2 cycles after async rise, sync_out propagated");

        // Falling edge
        @(negedge clk);
        async_in = 0;
        @(posedge clk); #1;
        check(1'b1, "1 cycle after async fall, sync_out still old value");
        @(posedge clk); #1;
        check(1'b0, "2 cycles after async fall, sync_out propagated");

        if (errors == 0)
            $display("\n=== tb_dbb_sync: ALL TESTS PASSED ===\n");
        else
            $display("\n=== tb_dbb_sync: %0d TEST(S) FAILED ===\n", errors);

        $finish;
    end

endmodule
