`timescale 1ns / 1ps

module ddr3_axi_master #(
    parameter int C_M_AXI_ADDR_WIDTH = 29,
    parameter int C_M_AXI_DATA_WIDTH = 128
)(
    // MIG User Interface Clock & Reset (83.33 MHz Domain)
    input  logic                              ui_clk,
    input  logic                              ui_clk_sync_rst,

    // Cross-Domain Trigger (From the I2S ingress)
    input  logic                              new_sample_trigger,
    input  logic [31:0]                       new_sample_data,

    // Cache Write Interface (To the Ping-Pong BRAM)
    output logic                              cache_we,
    output logic [7:0]                        cache_waddr,  // 256 beats
    output logic [127:0]                      cache_wdata,

    // AXI4 Write Address Channel (AW)
    output logic [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                        m_axi_awlen,
    output logic [2:0]                        m_axi_awsize,
    output logic [1:0]                        m_axi_awburst,
    output logic                              m_axi_awvalid,
    input  logic                              m_axi_awready,

    // AXI4 Write Data Channel (W)
    output logic [C_M_AXI_DATA_WIDTH-1:0]     m_axi_wdata,
    output logic [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output logic                              m_axi_wlast,
    output logic                              m_axi_wvalid,
    input  logic                              m_axi_wready,

    // AXI4 Write Response Channel (B)
    input  logic [1:0]                        m_axi_bresp,
    input  logic                              m_axi_bvalid,
    output logic                              m_axi_bready,

    // AXI4 Read Address Channel (AR)
    output logic [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                        m_axi_arlen,
    output logic [2:0]                        m_axi_arsize,
    output logic [1:0]                        m_axi_arburst,
    output logic                              m_axi_arvalid,
    input  logic                              m_axi_arready,

    // AXI4 Read Data Channel (R)
    input  logic [C_M_AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input  logic [1:0]                        m_axi_rresp,
    input  logic                              m_axi_rlast,
    input  logic                              m_axi_rvalid,
    output logic                              m_axi_rready
);

    // =================================---------------------------------------
    // 1. Circular Buffer Pointers
    // =================================---------------------------------------
    logic [C_M_AXI_ADDR_WIDTH-1:0] head_ptr;
    logic [C_M_AXI_ADDR_WIDTH-1:0] tail_ptr;

    // =================================---------------------------------------
    // 2. State Machine Encoding
    // =================================---------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        AW_PHASE,
        W_PHASE,
        B_PHASE,
        AR_PHASE,
        R_PHASE
    } axi_state_t;

    axi_state_t state, next_state;

    // =================================---------------------------------------
    // 3. Cross-Domain Trigger Synchronization
    // =================================---------------------------------------
    // Safely catches the slow 768kHz trigger pulse in the 83.33MHz domain
    logic trigger_q1, trigger_q2, trigger_pulse;

    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            trigger_q1 <= 1'b0;
            trigger_q2 <= 1'b0;
        end else begin
            trigger_q1 <= new_sample_trigger;
            trigger_q2 <= trigger_q1;
        end
    end
    
    // Edge detector fires a single 83.33MHz pulse
    assign trigger_pulse = trigger_q1 & ~trigger_q2;

    // =================================---------------------------------------
    // 4. State Machine Sequential Logic & Pointers
    // =================================---------------------------------------
    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            state <= IDLE;
            head_ptr <= '0;
        end else begin
            state <= next_state;

            // Advance the memory head pointer when a write completes
            if (state == W_PHASE && m_axi_wvalid && m_axi_wready) begin
                head_ptr <= head_ptr + 29'd16; // 16 bytes = 128 bits
            end
        end
    end

    // =================================---------------------------------------
    // 5. State Machine Combinational Transitions
    // =================================---------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (trigger_pulse) next_state = AW_PHASE;
            end
            AW_PHASE: begin
                if (m_axi_awvalid && m_axi_awready) next_state = W_PHASE;
            end
            W_PHASE: begin
                if (m_axi_wvalid && m_axi_wready) next_state = B_PHASE;
            end
            B_PHASE: begin
                if (m_axi_bvalid && m_axi_bready) next_state = AR_PHASE;
            end
            AR_PHASE: begin
                if (m_axi_arvalid && m_axi_arready) next_state = R_PHASE;
            end
            R_PHASE: begin
                if (m_axi_rvalid && m_axi_rready && m_axi_rlast) next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // =================================---------------------------------------
    // 6. AXI4 Channel Assignments
    // =================================---------------------------------------
    
    // --- Write Channels (AW & W) ---
    assign m_axi_awaddr  = head_ptr;
    assign m_axi_awlen   = 8'd0;          // 0 = 1 beat write
    assign m_axi_awsize  = 3'b100;        // 16 bytes (128 bits) per beat
    assign m_axi_awburst = 2'b01;         // INCR
    assign m_axi_awvalid = (state == AW_PHASE);

    // Pad the 32-bit audio sample to the 128-bit bus, but use the byte strobe 
    // to tell the MIG to only write the bottom 4 bytes (32 bits) to memory.
    assign m_axi_wdata   = {96'd0, new_sample_data}; 
    assign m_axi_wstrb   = 16'h000F;      // 0000_0000_0000_1111 
    assign m_axi_wlast   = 1'b1;          // Assert last on the single beat
    assign m_axi_wvalid  = (state == W_PHASE);

    assign m_axi_bready  = (state == B_PHASE);

    // --- Read Channels (AR & R) ---
    // Fetch 1,024 samples backwards (256 beats * 16 bytes = 4096 bytes)
    assign tail_ptr = head_ptr - 29'd4096;

    assign m_axi_araddr  = tail_ptr;
    assign m_axi_arlen   = 8'hFF;         // FF = 256 beats (Absolute AXI4 Maximum)
    assign m_axi_arsize  = 3'b100;        // 16 bytes (128 bits) per beat
    assign m_axi_arburst = 2'b01;         // INCR
    assign m_axi_arvalid = (state == AR_PHASE);

    assign m_axi_rready  = (state == R_PHASE);

    // =================================---------------------------------------
    // 7. Ping-Pong Cache Write Execution
    // =================================---------------------------------------
    logic [7:0] read_beat_cnt;

    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            read_beat_cnt <= '0;
        end else if (state == AR_PHASE && m_axi_arvalid && m_axi_arready) begin
            // Reset the internal BRAM cache pointer when issuing a new read request
            read_beat_cnt <= '0;
        end else if (state == R_PHASE && m_axi_rvalid && m_axi_rready) begin
            // Increment the BRAM cache pointer as valid data streams in
            read_beat_cnt <= read_beat_cnt + 1'b1;
        end
    end

    // Drive the BRAM write ports dynamically as data arrives
    assign cache_we    = (state == R_PHASE) && m_axi_rvalid && m_axi_rready;
    assign cache_waddr = read_beat_cnt;
    assign cache_wdata = m_axi_rdata;

endmodule