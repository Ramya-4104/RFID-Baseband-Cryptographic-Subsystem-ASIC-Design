// =============================================================================
// tb_dbb_byte_assembler.v -- unit testbench for dbb_byte_assembler
// Feeds 8 data bits (LSB-first) + 1 parity bit while frame_active is high,
// checks byte_data/byte_valid/parity_error for both correct and deliberately
// broken parity, and checks that consumption halts when frame_active drops.
// =============================================================================
`timescale 1ns/1ps

module tb_dbb_byte_assembler;

    reg clk = 0;
    reg rst_n = 0;
    reg frame_active = 0;
    reg dec_bit_valid = 0;
    reg dec_bit_value = 0;

    wire [7:0] byte_data;
    wire byte_valid, parity_error;

    integer errors = 0;

    dbb_byte_assembler dut (
        .clk (clk), .rst_n (rst_n), .frame_active (frame_active),
        .dec_bit_valid (dec_bit_valid), .dec_bit_value (dec_bit_value),
        .byte_data (byte_data), .byte_valid (byte_valid), .parity_error (parity_error)
    );

    always #5 clk = ~clk;

    task feed_bit(input v);
        begin
            @(negedge clk);
            dec_bit_valid = 1;
            dec_bit_value = v;
            @(negedge clk);
            dec_bit_valid = 0;
        end
    endtask

    // Feeds 8 data bits LSB-first, then the parity bit
    task feed_byte(input [7:0] data, input parity_bit);
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                feed_bit(data[i]);
            feed_bit(parity_bit);
        end
    endtask

    function correct_odd_parity(input [7:0] data);
        correct_odd_parity = ~(^data);
    endfunction

    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        frame_active = 1;

        // --- Byte 1: 0x65 (01100101, four 1s -> correct parity = 1) ---
        feed_byte(8'h65, correct_odd_parity(8'h65));
        #1;
        if (byte_valid !== 1'b1 || byte_data !== 8'h65 || parity_error !== 1'b0) begin
            $display("[FAIL] byte1: byte_valid=%b byte_data=%h parity_error=%b (expected 1,65,0)",
                       byte_valid, byte_data, parity_error);
            errors = errors + 1;
        end else begin
            $display("[PASS] byte1: 0x65 with correct parity decoded cleanly");
        end

        // --- Byte 2: 0xA3 with deliberately WRONG parity ---
        feed_byte(8'hA3, ~correct_odd_parity(8'hA3));
        #1;
        if (byte_valid !== 1'b1 || byte_data !== 8'hA3 || parity_error !== 1'b1) begin
            $display("[FAIL] byte2: byte_valid=%b byte_data=%h parity_error=%b (expected 1,A3,1)",
                       byte_valid, byte_data, parity_error);
            errors = errors + 1;
        end else begin
            $display("[PASS] byte2: 0xA3 with broken parity correctly flagged parity_error");
        end

        // --- Byte 3: 0x00 (all zeros -> correct parity = 1) ---
        feed_byte(8'h00, correct_odd_parity(8'h00));
        #1;
        if (byte_valid !== 1'b1 || byte_data !== 8'h00 || parity_error !== 1'b0) begin
            $display("[FAIL] byte3: byte_valid=%b byte_data=%h parity_error=%b (expected 1,00,0)",
                       byte_valid, byte_data, parity_error);
            errors = errors + 1;
        end else begin
            $display("[PASS] byte3: 0x00 with correct parity decoded cleanly");
        end

        // --- frame_active drops mid-byte: partial byte must be discarded ---
        feed_bit(1'b1);
        feed_bit(1'b0);
        feed_bit(1'b1);
        @(negedge clk);
        frame_active = 0;   // EOF hit mid-byte
        @(negedge clk);
        frame_active = 1;   // next frame starts
        feed_byte(8'hFF, correct_odd_parity(8'hFF));
        #1;
        if (byte_valid !== 1'b1 || byte_data !== 8'hFF || parity_error !== 1'b0) begin
            $display("[FAIL] post-reset byte: byte_valid=%b byte_data=%h parity_error=%b (expected 1,FF,0)",
                       byte_valid, byte_data, parity_error);
            errors = errors + 1;
        end else begin
            $display("[PASS] bit counter correctly reset when frame_active dropped mid-byte");
        end

        if (errors == 0)
            $display("\n=== tb_dbb_byte_assembler: ALL TESTS PASSED ===\n");
        else
            $display("\n=== tb_dbb_byte_assembler: %0d TEST(S) FAILED ===\n", errors);

        $finish;
    end

endmodule
