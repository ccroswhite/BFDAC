`timescale 1ns / 1ps

module sys_clock_gen #(
    // MMCM Math based on the 49.152 MHz / 45.1584 MHz family
    // Note: The MMCM will use the same multipliers for both, meaning:
    // 49.152 MHz in -> 98.304 MHz Frame / 393.216 MHz Bit
    // 45.1584 MHz in -> 90.3168 MHz Frame / 361.2672 MHz Bit
    parameter real VCO_MULTIPLIER  = 20.000, 
    parameter real BIT_CLK_DIVIDE  = 2.500,  
    parameter integer FRAME_DIVIDE = 10      
)(
    // Physical differential inputs from the two Crystek VCXOs
    input  logic clk_45m_p,
    input  logic clk_45m_n,
    input  logic clk_49m_p,
    input  logic clk_49m_n,
    
    // System controls
    input  logic rst_n,
    input  logic base_rate_sel,   // 0 = 44.1k family (45MHz), 1 = 48k family (49MHz)

    // Generated outputs
    output logic dsp_clk,         // Master DSP / OSERDES Frame Clock
    output logic lvds_bit_clk,    // High-Speed OSERDES Bit Clock
    output logic locked           // MMCM Locked Indicator (Audio Mute Control)
);

    // =========================================================================
    // 1. Differential Input Buffers
    // =========================================================================
    logic clk_45m_single, clk_49m_single;

    IBUFGDS #(.DIFF_TERM("TRUE")) u_ibuf_45m (
        .I  (clk_45m_p),
        .IB (clk_45m_n),
        .O  (clk_45m_single)
    );

    IBUFGDS #(.DIFF_TERM("TRUE")) u_ibuf_49m (
        .I  (clk_49m_p),
        .IB (clk_49m_n),
        .O  (clk_49m_single)
    );

    // =========================================================================
    // 2. Glitch-Free Clock Multiplexer
    // =========================================================================
    logic selected_master_clk;
    logic safe_clk_sel;

    // BUFGMUX_CTRL guarantees that when 'safe_clk_sel' flips, it waits for 
    // the current clock to hit low, and the new clock to hit low, before switching.
    BUFGMUX_CTRL u_clk_mux (
        .I0 (clk_45m_single), // input 0
        .I1 (clk_49m_single), // input 1
        .S  (safe_clk_sel),   // select pin
        .O  (selected_master_clk)
    );

    // =========================================================================
    // 3. MMCM Safe-Reset State Machine (Driven by a slow, safe internal clock)
    // =========================================================================
    // We cannot use the DSP clock for this state machine because the DSP clock 
    // will be dead while the MMCM is in reset! 
    // We must use the un-switched 49Mhz clock as the management heartbeat.
    
    typedef enum logic [1:0] {
        ST_NORMAL = 2'b00,
        ST_RESET  = 2'b01,
        ST_SWITCH = 2'b10,
        ST_WAIT   = 2'b11
    } state_t;
    
    state_t state, next_state;
    logic current_sel_reg;
    logic mmcm_reset;
    logic [7:0] wait_timer; // Small delay to let the MMCM settle
    
    always_ff @(posedge clk_49m_single or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_RESET;
            current_sel_reg <= 1'b0;
            safe_clk_sel    <= 1'b0;
            wait_timer      <= '0;
        end else begin
            state <= next_state;
            
            case (state)
                ST_NORMAL: begin
                    // If a sample rate change is requested, trigger the reset sequence
                    if (base_rate_sel != current_sel_reg) begin
                        current_sel_reg <= base_rate_sel;
                    end
                end
                ST_SWITCH: begin
                    safe_clk_sel <= current_sel_reg;
                    wait_timer   <= '0;
                end
                ST_WAIT: begin
                    if (wait_timer != 8'hFF) wait_timer <= wait_timer + 1;
                end
                default: ; // Do nothing
            endcase
        end
    end

    // Combinational next-state logic
    always_comb begin
        next_state = state;
        mmcm_reset = 1'b0;
        
        case (state)
            ST_NORMAL: begin
                if (base_rate_sel != current_sel_reg) next_state = ST_RESET;
            end
            ST_RESET: begin
                mmcm_reset = 1'b1;
                next_state = ST_SWITCH;
            end
            ST_SWITCH: begin
                mmcm_reset = 1'b1;
                next_state = ST_WAIT; // Wait for the BUFGMUX to physically switch
            end
            ST_WAIT: begin
                mmcm_reset = 1'b1;
                if (wait_timer == 8'hFF) next_state = ST_NORMAL; // Release reset
            end
        endcase
    end

    // =========================================================================
    // 4. The MMCM Engine
    // =========================================================================
    logic vco_feedback_out, vco_feedback_in;
    logic clk_out_bit_unbuf, clk_out_frame_unbuf;
    logic mmcm_locked;

    // Notice we use a generic PERIOD here because we are dynamically switching. 
    // The MMCM will track the input seamlessly.
    MMCME2_ADV #(
        .BANDWIDTH            ("OPTIMIZED"),
        .COMPENSATION         ("ZHOLD"),
        .DIVCLK_DIVIDE        (1),
        .CLKFBOUT_MULT_F      (VCO_MULTIPLIER),
        .CLKFBOUT_PHASE       (0.000),
        .CLKIN1_PERIOD        (20.345), // Base period hint
        
        .CLKOUT0_DIVIDE_F     (BIT_CLK_DIVIDE),
        .CLKOUT1_DIVIDE       (FRAME_DIVIDE)
    ) u_mmcm_master (
        .CLKIN1      (selected_master_clk),
        .CLKIN2      (1'b0),
        .CLKINSEL    (1'b1),
        .RST         (mmcm_reset | ~rst_n), // Driven by our state machine
        .PWRDWN      (1'b0),

        .CLKFBOUT    (vco_feedback_out),
        .CLKFBIN     (vco_feedback_in),
        .CLKOUT0     (clk_out_bit_unbuf),
        .CLKOUT1     (clk_out_frame_unbuf),

        .LOCKED      (mmcm_locked)
    );

    // =========================================================================
    // 5. Global Clock Buffers (BUFG)
    // =========================================================================
    BUFG u_bufg_fb    (.I(vco_feedback_out),    .O(vco_feedback_in));
    BUFG u_bufg_bit   (.I(clk_out_bit_unbuf),   .O(lvds_bit_clk));
    BUFG u_bufg_frame (.I(clk_out_frame_unbuf), .O(dsp_clk));

    // Expose the locked signal so the top module knows when to mute/unmute audio
    always_ff @(posedge dsp_clk or negedge rst_n) begin
        if (!rst_n) locked <= 1'b0;
        else        locked <= mmcm_locked;
    end

endmodule