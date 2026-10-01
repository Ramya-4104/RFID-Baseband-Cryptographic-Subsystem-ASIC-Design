// =============================================================================
// dbb_byte_framer.v
// Byte-level -> frame-level. Waits for each new completed byte from the
// assembler and writes it into the next open slot of the frame buffer,
// incrementing a byte-count register. On Frame Control FSM's frame_done
// (confirmed EOF), freezes the buffer and raises data_ready. Clears once
// the APB side acknowledges the read, protecting the next frame's bytes
// from overwriting data firmware hasn't consumed yet.
//
// FRAME_BYTES is a parameter, not a hardcoded constant -- default 8 bytes
// matches ADDR_DATA_OUT_0 + ADDR_DATA_OUT_1 (two 32-bit words) in the memory
// map. Per spec, frames are variable-length (start bit + N x [8 data + parity]
// + EOF) -- byte_count reports how many bytes actually arrived so firmware/
// the cipher handoff know how much of the buffer is real payload.
// =============================================================================

module dbb_byte_framer #(
    parameter FRAME_BYTES = 8
)(
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire                             byte_valid,
    input  wire [7:0]                       byte_data,
    input  wire                             parity_error,  // from byte assembler, latched per-frame
    input  wire                             frame_done,    // from Frame Control FSM: EOF confirmed
    input  wire                             frame_abort,   // discard partial frame (timeout/error)
    input  wire                             data_read_ack, // pulse: firmware/cipher consumed the frame

    output reg [FRAME_BYTES*8-1:0]          frame_buf,     // packed frame, byte 0 in bits [7:0]
    output reg [$clog2(FRAME_BYTES+1)-1:0]  byte_count,    // how many bytes actually arrived
    output reg                              frame_parity_error, // sticky: any byte in this frame failed parity
    output reg                              data_ready
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_buf           <= {FRAME_BYTES*8{1'b0}};
            byte_count          <= 0;
            frame_parity_error  <= 1'b0;
            data_ready          <= 1'b0;
        end else begin
            if (data_read_ack) begin
                // Firmware/cipher has consumed the frame -- clear for reuse
                data_ready          <= 1'b0;
                byte_count          <= 0;
                frame_parity_error  <= 1'b0;
            end else if (frame_abort) begin
                byte_count          <= 0;
                frame_parity_error  <= 1'b0;
            end else begin
                if (byte_valid && !data_ready) begin
                    if (parity_error)
                        frame_parity_error <= 1'b1;
                    if (byte_count < FRAME_BYTES) begin
                        frame_buf[byte_count*8 +: 8] <= byte_data;
                        byte_count <= byte_count + 1'b1;
                    end
                    // bytes beyond FRAME_BYTES are silently dropped from the buffer;
                    // byte_count saturates at FRAME_BYTES (won't happen at 106kbit/s
                    // 8-byte frames per current scope, but guarded regardless)
                end
                if (frame_done && !data_ready) begin
                    data_ready <= 1'b1;
                end
            end
        end
    end

endmodule
