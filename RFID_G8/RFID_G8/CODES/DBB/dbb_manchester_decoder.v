// ===========================================================================
// dbb_manchester_decoder  (v3 -- align_load only, no transition_seen needed)
// ---------------------------------------------------------------------------
// Same "capture, don't discard" fix as before: align_load means "load this
// sample as half1 of a fresh pair" rather than resetting and dropping it.
// The FSM now drives align_load directly off the raw bit_out/bit_out_valid
// pattern (see dbb_frame_ctrl_fsm v3), so this module no longer needs to
// compute transition_seen itself -- it just needs to obey align_load.
// ===========================================================================
module dbb_manchester_decoder (
    input  wire clk,
    input  wire rst_n,

    input  wire bit_out,
    input  wire bit_out_valid,
    input  wire align_load,       // FSM: "this sample is half1 of a fresh pair" (SOF search only)

    output reg  bit_value,
    output reg  bit_valid,
    output reg  unit_done
);

    reg half1_level;
    reg phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half1_level <= 1'b0;
            phase       <= 1'b0;
            bit_value   <= 1'b0;
            bit_valid   <= 1'b0;
            unit_done   <= 1'b0;
        end else if (bit_out_valid) begin
            if (align_load) begin
                half1_level <= bit_out;
                phase       <= 1'b1;
                bit_valid   <= 1'b0;
                unit_done   <= 1'b0;
            end else if (!phase) begin
                half1_level <= bit_out;
                phase       <= 1'b1;
                bit_valid   <= 1'b0;
                unit_done   <= 1'b0;
            end else begin
                phase     <= 1'b0;
                unit_done <= 1'b1;
                case ({half1_level, bit_out})
                    2'b10:   begin bit_value <= 1'b1; bit_valid <= 1'b1; end
                    2'b01:   begin bit_value <= 1'b0; bit_valid <= 1'b1; end
                    default: begin bit_value <= 1'b0; bit_valid <= 1'b0; end
                endcase
            end
        end else begin
            bit_valid <= 1'b0;
            unit_done <= 1'b0;
        end
    end

endmodule
