module present_s_layer (
    input  wire [63:0] state_in,
    output wire [63:0] state_out
);
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : GEN_SBOX
            present_sbox u_sbox (
                .x(state_in[4*i +: 4]),
                .y(state_out[4*i +: 4])
            );
        end
    endgenerate
endmodule
