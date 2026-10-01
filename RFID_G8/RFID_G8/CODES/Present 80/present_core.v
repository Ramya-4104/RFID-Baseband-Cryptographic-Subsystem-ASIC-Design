// =============================================================================
// PRESENT-80 encryption core
//
// External key interface is now 80 bits. The core owns the key scheduler;
// there is no longer an externally supplied 64-bit round_key.
//
// One encryption:
//   start edge       : latch plaintext and key; scheduler presents K1
//   31 busy cycles   : rounds 1..31 = AddRoundKey -> S -> P
//   final busy cycle : ciphertext = state ^ K32
//
// Latency from the start rising edge to done is 32 clock cycles.
// =============================================================================
module present_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [63:0] plaintext,
    input  wire [79:0] key,

    output reg  [63:0] ciphertext,
    output reg         done,
    output reg         busy
);

    reg [63:0] state_reg;
    reg [5:0]  round_ctr;

    wire [63:0] round_key;
    wire [5:0]  key_round_count;
    wire        key_active;
    wire        key_done;
    wire [63:0] round_state;

    // -----------------------------------------------------------------
    // Integrated PRESENT-80 key scheduler.
    // K1 appears immediately after the start edge.
    // -----------------------------------------------------------------
    present_key_scheduling u_key_schedule (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start && !busy),
        .key_in        (key),
        .round_key_out (round_key),
        .round_count   (key_round_count),
        .active        (key_active),
        .done          (key_done)
    );

    // -----------------------------------------------------------------
    // One regular PRESENT round:
    // AddRoundKey -> S-layer -> P-layer
    // -----------------------------------------------------------------
    present_round u_round (
        .state_in  (state_reg),
        .round_key (round_key),
        .state_out (round_state)
    );

    // Optional debug visibility through hierarchy:
    //   u_key_schedule.key_reg
    //   u_key_schedule.round_key_out
    //   u_key_schedule.round_count
    //   state_reg
    //   round_ctr
    //
    // These are intentionally kept as registers rather than hidden
    // behind opaque logic so they can be inspected in GTKWave/Xcelium.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg  <= 64'b0;
            round_ctr  <= 6'd0;
            ciphertext <= 64'b0;
            done       <= 1'b0;
            busy       <= 1'b0;
        end
        else begin
            done <= 1'b0;

            if (start && !busy) begin
                state_reg <= plaintext;
                round_ctr <= 6'd1;
                ciphertext <= 64'b0;
                busy      <= 1'b1;
            end
            else if (busy) begin
                if (round_ctr <= 6'd31) begin
                    // Round 1..31 uses K1..K31 respectively.
                    state_reg <= round_state;
                    round_ctr <= round_ctr + 6'd1;
                end
                else begin
                    // Final whitening uses K32.
                    ciphertext <= state_reg ^ round_key;
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    round_ctr  <= 6'd0;
                end
            end
        end
    end

endmodule
