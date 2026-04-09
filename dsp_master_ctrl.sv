`timescale 1ns / 1ps

module dsp_master_ctrl #(
    parameter int DATA_WIDTH       = 32,
    parameter int NUM_MACS         = 256,
    parameter int OVERSAMPLE_RATIO = 5120,
    parameter int ACC_WIDTH        = 64,
    parameter int DEM_AMP_WIDTH    = 6,
    parameter int DMA_ADDR_WIDTH   = 28
)(
    input  logic                      clk,
    input  logic                      rst_n,

    // Upstream Interface (From CDC Moat FIFO)
    input  logic                      new_sample_valid,
    input  logic [DATA_WIDTH-1:0]     new_sample_data,

    // Fast-Memory Interface (To DDR3 DMA Controller)
    output logic                      dma_wr_req,
    output logic                      dma_rd_req,
    output logic [DMA_ADDR_WIDTH-1:0] dma_addr,
    output logic [DATA_WIDTH-1:0]     dma_wr_data,
    
    input  logic [DATA_WIDTH-1:0]     dma_rd_data,
    input  logic                      dma_rd_valid,
    input  logic                      dma_busy,

    // Number Crunching Interface (To Systolic FIR Array)
    output logic signed [DATA_WIDTH-1:0] fir_sample_in,
    output logic signed [ACC_WIDTH-1:0]  fir_acc_in,
    input  logic signed [ACC_WIDTH-1:0]  fir_acc_out,

    // Output Conversion Interface (To DEM Mapper)
    output logic [DEM_AMP_WIDTH-1:0]  dsp_audio_out,
    output logic                      dsp_audio_valid
);

    // Secure state bounds (Consolidated Fetch & Pump)
    typedef enum logic [2:0] {
        IDLE          = 3'b000,
        STORE_SAMPLE  = 3'b001,
        BURST_HISTORY = 3'b010,
        OUTPUT_RESULT = 3'b011
    } state_t;

    state_t state;

    logic [12:0] ring_buffer_ptr; 
    logic [12:0] fetch_ptr;
    logic [DATA_WIDTH-1:0] latched_sample;
    
    // Decoupled parallel trackers
    logic [15:0] req_counter;
    logic [15:0] rx_counter;
    logic [15:0] drain_counter;
    logic        dma_in_flight;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            ring_buffer_ptr <= '0;
            
            dma_wr_req      <= 1'b0;
            dma_rd_req      <= 1'b0;
            dma_addr        <= '0;
            dma_wr_data     <= '0;
            
            fir_sample_in   <= '0;
            fir_acc_in      <= '0; 
            
            dsp_audio_out   <= '0;
            dsp_audio_valid <= 1'b0;
            
            req_counter     <= '0;
            rx_counter      <= '0;
            drain_counter   <= '0;
            fetch_ptr       <= '0;
            latched_sample  <= '0;
            dma_in_flight   <= 1'b0;
        end else begin
            dsp_audio_valid <= 1'b0;
            fir_sample_in   <= '0;
            
            case (state)
                IDLE: begin
                    if (new_sample_valid) begin
                        ring_buffer_ptr <= (ring_buffer_ptr + 13'b1) & 13'h1FFF;
                        latched_sample  <= new_sample_data;
                        dma_in_flight   <= 1'b0;
                        state           <= STORE_SAMPLE;
                    end
                end
                
                STORE_SAMPLE: begin
                    if (!dma_busy && !dma_wr_req && !dma_in_flight) begin
                         dma_addr    <= DMA_ADDR_WIDTH'(ring_buffer_ptr);
                         dma_wr_data <= latched_sample;
                         dma_wr_req  <= 1'b1;
                         dma_in_flight <= 1'b1; 
                    end 
                    else if (dma_wr_req) begin
                         dma_wr_req <= 1'b0;
                    end 
                    else if (!dma_busy && dma_in_flight) begin
                         state         <= BURST_HISTORY;
                         dma_in_flight <= 1'b0;
                         
                         req_counter   <= '0;
                         rx_counter    <= '0;
                         fetch_ptr     <= ring_buffer_ptr;
                    end
                end
                
                BURST_HISTORY: begin
                    // ENGINE 1: The Request Blaster
                    // Fires commands as fast as the DMA will accept them, independent of returned data.
                    if (req_counter < OVERSAMPLE_RATIO) begin
                        if (!dma_busy && !dma_rd_req) begin
                            dma_addr   <= DMA_ADDR_WIDTH'(fetch_ptr);
                            dma_rd_req <= 1'b1;
                            fetch_ptr  <= (fetch_ptr - 13'b1) & 13'h1FFF; 
                            req_counter <= req_counter + 16'b1;
                        end else if (dma_rd_req) begin
                            dma_rd_req <= 1'b0;
                        end
                    end else begin
                        dma_rd_req <= 1'b0;
                    end

                    // ENGINE 2: The Receive Catcher & FIR Pumper
                    // Operates completely asynchronously to the request blaster above.
                    if (dma_rd_valid) begin
                        fir_sample_in <= dma_rd_data;
                        rx_counter    <= rx_counter + 16'b1;
                    end

                    // ENGINE 3: Exit Condition
                    // Only transition when the exact number of required samples have physically returned.
                    if (rx_counter == OVERSAMPLE_RATIO) begin
                        state <= OUTPUT_RESULT;
                        drain_counter <= '0;
                    end
                end
                
                OUTPUT_RESULT: begin
                    if (drain_counter < (NUM_MACS * 2) + 10) begin
                        drain_counter <= drain_counter + 16'b1;
                    end else begin
                        dsp_audio_out   <= fir_acc_out[DATA_WIDTH + DEM_AMP_WIDTH - 1 : DATA_WIDTH];
                        dsp_audio_valid <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
