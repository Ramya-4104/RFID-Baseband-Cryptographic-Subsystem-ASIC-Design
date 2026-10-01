// =============================================================================
// dbb_loopback_serializer.v
// Mode 1 (DBB Loopback) test path.
//
// {data1,data0} (64 bits) is ALREADY Manchester encoded by firmware:
// 64 line bits = 32 decoded bits = 4 bytes. The serializer does not encode
// the payload. It sends the 64 bits serially, LSB first (data0[0] first),
// one line bit per shift_en strobe, and inserts SOF, parity and EOF:
//
//   SOF(2) | 16 payload bits | P(2) | 16 payload bits | P(2) | ... | EOF(4)
//
// - SOF    : MANCHESTER=1 -> "10",  MANCHESTER=0 -> "01"
// - Parity : odd parity over the 8 decoded bits of each byte, sent as a
//            Manchester symbol (MANCHESTER=1: 1->"10", 0->"01";
//                                MANCHESTER=0: 1->"01", 0->"10")
// - EOF    : "0000"
// - Idle level of bit_out is 0.
// =============================================================================

module dbb_loopback_serializer #(
    parameter PATTERN_BITS = 64            // line bits; must be a multiple of 16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] data0,              // ADDR_DATA_0 (lower 32 bits, sent first)
    input  wire [31:0] data1,              // ADDR_DATA_1 (upper 32 bits)
    input  wire        load,               // pulse: latch {data1,data0}, start frame
    input  wire        shift_en,           // tie to oversampler os_shreg_full

    output wire        bit_out,            // line bit for oversampler bit_in
    output wire        rx_en,              // tie to oversampler enable
    output reg         pattern_done        // pulses on the last EOF bit
);

    localparam MANCHESTER = 1'b1;          // 1: 1->10, 0->01   |   0: 1->01, 0->10

    localparam NUM_BYTES  = PATTERN_BITS / 16;   // 16 line bits = 1 decoded byte

    localparam [2:0] S_IDLE   = 3'd0,
                     S_SOF    = 3'd1,
                     S_DATA   = 3'd2,
                     S_PARITY = 3'd3,
                     S_EOF    = 3'd4;

    reg [2:0]                      state;
    reg [PATTERN_BITS-1:0]         shreg;       // already-encoded payload, LSB sent first
    reg [$clog2(NUM_BYTES+1)-1:0]  bytes_left;
    reg [3:0]                      cnt;         // line-bit index within the current field
    reg                            par_acc; 
    assign rx_en = (state != S_IDLE);     // XOR of decoded bits of current byte

    // ---------------------------------------------------------------------
    // Decoded value of the symbol whose FIRST half is shreg[0]
    //   MANCHESTER=1: first half = value      (10 -> 1, 01 -> 0)
    //   MANCHESTER=0: first half = ~value     (01 -> 1, 10 -> 0)
    // ---------------------------------------------------------------------
    wire dec_bit      = MANCHESTER ? shreg[0] : ~shreg[0]; //notice that this dec bit is wire

    // Odd parity bit and its Manchester symbol (first half, second = inverse)
    wire par_bit      = ~par_acc;
    wire parity_first = MANCHESTER ? par_bit : ~par_bit;

    // ---------------------------------------------------------------------
    // Current line bit
    // ---------------------------------------------------------------------
    reg line_bit;
    always @(*) begin
        case (state)
            S_SOF:    line_bit = cnt[0] ? ~MANCHESTER : MANCHESTER;    // "10" / "01"
            S_DATA:   line_bit = shreg[0];                             // pre-encoded, LSB first
            S_PARITY: line_bit = cnt[0] ? ~parity_first : parity_first;
            S_EOF:    line_bit = 1'b0;                                 // "0000"
            default:  line_bit = 1'b0;                                 // idle
        endcase
    end

    assign bit_out = line_bit;

    // ---------------------------------------------------------------------
    // Sequencer (advances only on shift_en)
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            shreg        <= {PATTERN_BITS{1'b0}};
            bytes_left   <= 0;
            cnt          <= 4'd0;
            par_acc      <= 1'b0;
            pattern_done <= 1'b0;
        end else begin
            pattern_done <= 1'b0;

            if (load) begin
                shreg      <= {data1, data0};
                bytes_left <= NUM_BYTES;
                cnt        <= 4'd0;
                par_acc    <= 1'b0;
                state      <= S_SOF;
            end else if (shift_en) begin
                case (state)
                    // ---------- SOF: 2 line bits ----------
                    S_SOF: begin
                        if (cnt == 4'd1) begin
                            cnt     <= 4'd0;
                            par_acc <= 1'b0;
                            state   <= S_DATA;
                        end else cnt <= cnt + 1'b1;
                    end

                    // ---------- payload: 16 line bits (= 8 decoded bits) ----------
                    S_DATA: begin
                        shreg <= {1'b0, shreg[PATTERN_BITS-1:1]};      // LSB-first
                        if (!cnt[0])                                    // first half of a symbol
                            par_acc <= par_acc ^ dec_bit;
                        if (cnt == 4'd15) begin
                            cnt   <= 4'd0;
                            state <= S_PARITY;
                        end else cnt <= cnt + 1'b1;
                    end

                    // ---------- parity: 2 line bits ----------
                    S_PARITY: begin
                        if (cnt == 4'd1) begin
                            cnt        <= 4'd0;
                            bytes_left <= bytes_left - 1'b1;
                            if (bytes_left == 1) state <= S_EOF;
                            else begin
                                par_acc <= 1'b0;
                                state   <= S_DATA;
                            end
                        end else cnt <= cnt + 1'b1;
                    end

                    // ---------- EOF: 4 line bits of 0 ----------
                    S_EOF: begin
                        if (cnt == 4'd3) begin
                            cnt          <= 4'd0;
                            state        <= S_IDLE;
                            pattern_done <= 1'b1;
                        end else cnt <= cnt + 1'b1;
                    end

                    default: ;
                endcase
            end
        end
    end

endmodule