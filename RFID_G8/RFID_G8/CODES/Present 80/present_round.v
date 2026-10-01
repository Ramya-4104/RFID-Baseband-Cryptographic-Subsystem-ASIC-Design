module present_round (
    input  wire [63:0] state_in,
    input  wire [63:0] round_key,
    output wire [63:0] state_out
);
    wire [63:0] ark_state;
    wire [63:0] s_state;

    assign ark_state = state_in ^ round_key;

    present_s_layer u_s_layer (
        .state_in  (ark_state),
        .state_out (s_state)
    );

    present_p_layer u_p_layer (
        .state_in  (s_state),
        .state_out (state_out)
    );
endmodule
