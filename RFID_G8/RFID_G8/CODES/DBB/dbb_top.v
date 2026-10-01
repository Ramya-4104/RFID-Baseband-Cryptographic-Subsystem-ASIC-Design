// =============================================================================
// dbb_top.v
//
// Digital Baseband top-level.
//
// Mode 0 (Live):
//     rfid_rx_bit -> synchronizer -> oversampler -> majority voter
//     -> Manchester decoder -> frame control -> byte assembler
//     -> byte framer -> cipher_data_in
//
// Mode 1 (DBB Loopback):
//     lb_data0/1 -> loopback serializer -> DBB receive path
//     -> frame_data_out0/1 + data_ready
//
// Mode 2 (Crypto Loopback):
//     Not processed by this block.
//
// =============================================================================

    //wire           os_shreg_full;
module dbb_top #(
    parameter OSR             = 8,
    parameter HALF_BIT_CYCLES = 236,
    parameter FRAME_BYTES     = 8,
    parameter MAX_FRAME_BITS  = 512
)(
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------------------
    // Mode select
    //
    // 0 = Live
    // 1 = DBB Loopback
    // 2 = Crypto Loopback
    // ------------------------------------------------------------
    input  wire [1:0]  mode_sel,

    // ------------------------------------------------------------
    // Mode 0: live RF input
    // ------------------------------------------------------------
    input  wire        rfid_rx_bit,

    // ------------------------------------------------------------
    // Mode 1: loopback input
    // ------------------------------------------------------------
    input  wire [31:0] lb_data0,
    input  wire [31:0] lb_data1,
    input  wire        lb_load,

    // ------------------------------------------------------------
    // Frame output
    // ------------------------------------------------------------
    output wire [31:0] frame_data_out0,
    output wire [31:0] frame_data_out1,

    output wire        data_ready,

    input  wire        data_read_ack,

    // ------------------------------------------------------------
    // Mode 0 cipher interface
    // ------------------------------------------------------------
    output wire [63:0] cipher_data_in,
    output wire        cipher_data_valid,

    // ------------------------------------------------------------
    // Frame error
    // ------------------------------------------------------------
    output wire        frame_parity_error,

    // ------------------------------------------------------------
    // TX output
    // ------------------------------------------------------------
    output wire        rfid_tx_bit
);

    // FIX: nets used before their declaration (or implicitly) are declared here
    wire       os_shreg_full;
    wire       lb_bit;
    wire       mode1_enable;
    wire       rx_rst_n;
    wire       align;

    // ============================================================
    // TX PATH
    // ============================================================

    // No TX path in current scope.
    assign rfid_tx_bit = 1'b0;


    // ============================================================
    // MODE 0
    // Synchronizer
    // ============================================================

    wire rx_sync;

    dbb_sync u_sync (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (rfid_rx_bit),
        .sync_out (rx_sync)
    );


    

    wire oversampler_enable;
    assign oversampler_enable = mode_sel ? mode1_enable : 1'b1;


    // ============================================================
    // Select input to oversampler
    //
    // Mode 0 -> synchronized RF input
    // Mode 1 -> loopback serializer output
    // Mode 2 -> RF path is selected here, but downstream outputs
    //           are disabled by the mode logic.
    // ============================================================

    wire osr_bit_in;

    assign osr_bit_in =
        (mode_sel == 2'd1) ? lb_bit : rx_sync;


    // ============================================================
    // OVERSAMPLER
    // ============================================================

    wire [OSR-1:0] os_shreg;
    //wire           os_strobe;

    dbb_oversampler #(
        .OSR             (OSR),
        .HALF_BIT_CYCLES (HALF_BIT_CYCLES)
    ) u_osr (
        .clk           (clk),
        .rst_n         (rx_rst_n),
        .bit_in        (osr_bit_in),
        .enable        (oversampler_enable),
        .os_shreg      (os_shreg),
        .os_shreg_full (os_shreg_full)
        //.strobe_out    (os_strobe)
    );


    // ============================================================
    // MAJORITY VOTER
    // ============================================================

    wire bit_out;
    wire bit_out_valid;

    dbb_majority_voter #(
        .OSR (OSR)
    ) u_vote (
        .clk           (clk),
        .rst_n         (rx_rst_n),
        .os_shreg      (os_shreg),
        .os_shreg_full (os_shreg_full),
        .bit_out       (bit_out),
        .bit_out_valid (bit_out_valid)
    );


    // ============================================================
    // MANCHESTER DECODER
    // ============================================================

    wire dec_bit_value;
    wire dec_bit_valid;
    wire dec_unit_done;
    //wire align;


    dbb_manchester_decoder u_dec (
        .clk           (clk),
        .rst_n         (rx_rst_n),
        .bit_out       (bit_out),
        .bit_out_valid (bit_out_valid),
        .align_load    (align),


        .bit_value     (dec_bit_value),
        .bit_valid     (dec_bit_valid),
        .unit_done     (dec_unit_done)
    );


    // ============================================================
    // FRAME CONTROL FSM
    //
    // Current dbb_frame_ctrl_fsm interface:
    //
    // Inputs:
    //     clk
    //     rst_n
    //     bit_out_valid
    //     dec_unit_done
    //     dec_bit_valid
    //     dec_bit_value
    //
    // Outputs:
    //     frame_active
    //     frame_done
    //     frame_abort
    // ============================================================

    wire frame_active;
    wire frame_done;
    wire frame_abort;

    dbb_frame_ctrl_fsm #(
        .EOF_CONFIRM_UNITS (2),
        .MAX_FRAME_BITS    (MAX_FRAME_BITS)
    ) u_fsm (
        .clk           (clk),
        .rst_n         (rx_rst_n),

        .bit_out       (bit_out),        // FIX: was left unconnected (floating -> FSM never leaves IDLE)
        .bit_out_valid (bit_out_valid),  // FIX: was left unconnected

        .dec_unit_done (dec_unit_done),
        .dec_bit_valid (dec_bit_valid),
        .dec_bit_value (dec_bit_value),


        .frame_active  (frame_active),
        .align_load    (align),
        .frame_done    (frame_done),
        .frame_abort   (frame_abort)
    );


    // ============================================================
    // BYTE ASSEMBLER
    // ============================================================

    wire [7:0] byte_data;
    wire       byte_valid;
    wire       byte_parity_error;

    dbb_byte_assembler u_asm (
        .clk           (clk),
        .rst_n         (rx_rst_n),

        .frame_active  (frame_active),

        .dec_bit_valid (dec_bit_valid),
        .dec_bit_value (dec_bit_value),

        .byte_data     (byte_data),
        .byte_valid    (byte_valid),
        .parity_error  (byte_parity_error)
    );


    // ============================================================
    // BYTE FRAMER
    // ============================================================

    wire [FRAME_BYTES*8-1:0] frame_buf;
    wire                     data_ready_int;
    wire framer_ack;
    wire [$clog2(FRAME_BYTES+1)-1:0] byte_count;   // FIX: was 1 bit wide

    // ------------------------------------------------------------
    // Mode 0:
    // Automatically acknowledge the frame once data is ready.
    //
    // Mode 1:
    // Wait for APB-side data_read_ack.
    // ------------------------------------------------------------


    

    //wire auto_ack_mode0;

    


    dbb_byte_framer #(
        .FRAME_BYTES (FRAME_BYTES)
    ) u_framer (
        .clk                (clk),
        .rst_n              (rst_n),

        .byte_valid         (byte_valid),
        .byte_data          (byte_data),
        .parity_error       (byte_parity_error),

        .frame_done         (frame_done),
        .frame_abort        (frame_abort),

        .data_read_ack      (framer_ack),

        .frame_buf          (frame_buf),
        .byte_count         (byte_count),
        .frame_parity_error (frame_parity_error),
        .data_ready         (data_ready_int)
    );



    // ============================================================
    // MODE 1
    // Loopback serializer
    // ============================================================

    dbb_loopback_serializer #(
        .PATTERN_BITS (FRAME_BYTES * 8)
    ) u_lb_ser (
        .clk         (clk),
        .rst_n        (rst_n),
        .data0       (lb_data0),
        .data1       (lb_data1),
        .load        (lb_load),
        .shift_en    (os_shreg_full),
        .bit_out     (lb_bit),
        .pattern_done(),
        .rx_en       (mode1_enable)   // FIX: port is named rx_en, not enable
    );


    reg [1:0] mode_prev;
    reg       flush_q;

    always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 
        mode_prev <= 2'd0;
        flush_q   <= 1'b0;
    end 
    else begin       
        mode_prev <= mode_sel;
        flush_q   <= (mode_sel != mode_prev);
        
    end
    end // FIX: 'always' block was never closed

    wire mode_changed = (mode_sel != mode_prev);
    assign rx_rst_n = rst_n & ~flush_q;   // FIX: declared up-front, driven here

    wire auto_ack_mode0 = (mode_sel == 2'd0) && data_ready_int && !mode_changed && !flush_q;

    

   assign framer_ack        = data_read_ack | auto_ack_mode0 | mode_changed | flush_q;


    // ============================================================
    // OUTPUT ROUTING
    // ============================================================

    // Mode 1 -> APB readable output registers
    assign frame_data_out0 =
        frame_buf[31:0];

    assign frame_data_out1 =
        frame_buf[63:32];

    assign data_ready = mode_sel & data_ready_int ;


    // Mode 0 -> cipher datapath
    assign cipher_data_in =
        frame_buf[63:0];

    // One-cycle indication when Mode 0 frame is consumed.
    assign cipher_data_valid =
        (byte_count== FRAME_BYTES) & auto_ack_mode0;

endmodule