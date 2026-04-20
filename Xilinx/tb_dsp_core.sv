`timescale 1ns / 1ps

module tb_dsp_core();

    // 90MHz DSP Clock (11.111 ns period)
    logic clk = 0;
    always #5.555 clk = ~clk;

    logic rst_n;
    
    // Stimulus generation
    logic [23:0] test_audio_data;
    logic        test_audio_valid;
    
    // Outputs
    logic signed [47:0] interpolated_audio_48b;
    logic               interpolated_valid;
    logic [5:0]         dem_drive_command;
    logic [63:0]        resistor_ring_bus;

    // File I/O
    int fd;

    // -------------------------------------------------------------
    // Device Under Test (DUT) Instantiations
    // -------------------------------------------------------------
    fir_polyphase_interpolator #(
        .NUM_MACS(256), .DATA_WIDTH(24), .COEF_WIDTH(18), .ACC_WIDTH(48)
    ) u_1m_tap_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .new_sample_valid   (test_audio_valid),
        .new_sample_data    (test_audio_data), 
        .interpolated_out   (interpolated_audio_48b),
        .interpolated_valid (interpolated_valid)
    );

    localparam int FIR_GAIN_SHIFT = 16; 
    
    noise_shaper_2nd_order #(
        .INPUT_WIDTH(32), .FRAC_WIDTH(26)
    ) u_noise_shaper (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (interpolated_valid),
        .data_in        (interpolated_audio_48b[FIR_GAIN_SHIFT + 31 : FIR_GAIN_SHIFT]),
        .dem_drive_out  (dem_drive_command)
    );

    dem_mapper #(
        .ARRAY_SIZE(32), .AMP_WIDTH(6)
    ) u_dem_mapper (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (interpolated_valid),
        .amplitude_in (dem_drive_command),
        .resistor_out (resistor_ring_bus)
    );

    // -------------------------------------------------------------
    // Stimulus & Capture
    // -------------------------------------------------------------
    real PI = 3.141592653589793;
    real F_SINE = 1000.0;     // 1 kHz test tone
    real F_SAMPLE = 44100.0;  // 44.1 kHz base rate
    real t = 0.0;
    real sine_val;

    initial begin
        fd = $fopen("dsp_output.txt", "w");
        if (!fd) begin
            $display("ERROR: Could not open file.");
            $finish;
        end

        rst_n = 0;
        test_audio_valid = 0;
        test_audio_data = 0;
        
        #100;
        rst_n = 1;
        #100;

        // Generate 0.1 seconds of audio (approx 4410 base samples)
        for (int i = 0; i < 4500; i++) begin
            // Calculate perfect sine wave (-1.0 to 1.0)
            sine_val = $sin(2.0 * PI * F_SINE * t);
            
            // Scale to 24-bit signed integer space (using 50% amplitude to avoid clipping)
            test_audio_data = $rtoi(sine_val * (0.5 * (2**23 - 1)));
            
            // Strobe valid for 1 clock cycle
            @(posedge clk);
            test_audio_valid = 1;
            @(posedge clk);
            test_audio_valid = 0;

            // Wait for next sample period (approx 22.67 us / 11.11 ns = ~2040 clock cycles)
            repeat(2040) @(posedge clk);
            
            t = t + (1.0 / F_SAMPLE);
        end

        $fclose(fd);
        $display("Simulation Complete. Output written to dsp_output.txt");
        $finish;
    end

    // Log the high-speed noise shaped output
    always_ff @(posedge clk) begin
        if (interpolated_valid) begin
            // Write the Noise Shaper Amplitude and the raw DEM bitmask
            $fdisplay(fd, "%d,%h", dem_drive_command, resistor_ring_bus);
        end
    end

endmodule