// =============================================================================
// dbb_sync.v
// 2-flop synchronizer: crosses the async rfid_rx_bit (from the TRF7970A AFE
// envelope detector) into the SoC clock domain. Only used on the Mode 0
// (Live) path -- Mode 1 loopback data is already bus-synchronous and bypasses
// this stage entirely (wired at the dbb_top mux, not here).
// =============================================================================

module dbb_sync (
    input  wire clk,
    input  wire rst_n,
    input  wire async_in,   // rfid_rx_bit, asynchronous to clk
    output reg  sync_out    // synchronized, 2-cycle latency
);

    reg meta_ff;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_ff  <= 1'b0;
            sync_out <= 1'b0;
        end else begin
            meta_ff  <= async_in;  // catches metastability
            sync_out <= meta_ff;   // resolved, safe to use
        end
    end

endmodule
