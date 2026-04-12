`timescale 1ns / 1ps

module dsp_master_ctrl #(
    parameter int DATA_WIDTH     = 32,
    parameter int NUM_MACS       = 256,
    parameter int ACC_WIDTH      = 64,
    parameter int DEM_AMP_WIDTH  = 6,
    parameter int DMA_ADDR_WIDTH = 28,
    // Determines which slice of the 64-bit accumulator holds the active audio.
    // Depends on coefficient gain; usually requires tuning during simulation.
    parameter int ACC_SHIFT      = 40 
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

    typedef enum logic [2:0] {
        IDLE          = 3'b000,
        STORE_SAMPLE  = 3'b001,
        FETCH_HISTORY = 3'b010,
        PUMP_FIR      = 3'b011, // New State: Unbroken continuous feed
        OUTPUT_RESULT = 3'b100
    } state_t;

    state_t state;

    logic [12:0] ring_buffer_ptr, fetch_ptr;
    logic [DATA_WIDTH-1:0] latched_sample;
    
    logic [15:0] req_counter, rx_counter, pump_counter, drain_counter;
    logic        dma_in_flight;

    // =========================================================================
    // The Elastic Buffer (Inferred BRAM)
    // Absorbs AXI/DDR latency to guarantee continuous streaming to the FIR array
    // =========================================================================
    logic [DATA_WIDTH-1:0] elastic_buffer [0:NUM_MACS-1];

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
            pump_counter    <= '0;
            drain_counter   <= '0;
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
                         dma_addr      <= DMA_ADDR_WIDTH'(ring_buffer_ptr);
                         dma_wr_data   <= latched_sample;
                         dma_wr_req    <= 1'b1;
                         dma_in_flight <= 1'b1; 
                    end else if (dma_wr_req) begin
                         dma_wr_req <= 1'b0;
                    end else if (!dma_busy && dma_in_flight) begin
                         req_counter   <= '0;
                         rx_counter    <= '0;
                         fetch_ptr     <= ring_buffer_ptr;
                         dma_in_flight <= 1'b0;
                         state         <= FETCH_HISTORY;
                    end
                end
                
                FETCH_HISTORY: begin
                    // 1. Blast Requests to DDR3
                    if (req_counter < NUM_MACS) begin
                        if (!dma_busy && !dma_rd_req) begin
                            dma_addr    <= DMA_ADDR_WIDTH'(fetch_ptr);
                            dma_rd_req  <= 1'b1;
                            fetch_ptr   <= (fetch_ptr - 13'b1) & 13'h1FFF; 
                            req_counter <= req_counter + 16'b1;
                        end else if (dma_rd_req) begin
                            dma_rd_req <= 1'b0;
                        end
                    end else begin
                        dma_rd_req <= 1'b0;
                    end

                    // 2. Catch Returns into the Elastic Buffer
                    if (dma_rd_valid) begin
                        elastic_buffer[rx_counter] <= dma_rd_data;
                        rx_counter                 <= rx_counter + 16'b1;
                    end

                    // 3. Wait until the entire buffer is safe
                    if (rx_counter == NUM_MACS) begin
                        pump_counter <= '0;
                        state        <= PUMP_FIR;
                    end
                end

                PUMP_FIR: begin
                    // Feed the systolic array continuously, ignoring DMA latency
                    if (pump_counter < NUM_MACS) begin
                        fir_sample_in <= elastic_buffer[pump_counter];
                        pump_counter  <= pump_counter + 16'b1;
                    end else begin
                        drain_counter <= '0;
                        state         <= OUTPUT_RESULT;
                    end
                end
                
                OUTPUT_RESULT: begin
                    // Wait for the pipeline depth of the systolic array to clear
                    if (drain_counter < (NUM_MACS * 2) + 10) begin
                        drain_counter <= drain_counter + 16'b1;
                    end else begin
                        
                        // --- SIGNED TO UNSIGNED PHYSICAL MAPPING ---
                        // 1. Extract the active signed audio bits from the 64-bit accumulator.
                        //    (We cast it to signed to ensure the synthesis tool tracks the MSB).
                        automatic logic signed [5:0] extracted_audio = 
                            $signed(fir_acc_out[ACC_SHIFT + 5 : ACC_SHIFT]);
                        
                        // 2. Offset Binary Conversion. 
                        //    Add 16 to move the DC center from 0 to 16.
                        //    Audio 0 -> 16 resistors. Audio +15 -> 31 resistors.
                        automatic logic [5:0] physical_drive = 
                            unsigned'(extracted_audio + 6'd16);

                        // 3. Hard Clamping to protect the array bounds (0 to 32)
                        if (physical_drive > 6'd32)      dsp_audio_out <= 6'd32;
                        else                             dsp_audio_out <= physical_drive;

                        dsp_audio_valid <= 1'b1;
                        state           <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule