// =============================================================================
// tb_dbb_byte_framer.v -- unit testbench for dbb_byte_framer
// Feeds bytes in, checks the packed frame_buf placement, byte_count,
// data_ready timing off frame_done, data_read_ack clearing, frame_abort
// discarding a partial frame, and that new bytes are rejected while
// data_ready is still asserted (buffer occupied, firmware hasn't read yet).
// =============================================================================
`timescale 1ns/1ps

module tb_dbb_byte_framer;

    localparam FRAME_BYTES = 4;  // small, for a quick/legible test

    reg clk = 0;
    reg rst_n = 0;
    reg byte_valid = 0;
    reg [7:0] byte_data = 0;
    reg parity_error = 0;
    reg frame_done = 0;
    reg frame_abort = 0;
    reg data_read_ack = 0;

    wire [FRAME_BYTES*8-1:0] frame_buf;
    wire [$clog2(FRAME_BYTES+1)-1:0] byte_count;
    wire frame_parity_error, data_ready;

    integer errors = 0;

    dbb_byte_framer #(.FRAME_BYTES(FRAME_BYTES)) dut (
        .clk (clk), .rst_n (rst_n),
        .byte_valid (byte_valid), .byte_data (byte_data), .parity_error (parity_error),
        .frame_done (frame_done), .frame_abort (frame_abort), .data_read_ack (data_read_ack),
        .frame_buf (frame_buf), .byte_count (byte_count),
        .frame_parity_error (frame_parity_error), .data_ready (data_ready)
    );

    always #5 clk = ~clk;

    task push_byte(input [7:0] d, input perr);
        begin
            @(negedge clk);
            byte_valid = 1; byte_data = d; parity_error = perr;
            @(negedge clk);
            byte_valid = 0; parity_error = 0;
        end
    endtask

    task pulse_frame_done;
        begin
            @(negedge clk);
            frame_done = 1;
            @(negedge clk);
            frame_done = 0;
        end
    endtask

    task pulse_abort;
        begin
            @(negedge clk);
            frame_abort = 1;
            @(negedge clk);
            frame_abort = 0;
        end
    endtask

    task pulse_ack;
        begin
            @(negedge clk);
            data_read_ack = 1;
            @(negedge clk);
            data_read_ack = 0;
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // --- Fill a full 4-byte frame, no parity errors ---
        push_byte(8'h11, 1'b0);
        push_byte(8'h22, 1'b0);
        push_byte(8'h33, 1'b0);
        push_byte(8'h44, 1'b0);
        #1;
        if (byte_count !== 4 || frame_buf !== 32'h44332211) begin
            $display("[FAIL] frame_buf=%h byte_count=%0d (expected 44332211, 4)", frame_buf, byte_count);
            errors = errors + 1;
        end else begin
            $display("[PASS] 4 bytes packed correctly: frame_buf=%h byte_count=%0d", frame_buf, byte_count);
        end
        if (data_ready !== 1'b0) begin
            $display("[FAIL] data_ready asserted before frame_done");
            errors = errors + 1;
        end

        pulse_frame_done;
        #1;
        if (data_ready !== 1'b1) begin
            $display("[FAIL] data_ready not asserted after frame_done");
            errors = errors + 1;
        end else begin
            $display("[PASS] data_ready asserted after frame_done");
        end
        if (frame_parity_error !== 1'b0) begin
            $display("[FAIL] frame_parity_error incorrectly set (no bytes had parity errors)");
            errors = errors + 1;
        end

        // --- A byte arriving while data_ready is still high must be ignored ---
        push_byte(8'hFF, 1'b0);
        #1;
        if (byte_count !== 4 || frame_buf[7:0] !== 8'h11) begin
            $display("[FAIL] byte accepted into an occupied (unread) buffer");
            errors = errors + 1;
        end else begin
            $display("[PASS] byte correctly rejected while buffer occupied (data_ready high)");
        end

        // --- ack clears the buffer for reuse ---
        pulse_ack;
        #1;
        if (data_ready !== 1'b0 || byte_count !== 0) begin
            $display("[FAIL] data_read_ack did not clear data_ready/byte_count");
            errors = errors + 1;
        end else begin
            $display("[PASS] data_read_ack clears data_ready and byte_count");
        end

        // --- Second frame: one byte has a parity error -> sticky frame_parity_error ---
        push_byte(8'hAA, 1'b0);
        push_byte(8'hBB, 1'b1);   // parity error on this byte
        push_byte(8'hCC, 1'b0);
        pulse_frame_done;
        #1;
        if (frame_parity_error !== 1'b1) begin
            $display("[FAIL] frame_parity_error not set despite a bad byte in the frame");
            errors = errors + 1;
        end else begin
            $display("[PASS] frame_parity_error correctly latched sticky for the frame");
        end
        pulse_ack;

        // --- frame_abort discards a partial frame without setting data_ready ---
        push_byte(8'h01, 1'b0);
        push_byte(8'h02, 1'b0);
        pulse_abort;
        #1;
        if (byte_count !== 0 || data_ready !== 1'b0) begin
            $display("[FAIL] frame_abort did not discard partial frame cleanly");
            errors = errors + 1;
        end else begin
            $display("[PASS] frame_abort discards partial frame, data_ready stays low");
        end

        if (errors == 0)
            $display("\n=== tb_dbb_byte_framer: ALL TESTS PASSED ===\n");
        else
            $display("\n=== tb_dbb_byte_framer: %0d TEST(S) FAILED ===\n", errors);

        $finish;
    end

endmodule
