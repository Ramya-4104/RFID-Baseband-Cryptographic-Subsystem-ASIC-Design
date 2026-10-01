`timescale 1ns/1ps

// =============================================================================
// tb_dbb_loopback_serializer.v
//
// Self-checking testbench for dbb_loopback_serializer.
//
// Assumptions:
//   - data0/data1 already contain Manchester-encoded line bits.
//   - data0[0] is the FIRST transmitted line bit (LSB first).
//   - PATTERN_BITS = 64 => 4 decoded bytes.
//   - Each decoded byte is represented by 16 Manchester line bits.
//   - Manchester convention: 1 -> 10, 0 -> 01.
//   - Odd parity is inserted by the DUT.
//   - EOF = 0000.
//   - One shift_en strobe advances exactly one line bit.
// =============================================================================

module tb_dbb_loopback_serializer;

    localparam integer PATTERN_BITS      = 64;
    localparam integer HALF_BIT_CYCLES   = 8;   // simulation value
    localparam integer NUM_BYTES         = PATTERN_BITS / 16;
    localparam integer TOTAL_LINE_BITS   = 2 + PATTERN_BITS + (2*NUM_BYTES) + 4;

    reg         clk;
    reg         rst_n;
    reg [31:0]  data0;
    reg [31:0]  data1;
    reg         load;
    reg         shift_en;

    wire        bit_out;
    wire        rx_en;
    wire        pattern_done;

    dbb_loopback_serializer #(
        .PATTERN_BITS(PATTERN_BITS)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .data0        (data0),
        .data1        (data1),
        .load         (load),
        .shift_en     (shift_en),
        .bit_out      (bit_out),
        .rx_en        (rx_en),
        .pattern_done (pattern_done)
    );

    // 10 ns clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Manchester encoder used only by the TB to create the APB contents.
    //
    // For MANCHESTER=1:
    //   decoded 1 -> 10
    //   decoded 0 -> 01
    //
    // IMPORTANT:
    // encoded[0] is the first line bit transmitted.
    // -------------------------------------------------------------------------
    function automatic [15:0] encode_byte;
        input [7:0] b;
        integer k;
        begin
            encode_byte = 16'b0;
            for (k = 0; k < 8; k = k + 1) begin
                if (b[k]) begin
                    encode_byte[2*k]   = 1'b1;
                    encode_byte[2*k+1] = 1'b0;
                end
                else begin
                    encode_byte[2*k]   = 1'b0;
                    encode_byte[2*k+1] = 1'b1;
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Build expected transmitted stream.
    //
    // stream[0] is the FIRST line bit after load.
    // -------------------------------------------------------------------------
    reg [TOTAL_LINE_BITS-1:0] expected_stream;
    reg [63:0] encoded_payload;

    reg [7:0] test_byte [0:NUM_BYTES-1];
    reg       parity;
    integer   i, b, idx;
    integer   errors;

    task automatic build_expected_stream;
        begin
            encoded_payload = 64'b0;

            // Choose four decoded bytes.
            // These are arbitrary nontrivial values to exercise 0/1 transitions.
            test_byte[0] = 8'hA6;
            test_byte[1] = 8'h3D;
            test_byte[2] = 8'hF0;
            test_byte[3] = 8'h59;

            // Construct already-Manchester-encoded APB data:
            // data0[0] is the first transmitted chip.
            for (b = 0; b < NUM_BYTES; b = b + 1)
                encoded_payload[b*16 +: 16] = encode_byte(test_byte[b]);

            data0 = encoded_payload[31:0];
            data1 = encoded_payload[63:32];

            expected_stream = '0;
            idx = 0;

            // SOF = logical 1 -> "10"
            expected_stream[idx] = 1'b1; idx = idx + 1;
            expected_stream[idx] = 1'b0; idx = idx + 1;

            // Payload + parity for each byte.
            for (b = 0; b < NUM_BYTES; b = b + 1) begin

                // 16 already-encoded payload line bits.
                for (i = 0; i < 16; i = i + 1) begin
                    expected_stream[idx] =
                        encoded_payload[b*16 + i];
                    idx = idx + 1;
                end

                // Odd parity:
                // parity bit = NOT XOR(data bits).
                parity = ~(^test_byte[b]);

                if (parity) begin
                    expected_stream[idx] = 1'b1;
                    expected_stream[idx+1] = 1'b0;
                end
                else begin
                    expected_stream[idx] = 1'b0;
                    expected_stream[idx+1] = 1'b1;
                end
                idx = idx + 2;
            end

            // EOF = 0000
            expected_stream[idx]   = 1'b0;
            expected_stream[idx+1] = 1'b0;
            expected_stream[idx+2] = 1'b0;
            expected_stream[idx+3] = 1'b0;

            if (idx + 4 != TOTAL_LINE_BITS) begin
                $display("ERROR: expected stream length construction mismatch");
                $fatal;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Send one shift_en strobe after exactly HALF_BIT_CYCLES clocks.
    //
    // bit_out is checked immediately before the shift edge because the DUT
    // consumes the current line bit at that edge.
    // -------------------------------------------------------------------------
    task automatic check_and_shift;
        input integer n;
        begin
            repeat (HALF_BIT_CYCLES-1) @(posedge clk);

            if (bit_out !== expected_stream[n]) begin
                $display("ERROR at line bit %0d: expected=%b got=%b",
                         n, expected_stream[n], bit_out);
                errors = errors + 1;
            end

            shift_en = 1'b1;
            @(posedge clk);
            shift_en = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test
    // -------------------------------------------------------------------------
    initial begin
        load     = 1'b0;
        shift_en = 1'b0;
        rst_n    = 1'b0;
        data0    = 32'b0;
        data1    = 32'b0;
        errors   = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        build_expected_stream();

        $display("============================================================");
        $display("DBB LOOPBACK SERIALIZER TEST");
        $display("PATTERN_BITS    = %0d", PATTERN_BITS);
        $display("NUM_BYTES      = %0d", NUM_BYTES);
        $display("TOTAL LINE BITS = %0d", TOTAL_LINE_BITS);
        $display("data0          = %08h", data0);
        $display("data1          = %08h", data1);
        $display("============================================================");

        // Load starts the frame.
        @(posedge clk);
        load = 1'b1;
        @(posedge clk);
        load = 1'b0;

        // Immediately after load, serializer should be active.
        #1;
        if (rx_en !== 1'b1) begin
            $display("ERROR: rx_en should be high after load");
            errors = errors + 1;
        end

        // Check every SOF + payload + parity + EOF line bit.
        for (i = 0; i < TOTAL_LINE_BITS; i = i + 1)
            check_and_shift(i);



// After the last EOF bit, serializer must return idle.
if (rx_en !== 1'b0) begin
    $display("ERROR: rx_en should be low after EOF");
    errors = errors + 1;
end

if (pattern_done !== 1'b1) begin
    $display("ERROR: pattern_done should pulse after final EOF bit");
    errors = errors + 1;
end

// pattern_done should only be a pulse.
@(posedge clk);
#1;
if (pattern_done !== 1'b0) begin
    $display("ERROR: pattern_done did not return low");
    errors = errors + 1;
end

        if (errors == 0) begin
            $display("============================================================");
            $display("PASS: serializer transmitted all %0d line bits correctly.",
                     TOTAL_LINE_BITS);
            $display("      SOF + 64 payload chips + 4 parity symbols + EOF");
            $display("============================================================");
        end
        else begin
            $display("============================================================");
            $display("FAIL: %0d errors detected.", errors);
            $display("============================================================");
        end

        $finish;
    end

endmodule
