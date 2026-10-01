// =============================================================================
// dbb_majority_voter.v
// Once os_shreg fills (os_shreg_full pulses), votes across the samples and
// outputs exactly ONE clean level for that half-bit period -- not a
// continuously sliding vote. Combinational vote, resolved the same cycle
// os_shreg completes; bit_out latches into its own register so nothing is
// lost when os_shreg starts overwriting on the next half-bit.
//
// Votes on the middle 5 of 8 samples (bits 5:1), skipping the two outermost
// samples on each edge of the window -- those are the ones most likely to
// straddle a real transition.
// =============================================================================

module dbb_majority_voter #(
    parameter OSR = 8
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire [OSR-1:0]  os_shreg,
    input  wire            os_shreg_full,  // pulse: os_shreg just completed a window
    output reg             bit_out,        // one clean level per half-bit
    output reg             bit_out_valid   // 1-cycle pulse alongside bit_out
);
    localparam integer VOTE_WIDTH =
        ((OSR - 2) % 2) ? (OSR - 2) : (OSR - 3);
    localparam integer COUNT_WIDTH = $clog2(VOTE_WIDTH + 1);

    reg [COUNT_WIDTH-1:0] ones_count;
    integer i;
    always @* begin
        ones_count = 0;

        for (i = 1; i <= VOTE_WIDTH; i = i + 1)
            ones_count = ones_count + os_shreg[i];
    end

    // Middle-sample vote (assumes OSR == 8; adjust the slice if OSR changes)
    // wire [3:0] ones_count = os_shreg[5] + os_shreg[4] + os_shreg[3] +
    //                          os_shreg[2] + os_shreg[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_out       <= 1'b0;
            bit_out_valid <= 1'b0;
        end else if (os_shreg_full) begin
            //bit_out       <= (ones_count >= 4'd3);  // majority of 5
            bit_out       <= (ones_count >= ((VOTE_WIDTH + 1) / 2));
            bit_out_valid <= 1'b1;
        end else begin
            bit_out_valid <= 1'b0;
        end
    end

endmodule
