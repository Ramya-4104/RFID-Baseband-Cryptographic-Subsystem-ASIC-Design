`timescale 1ns/1ps

module tb_dbb_oversampler;

    localparam OSR             = 8;
    localparam HALF_BIT_CYCLES = 236;

    reg clk;
    reg rst_n;
    reg bit_in;
    reg enable;

    wire [OSR-1:0] os_shreg;
    wire           os_shreg_full;
    wire           strobe_out;

    dbb_oversampler #(
        .OSR(OSR),
        .HALF_BIT_CYCLES(HALF_BIT_CYCLES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .bit_in(bit_in),
        .enable(enable),
        .os_shreg(os_shreg),
        .os_shreg_full(os_shreg_full),
        .strobe_out(strobe_out)
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    integer i;
    integer cycle_count;
    integer last_strobe_cycle;

    initial begin
        rst_n = 1'b0;
        bit_in = 1'b0;
        enable = 1'b0;
        cycle_count = 0;
        last_strobe_cycle = 0;

        $display("========================================");
        $display(" DBB OVERSAMPLER TESTBENCH");
        $display("========================================");

        // Reset
        repeat (5) @(posedge clk);

        if (os_shreg !== 8'b0)
            $display("ERROR: os_shreg not zero after reset");

        if (os_shreg_full !== 1'b0)
            $display("ERROR: os_shreg_full not zero after reset");

        if (strobe_out !== 1'b0)
            $display("ERROR: strobe_out not zero after reset");

        $display("RESET TEST PASSED");

        // Enable
        rst_n = 1'b1;
        enable = 1'b1;

        $display("");
        $display("Checking strobe timing...");

        // Count clock cycles and observe strobes.
        for (cycle_count = 1; cycle_count <= 1000; cycle_count = cycle_count + 1) begin
            @(posedge clk);

            if (strobe_out) begin
                $display("Strobe at clock cycle %0d", cycle_count);

                if (last_strobe_cycle != 0) begin
                    $display("  Interval = %0d clocks",
                             cycle_count - last_strobe_cycle);
                end

                last_strobe_cycle = cycle_count;
            end
        end

        // Test shift-register filling.
        $display("");
        $display("Checking 8-sample shift register...");

        enable = 1'b0;
        repeat (2) @(posedge clk);

        enable = 1'b1;

        // Present a known sequence.
        bit_in = 1'b1;
        @(posedge strobe_out);

        bit_in = 1'b0;
        @(posedge strobe_out);

        bit_in = 1'b1;
        @(posedge strobe_out);

        bit_in = 1'b0;
        @(posedge strobe_out);

        bit_in = 1'b1;
        @(posedge strobe_out);

        bit_in = 1'b0;
        @(posedge strobe_out);

        bit_in = 1'b1;
        @(posedge strobe_out);

        bit_in = 1'b0;
        @(posedge strobe_out);

        #1;

        if (os_shreg_full !== 1'b1)
            $display("ERROR: os_shreg_full should be asserted after 8 samples");
        else
            $display("os_shreg_full asserted correctly");

        $display("os_shreg = %b", os_shreg);

        // Check full pulse.
        @(posedge clk);
        #1;

        if (os_shreg_full !== 1'b0)
            $display("ERROR: os_shreg_full should be a pulse");
        else
            $display("os_shreg_full pulse check PASSED");

        // Disable.
        $display("");
        $display("Checking disable behavior...");

        enable = 1'b0;
        repeat (2) @(posedge clk);
        #1;

        if (os_shreg_full !== 1'b0)
            $display("ERROR: os_shreg_full not cleared when disabled");

        if (strobe_out !== 1'b0)
            $display("ERROR: strobe_out not cleared when disabled");

        $display("DISABLE TEST PASSED");

        $display("");
        $display("========================================");
        $display(" TESTBENCH COMPLETE");
        $display("========================================");

        $finish;
    end

endmodule
