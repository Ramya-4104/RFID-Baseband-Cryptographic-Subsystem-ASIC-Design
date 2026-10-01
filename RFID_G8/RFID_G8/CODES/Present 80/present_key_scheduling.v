// =============================================================================
// PRESENT-80 key schedule
//
// Timing:
//   start=1 on a rising edge:
//       key_reg <= key_in
//       round_key_out <= K1 = key_in[79:16]
//       active <= 1
//
//   While active:
//       cycle with round_count=N uses current K_N at the output.
//       At the rising edge, the key register is updated to K_(N+1).
//
//   Therefore the encryption core can consume round_key_out on the same
//   cycle it consumes its round counter. K1 is available immediately after
//   the start edge and K32 is held for the final whitening operation.
//
// PRESENT-80 update:
//   1. rotate 80-bit key left by 61:
//          {key[18:0], key[79:19]}
//   2. S-box the leftmost nibble [79:76]
//   3. XOR round counter into [19:15]
// =============================================================================
module present_key_scheduling (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [79:0] key_in,

    output reg  [63:0] round_key_out,
    output reg  [5:0]  round_count,
    output reg         active,
    output reg         done
);

    reg [79:0] key_reg;
    reg [79:0] next_key;

    function [3:0] sbox;
        input [3:0] x;
        begin
            case (x)
                4'h0: sbox = 4'hC;
                4'h1: sbox = 4'h5;
                4'h2: sbox = 4'h6;
                4'h3: sbox = 4'hB;
                4'h4: sbox = 4'h9;
                4'h5: sbox = 4'h0;
                4'h6: sbox = 4'hA;
                4'h7: sbox = 4'hD;
                4'h8: sbox = 4'h3;
                4'h9: sbox = 4'hE;
                4'hA: sbox = 4'hF;
                4'hB: sbox = 4'h8;
                4'hC: sbox = 4'h4;
                4'hD: sbox = 4'h7;
                4'hE: sbox = 4'h1;
                4'hF: sbox = 4'h2;
                default: sbox = 4'h0;
            endcase
        end
    endfunction

    always @(*) begin
        // Rotate left by 61 bits.
        next_key = {key_reg[18:0], key_reg[79:19]};

        // S-box bits 79:76.
        next_key[79:76] = sbox(next_key[79:76]);

        // PRESENT-80 round counter injection.
        // round_count is 1 for K1 -> K2 update, ..., 31 for K31 -> K32.
        next_key[19:15] = next_key[19:15] ^ round_count[4:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_reg       <= 80'b0;
            round_key_out <= 64'b0;
            round_count   <= 6'd0;
            active        <= 1'b0;
            done          <= 1'b0;
        end
        else if (start && !active) begin
            // K1 is the initial 64 MSBs of the supplied 80-bit key.
            key_reg       <= key_in;
            round_key_out <= key_in[79:16];
            round_count   <= 6'd1;
            active        <= 1'b1;
            done          <= 1'b0;
        end
        else if (active) begin
            if (round_count < 6'd32) begin
                // Current output is K_round_count.
                // Advance the stored key so the next cycle presents K_(N+1).
                key_reg       <= next_key;
                round_key_out <= next_key[79:16];
                round_count   <= round_count + 6'd1;
            end
            else begin
                // K32 is now being presented. Hold it for final whitening.
                key_reg     <= key_reg;
                round_key_out <= round_key_out;
                round_count <= round_count;
                active      <= 1'b0;
                done        <= 1'b1;
            end
        end
        else begin
            done <= 1'b0;
        end
    end

endmodule
