`timescale 1ns / 1ps

module fir_engine_top (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               enable,
    input  logic signed [24:0] audio_in,
    output logic signed [47:0] fir_out,
    output logic               fir_out_valid
);

    logic [12:0] raw_addr_A;
    logic [12:0] raw_addr_B;
    logic        enable_systolic;
    logic signed [17:0] coeffs_in [0:127];

    // =================================---------------------------------------
    // The 2-Stage Fanout Pipeline Tree (Kills routing delay to 64 BRAMs)
    // =================================---------------------------------------
    
    // STAGE 1: Regional Distribution (Vivado will clone to 4 physical quadrants)
    (* max_fanout = 4 *) logic [12:0] addr_A_s1;
    (* max_fanout = 4 *) logic [12:0] addr_B_s1;

    // STAGE 2: Local BRAM Distribution (Vivado will clone directly next to the BRAMs)
    (* max_fanout = 16 *) logic [12:0] addr_A_s2;
    (* max_fanout = 16 *) logic [12:0] addr_B_s2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            addr_A_s1 <= '0;
            addr_B_s1 <= '0;
            addr_A_s2 <= '0;
            addr_B_s2 <= '0;
        end else begin
            // Step 1: Catch the output from the controller
            addr_A_s1 <= raw_addr_A;
            addr_B_s1 <= raw_addr_B;
            
            // Step 2: Forward to the local BRAM replicas
            addr_A_s2 <= addr_A_s1;
            addr_B_s2 <= addr_B_s1;
        end
    end

    // =================================---------------------------------------
    // 1. The Controller
    // =================================---------------------------------------
    fir_bram_controller u_ctrl (
        .clk               (clk),
        .rst_n             (rst_n),
        .start_processing  (enable),
        .enable_systolic   (enable_systolic),
        .addr_A            (raw_addr_A),
        .addr_B            (raw_addr_B)
    );

    // =================================---------------------------------------
    // 2. The 64 Physical BRAM Shards
    // =================================---------------------------------------
    genvar i;
    generate
        for (i = 0; i < 64; i++) begin : BRAM_BANK
            fir_rom_shard #(
                // Using ternary operator to force a '0' for indices 0-9
                .INIT_FILE( (i < 10) ? $sformatf("/Users/ccros/src/BFDAC/utils/coef/shard_0%0d_dcs.mem", i) : $sformatf("/Users/ccros/src/BFDAC/utils/coef/shard_%0d_dcs.mem", i) )
            ) u_shard (
                .clk    (clk),
                .ena    (1'b1), // FORCE BRAM ENABLE PIN HIGH
                .addr_A (addr_A_s2), // Feed from Stage 2 of the Fanout Tree
                .addr_B (addr_B_s2),
                .data_A (coeffs_in[i]),      // Port A feeds forward DSPs (0 to 63)
                .data_B (coeffs_in[127 - i]) // Port B feeds mirrored DSPs (127 down to 64)
            );
        end
    endgenerate

    // =================================---------------------------------------
    // 3. The 128-Slice Math Cascade
    // =================================---------------------------------------
    fir_systolic_128 u_math (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (enable_systolic),
        .audio_in      (audio_in),
        .coeffs_in     (coeffs_in),
        .fir_out       (fir_out),
        .fir_out_valid (fir_out_valid)
    );

endmodule