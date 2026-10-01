// =============================================================================
// dbb_byte_assembler.v
// Consumes gated payload bits only while Frame Control FSM asserts
// frame_active -- nothing before SOF, nothing after EOF. Shifts each decoded
// bit into an 8-bit register, LSB-first (ISO 14443A convention). After 8 data
// bits, treats the 9th incoming bit as odd parity and checks it against a
// locally computed XOR of the byte.
//
// Scope note: anti-collision / 7-bit short-frame handling is explicitly out
// of scope for this DBB block per spec, so every unit is the standard
// 8 data + 1 parity (9 bit-period) shape -- no mode flag needed here.
// =============================================================================

module dbb_byte_assembler (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       frame_active,   // from Frame Control FSM -- gates consumption
    input  wire       dec_bit_valid,  // pulse: new decoded payload bit available
    input  wire       dec_bit_value,

    output reg [7:0]  byte_data,
    output reg        byte_valid,     // 1-cycle pulse: byte_data is a completed, parity-checked byte
    output reg        parity_error    // pulses alongside byte_valid if odd parity failed
);

    reg [3:0] bit_cnt;   // counts bits within the current 9-bit unit (0..8)
    reg [7:0] shreg;     // LSB-first shift register for the 8 data bits

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt      <= 0;
            shreg        <= 8'h00;
            byte_data    <= 8'h00;
            byte_valid   <= 1'b0;
            parity_error <= 1'b0;
        end else if (!frame_active) begin
            // Not receiving -- hold reset between frames, nothing before SOF/after EOF
            bit_cnt    <= 0;
            byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            if (dec_bit_valid) begin
                if (bit_cnt < 8) begin
                    shreg   <= {dec_bit_value, shreg[7:1]};  // LSB-first
                    bit_cnt <= bit_cnt + 1'b1;
                end else begin
                    // 9th bit: odd parity -- total 1-count (byte + parity) must be odd
                    parity_error <= (^shreg == dec_bit_value);  // even total 1s -> parity fails
                    byte_data    <= shreg;
                    byte_valid   <= 1'b1;
                    bit_cnt      <= 0;
                end
            end
        end
    end

endmodule
