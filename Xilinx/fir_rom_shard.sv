`timescale 1ns / 1ps

module fir_rom_shard #(
    parameter string INIT_FILE = ""
)(
    input  logic               clk,
    input  logic               ena,
    input  logic [12:0]        addr_A,
    input  logic [12:0]        addr_B,
    output logic signed [17:0] data_A,
    output logic signed [17:0] data_B
);

    // Instantiate True Dual-Port RAM and tie Write Enables to 0 to create a ROM
    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(13),
        .ADDR_WIDTH_B(13),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(18),
        .BYTE_WRITE_WIDTH_B(18),
        .CLOCKING_MODE("common_clock"),
        .MEMORY_INIT_FILE(INIT_FILE),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(147456), 
        .READ_DATA_WIDTH_A(18),
        .READ_DATA_WIDTH_B(18),
        .READ_LATENCY_A(2),    // UPGRADED to 2: Enables internal BRAM output registers
        .READ_LATENCY_B(2),    // UPGRADED to 2: Enables internal BRAM output registers
        .USE_MEM_INIT(1),
        .WRITE_DATA_WIDTH_A(18),
        .WRITE_DATA_WIDTH_B(18)
    ) xpm_memory_tdpram_inst (
        .douta(data_A),
        .doutb(data_B),
        .addra(addr_A),
        .addrb(addr_B),
        .clka(clk),
        .clkb(clk),
        .ena(ena),
        .enb(ena),
        
        // --- TIE WRITES TO ZERO FOR ROM INFERENCE ---
        .dina(18'd0),
        .dinb(18'd0),
        .wea(1'b0), 
        .web(1'b0), 
        
        // --- TIE OFF UNUSED ADVANCED FEATURES ---
        .injectdbiterra(1'b0),
        .injectdbiterrb(1'b0),
        .injectsbiterra(1'b0),
        .injectsbiterrb(1'b0),
        .regcea(1'b1),
        .regceb(1'b1),
        .rsta(1'b0),
        .rstb(1'b0),
        .sleep(1'b0),
        .dbiterra(),
        .dbiterrb(),
        .sbiterra(),
        .sbiterrb()
    );

endmodule