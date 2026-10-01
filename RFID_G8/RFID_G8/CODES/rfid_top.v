// ============================================================================
// crypto_rfid_top.v
//
// Top level of the Baseband & Cryptographic Subsystem.
// Contains the APB slave logic (address decode, register file, wait-state
// handshake), the Mode 0/1/2 data muxes, and instantiates the DBB and the
// PRESENT-80 cipher core.
//
// Modes (CTRL_REG[1:0]):
//   0 - Live            : rfid_rx_bit -> DBB -> PRESENT-80 -> DATA_OUT
//   1 - DBB loopback    : DATA_0/1 -> DBB replay -> DATA_OUT
//   2 - Crypto loopback : DATA_0/1 -> PRESENT-80 -> DATA_OUT
//
// rfid_tx_bit is unused and tied to 0.
// ============================================================================

module crypto_rfid_top (
    input  wire        clk,
    input  wire        rst_n,

    // APB slave interface
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,

    // External RF interface
    input  wire        rfid_rx_bit,
    output wire        rfid_tx_bit
);

    // ------------------------------------------------------------------
    // 1. Register map and mode encoding
    // ------------------------------------------------------------------
    localparam ADDR_CTRL_REG    = 32'h00;
    localparam ADDR_STATUS_REG  = 32'h04;
    localparam ADDR_KEY_0       = 32'h08;
    localparam ADDR_KEY_1       = 32'h0C;
    localparam ADDR_KEY_2       = 32'h10;
    localparam ADDR_DATA_0      = 32'h14;
    localparam ADDR_DATA_1      = 32'h18;
    localparam ADDR_DATA_OUT_0  = 32'h1C;
    localparam ADDR_DATA_OUT_1  = 32'h20;

    localparam MODE_LIVE            = 2'd0;
    localparam MODE_DBB_LOOPBACK    = 2'd1;
    localparam MODE_CRYPTO_LOOPBACK = 2'd2;

    // ------------------------------------------------------------------
    // 2. Storage registers
    // ------------------------------------------------------------------
    reg [1:0]  ctrl_reg;
    reg [31:0] key0_reg, key1_reg;
    reg [15:0] key2_reg;
    reg [31:0] data0_reg, data1_reg;
    reg [63:0] data_out_reg;

    // ------------------------------------------------------------------
    // 3. Sub-module interface signals
    // ------------------------------------------------------------------
    // DBB
    wire [63:0] dbb_cipher_data_in;    // Mode 0: block handed to the cipher
    wire        dbb_cipher_data_valid; // 1-cycle pulse qualifying the block
    wire [31:0] dbb_frame_out0;        // Mode 1: decoded word, low half
    wire [31:0] dbb_frame_out1;        // Mode 1: decoded word, high half
    wire        dbb_data_ready;        // Mode 1: sticky until data_read_ack
    wire        dbb_frame_parity_err;  // Sticky frame parity fault
    wire        dbb_tx_bit_unused;     // DBB tx_bit, left unconnected

    // PRESENT-80
    wire [79:0] cipher_key = {key2_reg, key1_reg, key0_reg};
    reg  [63:0] cipher_data_in;
    wire        cipher_start;
    wire [63:0] cipher_data_out;
    wire        cipher_done;
    wire        cipher_busy;

    // ------------------------------------------------------------------
    // 4. APB transfer decode
    // ------------------------------------------------------------------
    wire apb_write_xfer = psel & penable & pwrite;
    wire apb_read_xfer  = psel & penable & ~pwrite;

    wire sel_ctrl     = (paddr == ADDR_CTRL_REG);
    wire sel_status   = (paddr == ADDR_STATUS_REG);
    wire sel_key0     = (paddr == ADDR_KEY_0);
    wire sel_key1     = (paddr == ADDR_KEY_1);
    wire sel_key2     = (paddr == ADDR_KEY_2);
    wire sel_data0    = (paddr == ADDR_DATA_0);
    wire sel_data1    = (paddr == ADDR_DATA_1);
    wire sel_dataout1 = (paddr == ADDR_DATA_OUT_1);

    // ------------------------------------------------------------------
    // 5. Mode 1 replay-busy tracking
    // ------------------------------------------------------------------
    // The DBB has no busy output, so busy is tracked here from lb_load_req
    // until the rising edge of data_ready. The edge (not the level) is used
    // because data_ready is sticky and may still be high from an un-acked
    // previous result.
    reg dbb_data_ready_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) dbb_data_ready_d <= 1'b0;
        else        dbb_data_ready_d <= dbb_data_ready;
    end
    wire dbb_data_ready_rise = dbb_data_ready && !dbb_data_ready_d;

    reg dbb_replay_busy;   // driven in Section 8

    // ------------------------------------------------------------------
    // 6. Write locks and APB wait states
    // ------------------------------------------------------------------
    // Registers feeding an active block cannot be modified until it finishes.
    // KEY_x feed the cipher in Modes 0 and 2.
    wire key_locked = cipher_busy;

    // DATA_0/1 feed the DBB in Mode 1 and the cipher in Mode 2.
    wire data_locked =
        (ctrl_reg == MODE_DBB_LOOPBACK    && dbb_replay_busy) ||
        (ctrl_reg == MODE_CRYPTO_LOOPBACK && cipher_busy);

    // Mode cannot change while any block is active.
    wire ctrl_locked = cipher_busy || dbb_replay_busy;

    // A write to a locked register stalls until the lock is released.
    wire write_must_stall =
        apb_write_xfer && (
            (sel_ctrl                           && ctrl_locked) ||
            ((sel_key0 || sel_key1 || sel_key2) && key_locked)  ||
            ((sel_data0 || sel_data1)           && data_locked)
        );

    assign pready = ~write_must_stall;

    // Write enables complete only when pready is high.
    wire wen_ctrl  = apb_write_xfer & sel_ctrl  & pready;
    wire wen_key0  = apb_write_xfer & sel_key0  & pready;
    wire wen_key1  = apb_write_xfer & sel_key1  & pready;
    wire wen_key2  = apb_write_xfer & sel_key2  & pready;
    wire wen_data0 = apb_write_xfer & sel_data0 & pready;
    wire wen_data1 = apb_write_xfer & sel_data1 & pready;

    // ------------------------------------------------------------------
    // 7. Register writes
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg  <= MODE_LIVE;
            key0_reg  <= 32'd0;
            key1_reg  <= 32'd0;
            key2_reg  <= 16'd0;
            data0_reg <= 32'd0;
            data1_reg <= 32'd0;
        end else begin
            if (wen_ctrl)  ctrl_reg  <= pwdata[1:0];
            if (wen_key0)  key0_reg  <= pwdata;
            if (wen_key1)  key1_reg  <= pwdata;
            if (wen_key2)  key2_reg  <= pwdata[15:0];
            if (wen_data0) data0_reg <= pwdata;
            if (wen_data1) data1_reg <= pwdata;
        end
    end

    // ------------------------------------------------------------------
    // 8. DBB handshake: lb_load, replay-busy, data_read_ack
    // ------------------------------------------------------------------
    // A DATA_1 write in Mode 1 requests a DBB replay. lb_load is delayed by
    // one cycle so the DBB sees the newly written DATA_0/1 values.
    wire lb_load_req = wen_data1 && (ctrl_reg == MODE_DBB_LOOPBACK);
    reg  lb_load;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lb_load <= 1'b0;
        else        lb_load <= lb_load_req;
    end

    // Replay timeout: clears busy if data_ready never rises, so the APB bus
    // cannot stall indefinitely. A full replay takes ~15.6k cycles
    // (64 bits * 236 cycles/half-bit + EOF silence); the limit is ~4x that.
    // Rescale if HALF_BIT_CYCLES or the pattern length changes.
    localparam REPLAY_TIMEOUT_CYCLES = 65535;
    reg [15:0] replay_timer;
    reg        dbb_replay_timed_out;   // sticky diagnostic, debug use only
    wire       replay_timeout = dbb_replay_busy && (replay_timer == REPLAY_TIMEOUT_CYCLES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 replay_timer <= 16'd0;
        else if (!dbb_replay_busy)  replay_timer <= 16'd0;
        else                        replay_timer <= replay_timer + 16'd1;
    end

    // Busy is set on the undelayed request so the lock takes effect
    // immediately; cleared on completion or timeout.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbb_replay_busy      <= 1'b0;
            dbb_replay_timed_out <= 1'b0;
        end else if (lb_load_req) begin
            dbb_replay_busy      <= 1'b1;
            dbb_replay_timed_out <= 1'b0;
        end else if (dbb_data_ready_rise) begin
            dbb_replay_busy      <= 1'b0;
        end else if (replay_timeout) begin
            dbb_replay_busy      <= 1'b0;
            dbb_replay_timed_out <= 1'b1;
        end
    end

    // Ack the DBB result on a DATA_OUT_1 read (Mode 1). Assumes firmware
    // reads DATA_OUT_0 before DATA_OUT_1.
    wire data_read_ack = apb_read_xfer && sel_dataout1 && (ctrl_reg == MODE_DBB_LOOPBACK);

    // ------------------------------------------------------------------
    // 9. Cipher input select (Mode 0: DBB block, otherwise DATA_0/1)
    // ------------------------------------------------------------------
    always @(*) begin
        case (ctrl_reg)
            MODE_CRYPTO_LOOPBACK: cipher_data_in = {data1_reg, data0_reg};
            MODE_LIVE:            cipher_data_in = dbb_cipher_data_in;
            default:              cipher_data_in = {data1_reg, data0_reg};  // reserved modes
        endcase
    end

    // ------------------------------------------------------------------
    // 10. Cipher start
    // ------------------------------------------------------------------
    // Mode 0: pass the DBB valid pulse straight through, so start and data
    //         are in the same cycle.
    // Mode 2: start one cycle after the DATA_1 write, once data1_reg has
    //         updated.
    reg cipher_start_m2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cipher_start_m2 <= 1'b0;
        else        cipher_start_m2 <= wen_data1 && (ctrl_reg == MODE_CRYPTO_LOOPBACK);
    end
    assign cipher_start = (ctrl_reg == MODE_LIVE) ? dbb_cipher_data_valid
                                                  : cipher_start_m2;

    // ------------------------------------------------------------------
    // 11. Output data select (DATA_OUT)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out_reg <= 64'd0;
        end else begin
            case (ctrl_reg)
                MODE_LIVE:
                    if (cipher_done) data_out_reg <= cipher_data_out;
                MODE_DBB_LOOPBACK:
                    if (dbb_data_ready) data_out_reg <= {dbb_frame_out1, dbb_frame_out0};
                MODE_CRYPTO_LOOPBACK:
                    if (cipher_done) data_out_reg <= cipher_data_out;
                default:
                    data_out_reg <= data_out_reg;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 12. STATUS_REG
    // ------------------------------------------------------------------
    // [0] DONE         : cipher_done latched; cleared on STATUS_REG read
    // [1] DATA_READY   : DBB data_ready (already sticky in the DBB)
    // [2] PARITY_ERROR : DBB frame parity error
    reg sticky_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sticky_done <= 1'b0;
        else if (cipher_done)
            sticky_done <= 1'b1;
        else if (apb_read_xfer && sel_status)
            sticky_done <= 1'b0;
    end

    wire [31:0] status_reg = {29'd0, dbb_frame_parity_err, dbb_data_ready, sticky_done};

    // ------------------------------------------------------------------
    // 13. APB read mux
    // ------------------------------------------------------------------
    always @(*) begin
        prdata = 32'd0;
        if (apb_read_xfer) begin
            case (paddr)
                ADDR_CTRL_REG   : prdata = {30'd0, ctrl_reg};
                ADDR_STATUS_REG : prdata = status_reg;
                ADDR_DATA_OUT_0 : prdata = data_out_reg[31:0];
                ADDR_DATA_OUT_1 : prdata = data_out_reg[63:32];
                default         : prdata = 32'd0;   // write-only regs read as 0
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 14. Unused output
    // ------------------------------------------------------------------
    assign rfid_tx_bit = 1'b0;

    // ------------------------------------------------------------------
    // 15. Sub-module instances
    // ------------------------------------------------------------------
    dbb_top u_dbb (
        .clk                (clk),
        .rst_n              (rst_n),
        .mode_sel           (ctrl_reg),
        .rfid_rx_bit        (rfid_rx_bit),
        .lb_data0           (data0_reg),
        .lb_data1           (data1_reg),
        .lb_load            (lb_load),
        .frame_data_out0    (dbb_frame_out0),
        .frame_data_out1    (dbb_frame_out1),
        .data_ready         (dbb_data_ready),
        .data_read_ack      (data_read_ack),
        .cipher_data_in     (dbb_cipher_data_in),
        .cipher_data_valid  (dbb_cipher_data_valid),
        .frame_parity_error (dbb_frame_parity_err),
        .rfid_tx_bit        (dbb_tx_bit_unused)
    );

    present_core u_present (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (cipher_start),
        .plaintext  (cipher_data_in),
        .key        (cipher_key),
        .ciphertext (cipher_data_out),
        .done       (cipher_done),
        .busy       (cipher_busy)
    );

endmodule
