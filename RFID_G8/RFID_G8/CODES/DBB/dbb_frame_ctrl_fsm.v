// ===========================================================================
// dbb_frame_ctrl_fsm  (v3 -- idle-polarity-agnostic SOF detection)
// ---------------------------------------------------------------------------
// SOF = raw half-bit pattern "1,0" (Manchester ON->OFF), found directly on
// bit_out/bit_out_valid -- NOT on a level change. This works regardless of
// whether the line idles at 0 or 1:
//   idle=1: every idle sample IS a "1", so `armed` just keeps re-latching
//           on every idle cycle (sliding the candidate forward) until the
//           real "0" finally arrives -- the LAST idle "1" becomes h1.
//   idle=0: `armed` stays 0 harmlessly through idle; the first real "1" is
//           unambiguous and latches immediately.
//
// TIMING CARE (this is the part that bites you if you're not careful):
//   armed is tracked HERE, off the raw bit_out/bit_out_valid, in lockstep
//   with the decoder's own phase register -- NOT off the decoder's
//   registered bit_valid/unit_done, which lag by one cycle. If the SOF
//   decision used those lagged signals, align_load could still be
//   asserted (state==IDLE) on the cycle the first payload bit's raw
//   sample arrives, re-arming the decoder on live payload data instead of
//   letting normal phase toggling take over. Using local `armed` lets the
//   FSM leave IDLE (and therefore silence align_load) on the exact same
//   cycle the confirming "0" arrives -- no race.
//
//   A second, separate one-cycle state (SOF_WAIT) absorbs the SOF pair's
//   own dec_unit_done/dec_bit_valid pulse while frame_active is still low,
//   so the byte assembler never sees the SOF bit itself as payload. This
//   is a different concern from the align_load race above and needs its
//   own cycle of slack.
// ===========================================================================
module dbb_frame_ctrl_fsm #(
    parameter EOF_CONFIRM_UNITS = 2,
    parameter MAX_FRAME_BITS    = 512
)(
    input  wire clk,
    input  wire rst_n,

    input  wire bit_out,          // raw voted half-bit level, from majority voter -- IDLE search only
    input  wire bit_out_valid,    // pulse: bit_out is fresh -- IDLE search only

    input  wire dec_unit_done,
    input  wire dec_bit_valid,
    input  wire dec_bit_value,

    output wire align_load,       // to decoder -- "(re)latch this sample as half1"
    output reg  frame_active,
    output reg  frame_done,
    output reg  frame_abort
);

    localparam IDLE        = 3'd0;
    localparam SOF_WAIT    = 3'd1;   // 1-cycle buffer: absorbs SOF's own decode pulse
    localparam RECEIVING   = 3'd2;
    localparam EOF_CONFIRM = 3'd3;
    localparam FRAME_DONE  = 3'd4;

    reg [2:0] state;
    reg       armed;   // SOF search candidate: "last raw sample seen was a 1"
    reg [$clog2(EOF_CONFIRM_UNITS+1)-1:0] eof_cnt;
    reg [$clog2(MAX_FRAME_BITS+1)-1:0]    frame_bit_cnt;

    // Combinational -- must land the SAME cycle as the qualifying raw "1"
    // sample so the decoder can (re)load it instead of dropping it.
    assign align_load = (state == IDLE) && bit_out_valid && bit_out;            

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            armed         <= 1'b0;
            frame_active  <= 1'b0;
            frame_done    <= 1'b0;
            frame_abort   <= 1'b0;
            eof_cnt       <= 0;
            frame_bit_cnt <= 0;
        end else begin
            frame_done  <= 1'b0;
            frame_abort <= 1'b0;

            case (state)
                // -----------------------------------------------------
                IDLE: begin
                    frame_active  <= 1'b0;
                    frame_bit_cnt <= 0;
                    eof_cnt       <= 0;
                    if (bit_out_valid) begin
                        if (bit_out) begin
                            armed <= 1'b1;          // (re)arm on every raw '1' -- Case 1 & 2
                        end else if (armed) begin
                            // armed('1') then this sample is '0' -> SOF complete
                            state <= SOF_WAIT;
                            armed <= 1'b0;
                        end
                        // else: unarmed and still 0 -> keep waiting (Case 2)
                    end
                end // FIX: removed stray 'end' left behind by the commented-out 'else begin'

                // -----------------------------------------------------
                SOF_WAIT: begin
                    // Absorbs the SOF pair's own dec_unit_done/dec_bit_valid
                    // (visible THIS cycle) with frame_active still low, so
                    // the byte assembler never ingests the SOF bit itself.
                    state         <= RECEIVING;
                    //frame_active  <= 1'b1;
                    frame_bit_cnt <= 0;
                    eof_cnt       <= 0;
                end

                // -----------------------------------------------------
                RECEIVING: begin
                    frame_active <= 1'b1;
                    if (dec_unit_done) begin
                        if (dec_bit_valid) begin
                            eof_cnt <= 0;
                            if (frame_bit_cnt == MAX_FRAME_BITS-1) begin
                                state        <= IDLE;
                                frame_active <= 1'b0;
                                frame_abort  <= 1'b1;
                            end else begin
                                frame_bit_cnt <= frame_bit_cnt + 1'b1;
                            end
                        end else begin
                            state   <= EOF_CONFIRM;
                            eof_cnt <= 1;
                        end
                    end
                end

                // -----------------------------------------------------
                EOF_CONFIRM: begin
                    frame_active <= 1'b1;
                    if (dec_unit_done) begin
                        if (!dec_bit_valid) begin
                            if (eof_cnt == EOF_CONFIRM_UNITS-1) begin
                                state        <= FRAME_DONE;
                                frame_active <= 1'b0;
                            end else begin
                                eof_cnt <= eof_cnt + 1'b1;
                            end
                        end else begin
                            state   <= RECEIVING;
                            eof_cnt <= 0;
                            if (frame_bit_cnt == MAX_FRAME_BITS-1) begin
                                state        <= IDLE;
                                frame_active <= 1'b0;
                                frame_abort  <= 1'b1;
                            end else begin
                                frame_bit_cnt <= frame_bit_cnt + 1'b1;
                            end
                        end
                    end
                end

                // -----------------------------------------------------
                FRAME_DONE: begin
                    frame_done   <= 1'b1;
                    frame_active <= 1'b0;
                    state        <= IDLE;
                end

                default: begin
                    state        <= IDLE;
                    frame_active <= 1'b0;
                end
            endcase
        end
    end

endmodule
