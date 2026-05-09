`timescale 1ns / 1ps

module hyperram_axi_master #(
    parameter int AXI_ADDR_WIDTH = 32,
    parameter int AXI_DATA_WIDTH = 32
)(
    // OpenHBMC Clock Domain (~100 MHz)
    input  logic                      axi_clk,
    input  logic                      axi_rst_n,

    // Command Interface (From 357MHz Domain via Async FIFO)
    input  logic                      cmd_valid,
    input  logic [AXI_ADDR_WIDTH-1:0] cmd_addr,
    input  logic [7:0]                cmd_burst_len,
    input  logic [AXI_DATA_WIDTH-1:0] cmd_write_data,
    input  logic                      cmd_is_write,
    output logic                      axi_busy,

    // BRAM Cache Interface (Writing fetched history back to DSP)
    output logic                      cache_we,
    output logic [AXI_DATA_WIDTH-1:0] cache_wdata,

    // ==========================================
    // AXI4 Master Interface (To OpenHBMC)
    // ==========================================
    
    // 1. Write Address Channel (AW)
    output logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    // 2. Write Data Channel (W)
    output logic [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,

    // 3. Write Response Channel (B)
    input  logic [1:0]                m_axi_bresp,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready,

    // 4. Read Address Channel (AR)
    output logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    // 5. Read Data Channel (R)
    input  logic [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rlast,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready
);

    // Hardcode AXI size and burst types for standard 32-bit incremental memory access
    assign m_axi_awsize  = 3'b010; // 4 bytes (32 bits)
    assign m_axi_arsize  = 3'b010; 
    assign m_axi_awburst = 2'b01;  // INCR burst
    assign m_axi_arburst = 2'b01;  
    assign m_axi_wstrb   = 4'b1111; // Write all bytes

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WRITE_ADDR,
        ST_WRITE_DATA,
        ST_WRITE_RESP,
        ST_READ_ADDR,
        ST_READ_DATA
    } state_t;
    
    state_t state, next_state;

    // State Machine Registers
    always_ff @(posedge axi_clk) begin
        if (!axi_rst_n) state <= ST_IDLE;
        else            state <= next_state;
    end

    // Next State & AXI Handshake Logic
    always_comb begin
        // Default Assignments
        next_state    = state;
        axi_busy      = 1'b1;
        
        m_axi_awvalid = 1'b0;
        m_axi_wvalid  = 1'b0;
        m_axi_wlast   = 1'b0;
        m_axi_bready  = 1'b0;
        
        m_axi_arvalid = 1'b0;
        m_axi_rready  = 1'b0;
        
        cache_we      = 1'b0;

        case (state)
            ST_IDLE: begin
                axi_busy = 1'b0;
                if (cmd_valid) begin
                    if (cmd_is_write) next_state = ST_WRITE_ADDR;
                    else              next_state = ST_READ_ADDR;
                end
            end

            // --- WRITE SEQUENCE (Pushing new I2S sample to HyperRAM) ---
            ST_WRITE_ADDR: begin
                m_axi_awvalid = 1'b1;
                if (m_axi_awvalid && m_axi_awready) begin
                    next_state = ST_WRITE_DATA;
                end
            end

            ST_WRITE_DATA: begin
                m_axi_wvalid = 1'b1;
                m_axi_wlast  = 1'b1; // Assuming single-beat writes for incoming audio
                if (m_axi_wvalid && m_axi_wready) begin
                    next_state = ST_WRITE_RESP;
                end
            end

            ST_WRITE_RESP: begin
                m_axi_bready = 1'b1;
                if (m_axi_bvalid && m_axi_bready) begin
                    next_state = ST_IDLE;
                end
            end

            // --- READ SEQUENCE (Bursting history back to the BRAM Cache) ---
            ST_READ_ADDR: begin
                m_axi_arvalid = 1'b1;
                if (m_axi_arvalid && m_axi_arready) begin
                    next_state = ST_READ_DATA;
                end
            end

            ST_READ_DATA: begin
                m_axi_rready = 1'b1;
                // If OpenHBMC has valid data, write it instantly to our Ping-Pong BRAM
                if (m_axi_rvalid) begin
                    cache_we = 1'b1;
                    if (m_axi_rlast) begin
                        next_state = ST_IDLE; // Burst complete
                    end
                end
            end
        endcase
    end

    // Address and Data Latching
    always_ff @(posedge axi_clk) begin
        if (!axi_rst_n) begin
            m_axi_awaddr <= '0;
            m_axi_awlen  <= '0;
            m_axi_wdata  <= '0;
            m_axi_araddr <= '0;
            m_axi_arlen  <= '0;
        end else if (state == ST_IDLE && cmd_valid) begin
            if (cmd_is_write) begin
                m_axi_awaddr <= cmd_addr;
                m_axi_awlen  <= cmd_burst_len;
                m_axi_wdata  <= cmd_write_data;
            end else begin
                m_axi_araddr <= cmd_addr;
                m_axi_arlen  <= cmd_burst_len;
            end
        end
    end

    // Stream the incoming AXI data directly to the BRAM cache output
    assign cache_wdata = m_axi_rdata;

endmodule