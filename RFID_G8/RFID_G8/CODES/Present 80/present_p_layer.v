module present_p_layer (
    input  wire [63:0] state_in,
    output reg  [63:0] state_out
);
    integer i;
    always @(*) begin
        state_out = 64'b0;
        for (i = 0; i < 63; i = i + 1)
            state_out[(16*i) % 63] = state_in[i];
        state_out[63] = state_in[63];
    end
endmodule
