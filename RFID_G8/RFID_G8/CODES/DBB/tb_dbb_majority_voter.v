// =============================================================================
// tb_dbb_majority_voter.v -- unit testbench for dbb_majority_voter
// Drives os_shreg directly (this block doesn't own the sampling, just the
// vote) with hand-picked patterns covering: solid 1s, solid 0s, and
// near-tie patterns on the voted bits [5:1], and checks bit_out / timing
// of bit_out_valid relative to os_shreg_full.
// =============================================================================
`timescale 1ns/1ps

module tb_dbb_majority_voter;

    localparam OSR = 8;

    reg clk = 0;
    reg rst_n = 0;
    reg [OSR-1:0] os_shreg = 0;
    reg os_shreg_full = 0;

    wire bit_out, bit_out_valid;

    integer errors = 0;

    dbb_majority_voter #(.OSR(OSR)) dut (
        .clk (clk), .rst_n (rst_n),
        .os_shreg (os_shreg), .os_shreg_full (os_shreg_full),
        .bit_out (bit_out), .bit_out_valid (bit_out_valid)
    );

    always #5 clk = ~clk;

    task apply_and_check(input [OSR-1:0] shreg_val, input exp_bit, input [255:0] msg);
        begin
            @(negedge clk);
            os_shreg = shreg_val;
            os_shreg_full = 1;
            @(negedge clk);
            os_shreg_full = 0;
            #1;
            if (bit_out_valid !== 1'b1) begin
                $display("[FAIL] %0s : bit_out_valid not asserted", msg);
                errors = errors + 1;
            end else if (bit_out !== exp_bit) begin
                $display("[FAIL] %0s : os_shreg=%b expected bit_out=%b got %b", msg, shreg_val, exp_bit, bit_out);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s : os_shreg=%b -> bit_out=%b", msg, shreg_val, bit_out);
            end
            @(negedge clk);
            if (bit_out_valid !== 1'b0) begin
                $display("[FAIL] %0s : bit_out_valid did not deassert after 1 cycle", msg);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Voted bits are os_shreg[5:1] (5 samples). Edge samples [7],[6],[0]
        // are intentionally excluded from the vote -- set them to the
        // opposite value in a couple of cases to prove they're ignored.

        apply_and_check(8'b0_111110_0, 1'b1, "solid 1s in voted field -> 1");
        apply_and_check(8'b1_000001_1, 1'b0, "solid 0s in voted field, edges=1 -> 0 (edges ignored)");
        apply_and_check(8'b0_111000_0, 1'b0, "3 zeros/2 ones in voted field -> minority 0");
        apply_and_check(8'b0_110000_1, 1'b0, "2 ones/3 zeros in voted field -> 0");
        apply_and_check(8'b0_111100_0, 1'b1, "4 ones/1 zero in voted field -> 1");
        apply_and_check(8'b0_000011_0, 1'b0, "2 ones/3 zeros (different pattern) -> 0");
        apply_and_check(8'b1_111100_1, 1'b1, "4 ones/1 zero with edges=1 -> 1 (edges still ignored)");

        // os_shreg_full not pulsed -> bit_out_valid must stay low
        @(negedge clk);
        os_shreg = 8'hFF;
        repeat (3) @(negedge clk);
        if (bit_out_valid !== 1'b0) begin
            $display("[FAIL] bit_out_valid asserted without os_shreg_full pulse");
            errors = errors + 1;
        end else begin
            $display("[PASS] bit_out_valid stays low with no os_shreg_full pulse");
        end

        if (errors == 0)
            $display("\n=== tb_dbb_majority_voter: ALL TESTS PASSED ===\n");
        else
            $display("\n=== tb_dbb_majority_voter: %0d TEST(S) FAILED ===\n", errors);

        $finish;
    end

endmodule
