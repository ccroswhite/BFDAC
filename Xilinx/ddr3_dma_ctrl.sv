`timescale 1ns / 1ps

module ddr3_dma_ctrl #(
    parameter int APP_ADDR_WIDTH = 28,
    parameter int APP_DATA_WIDTH = 128
)(
    // User Logic Interface (The DSP Side)
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          user_rd_req,
    input  logic                          user_wr_req,
    input  logic [APP_ADDR_WIDTH-1:0]     user_addr,
    input  logic [APP_DATA_WIDTH-1:0]     user_wr_data,

    output logic [APP_DATA_WIDTH-1:0]     user_rd_data,
    output logic                          user_rd_valid,
    output logic                          user_busy,

    // MIG Native UI Interface (The RAM Side)
    output logic [APP_ADDR_WIDTH-1:0]     app_addr,
    output logic [2:0]                    app_cmd,     // 3'b000=Write, 3'b001=Read
    output logic                          app_en,
    input  logic                          app_rdy,

    output logic [APP_DATA_WIDTH-1:0]     app_wdf_data,
    output logic                          app_wdf_en,
    output logic                          app_wdf_end,
    input  logic                          app_wdf_rdy,

    input  logic [APP_DATA_WIDTH-1:0]     app_rd_data,
    input  logic                          app_rd_data_valid
);

    // Strictly defined FSM States
    typedef enum logic [2:0] {
        IDLE       = 3'b000,
        WRITE_WAIT = 3'b001,
        READ_WAIT  = 3'b010
    } state_t;

    state_t state;

    // Internal registers to latch user logic targets
    logic [APP_ADDR_WIDTH-1:0] req_addr;
    logic [APP_DATA_WIDTH-1:0] req_data;

    // Continuous Combinatorial Connections
    // Directly propagating incoming asynchronous valid pulses and data buses
    assign user_rd_data  = app_rd_data;
    assign user_rd_valid = app_rd_data_valid;

    // Strictly a single-beat burst interface natively aligned to enable
    assign app_wdf_end   = app_wdf_en;

    // Sequentially bounded operations using strict always_ff evaluation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            user_busy    <= 1'b0;
            
            app_addr     <= '0;
            app_cmd      <= 3'b000;
            app_en       <= 1'b0;
            
            app_wdf_data <= '0;
            app_wdf_en   <= 1'b0;
            
            req_addr     <= '0;
            req_data     <= '0;
        end else begin
            case (state)
                IDLE: begin
                    // Ensure the command triggers are intrinsically zeroed when not driving
                    app_en     <= 1'b0;
                    app_wdf_en <= 1'b0;

                    if (user_wr_req) begin
                        // Secure boundaries on User Requests
                        user_busy    <= 1'b1;
                        req_addr     <= user_addr;
                        req_data     <= user_wr_data;
                        
                        // Inject Write transaction directly onto the MIG UI bus parallel
                        app_addr     <= user_addr;
                        app_cmd      <= 3'b000;
                        app_en       <= 1'b1;
                        app_wdf_data <= user_wr_data;
                        app_wdf_en   <= 1'b1;
                        
                        state        <= WRITE_WAIT;
                    end else if (user_rd_req) begin
                        // Secure boundaries on User Requests
                        user_busy    <= 1'b1;
                        req_addr     <= user_addr;
                        
                        // Inject Read command (Leaving payload UI data logic inactive)
                        app_addr     <= user_addr;
                        app_cmd      <= 3'b001; 
                        app_en       <= 1'b1;
                        app_wdf_data <= '0;
                        app_wdf_en   <= 1'b0;
                        
                        state        <= READ_WAIT;
                    end else begin
                        user_busy    <= 1'b0;
                    end
                end
                
                WRITE_WAIT: begin
                    // Strictly hold data until the precise moment BOTH native UI limits unlock 
                    if (app_rdy && app_wdf_rdy) begin
                        app_en     <= 1'b0;
                        app_wdf_en <= 1'b0;
                        
                        // Transaction gracefully complete
                        user_busy  <= 1'b0; 
                        state      <= IDLE;
                    end
                end
                
                READ_WAIT: begin
                    // Sub-Phase 1: Present Read command until UI is natively ready
                    if (app_en && app_rdy) begin
                        app_en <= 1'b0; 
                        // Retaining state automatically shifts this to a passive wait payload structure
                    end
                    
                    // Sub-Phase 2: Transitioned wait phase until memory returns targeted payload frame
                    if (app_rd_data_valid) begin
                        user_busy <= 1'b0;
                        state     <= IDLE;
                    end
                end
                
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
