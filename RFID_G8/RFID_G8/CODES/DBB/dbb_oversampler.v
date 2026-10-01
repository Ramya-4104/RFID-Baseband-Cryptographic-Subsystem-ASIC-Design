// =============================================================================
// dbb_oversampler.v
//
// Fixed-rate oversampler for ISO/IEC 14443A Type A, 106 kbit/s Manchester.
//
// Clock:
//     50 MHz
//
// Half-bit:
//     HALF_BIT_CYCLES = 236 clocks
//
// Oversampling:
//     OSR = 8 samples / half-bit
//
// Since:
//     236 / 8 = 29.5 clocks/sample
//
// We distribute the remainder using:
//
//     29, 30, 29, 30, 29, 30, 29, 30
//
// Total:
//     29 + 30 + 29 + 30 + 29 + 30 + 29 + 30 = 236 clocks
//
// Interface:
//     os_shreg       : 8 most-recently sampled bits
//     os_shreg_full  : 1-clock pulse after the 8th sample
//     strobe_out     : 1-clock pulse whenever a sample is taken
//
// =============================================================================

module dbb_oversampler #(
    parameter OSR             = 8,
    parameter HALF_BIT_CYCLES = 236
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             bit_in,
    input  wire             enable,

    output reg  [OSR-1:0]   os_shreg,
    output reg              os_shreg_full,
    output reg              strobe_out
);

    // =========================================================================
    // Basic parameters
    // =========================================================================

    localparam integer BASE_PERIOD = HALF_BIT_CYCLES / OSR;
    localparam integer REMAINDER   = HALF_BIT_CYCLES % OSR;

    // Counter for clocks inside the current sample interval.
    reg [$clog2(BASE_PERIOD + 1)-1:0] strobe_cnt;

    // Number of samples already collected in the current half-bit.
    //
    // 0 -> before sample 1
    // 1 -> before sample 2
    // ...
    // 7 -> before sample 8
    //
    // After sample 8 it returns to 0.
    reg [$clog2(OSR)-1:0] sample_cnt;

    // Remainder accumulator.
    //
    // Used to distribute the extra clocks caused by:
    //
    //     HALF_BIT_CYCLES % OSR
    //
    // For 236 / 8:
    //
    //     BASE_PERIOD = 29
    //     REMAINDER   = 4
    //
    // This generates:
    //
    //     29, 30, 29, 30, 29, 30, 29, 30
    //
    reg [$clog2(OSR+1)-1:0] remainder_acc;

    // Current interval length.
    //
    // This value stays constant during a sample interval because
    // remainder_acc only changes when a sample is taken.
    wire [31:0] current_period;

    assign current_period =
        ((remainder_acc + REMAINDER) >= OSR) ?
        (BASE_PERIOD + 1) :
        BASE_PERIOD;


    // =========================================================================
    // Main oversampler
    // =========================================================================
    //
    // Everything is handled in ONE clocked block.
    //
    // This is important because we don't want to generate a registered
    // strobe_out in one always block and then consume the OLD value of
    // strobe_out in another always block.
    //
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            strobe_cnt    <= 0;
            sample_cnt    <= 0;
            remainder_acc <= 0;

            os_shreg      <= {OSR{1'b0}};
            os_shreg_full <= 1'b0;
            strobe_out    <= 1'b0;

        end

        else if (!enable) begin

            strobe_cnt    <= 0;
            sample_cnt    <= 0;
            remainder_acc <= 0;

            os_shreg      <= {OSR{1'b0}};
            os_shreg_full <= 1'b0;
            strobe_out    <= 1'b0;

        end

        else begin

            // -------------------------------------------------------------
            // Default values.
            //
            // Both strobe_out and os_shreg_full are pulses.
            // Therefore they are cleared every clock and asserted only
            // when their corresponding event occurs.
            // -------------------------------------------------------------

            strobe_out    <= 1'b0;
            os_shreg_full <= 1'b0;


            // -------------------------------------------------------------
            // Wait for the current sample interval to complete.
            // -------------------------------------------------------------

            if (strobe_cnt == current_period - 1) begin

                // ---------------------------------------------------------
                // SAMPLE EVENT
                // ---------------------------------------------------------
                //
                // Generate a one-clock sampling strobe.
                // ---------------------------------------------------------

                strobe_out <= 1'b1;

                // Restart the clock counter for the next sample.
                strobe_cnt <= 0;


                // ---------------------------------------------------------
                // Capture the new sample.
                // ---------------------------------------------------------
                //
                // Old:
                //
                //     [b7 b6 b5 b4 b3 b2 b1]
                //
                // New bit enters at bit 0.
                //
                //     [b6 b5 b4 b3 b2 b1 NEW]
                //
                // ---------------------------------------------------------

                os_shreg <= {
                    os_shreg[OSR-2:0],
                    bit_in
                };


                // ---------------------------------------------------------
                // Check whether this was the 8th sample.
                // ---------------------------------------------------------

                if (sample_cnt == OSR-1) begin

                    // -----------------------------------------------------
                    // OSR-th sample completed.
                    //
                    // This is exactly ONE clock pulse.
                    // -----------------------------------------------------

                    os_shreg_full <= 1'b1;

                    // Start collecting the next half-bit.
                    sample_cnt <= 0;

                end

                else begin

                    // Continue collecting samples.
                    sample_cnt <= sample_cnt + 1'b1;

                end


                // ---------------------------------------------------------
                // Update remainder accumulator.
                //
                // For 236 / 8:
                //
                // Start:
                // remainder_acc = 0
                //
                // sample 1 -> 29 clocks
                // remainder_acc = 4
                //
                // sample 2 -> 30 clocks
                // remainder_acc = 0
                //
                // sample 3 -> 29 clocks
                // remainder_acc = 4
                //
                // ...
                //
                // Therefore:
                //
                // 29,30,29,30,29,30,29,30
                //
                // ---------------------------------------------------------

                if ((remainder_acc + REMAINDER) >= OSR)
                    remainder_acc <= remainder_acc + REMAINDER - OSR;
                else
                    remainder_acc <= remainder_acc + REMAINDER;

            end

            else begin

                // No sample yet.
                strobe_cnt <= strobe_cnt + 1'b1;

            end

        end

    end

endmodule