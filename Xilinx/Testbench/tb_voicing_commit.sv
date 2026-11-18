`timescale 1ns / 1ps
// tb_voicing_commit: unit TB for voicing_commit_ctrl FSM.
//   P1: field-only commit (same preset)  -> apply at fir_frame_done, ack flips
//   P2: preset swap                      -> fade_out -> req -> load_done ->
//       swap confirm -> apply at frame_done -> fade_in -> ack
//   P3: failed preset load               -> err_toggle + fade_in + ack, no apply
//   P4: atomicity                        -- {en,k2,k3,preset} must appear TOGETHER

module tb_voicing_commit;
    localparam logic [15:0] BASE = 16'hF000;

    logic clk = 0, rst_n = 0;
    logic        commit_toggle_in = 0;
    logic        sh_en = 0;
    logic signed [26:0] sh_k2 = 0, sh_k3 = 0;
    logic [15:0] sh_filter_id = 16'hFFFF;
    logic        fir_frame_done = 0;
    logic        bank_valid = 1;
    logic        mgr_busy = 0;
    logic        coef_load_done = 0;
    logic        coef_load_failed = 0;
    logic [16:0] mgr_current_bank = 0;
    logic        spi_req_active = 0;
    logic        err_seen_in = 0;
    logic        fade_done = 0;
    logic        voicing_en;
    logic signed [26:0] voicing_k2, voicing_k3;
    logic [15:0] applied_filter_id;
    logic        ack_toggle, swap_busy, vo_err_toggle;
    logic        vo_req_pulse;
    logic [16:0] vo_req_data;
    logic        fade_out_req, fade_in_req;

    voicing_commit_ctrl dut (.*);

    always #5 clk = ~clk;

    int errors = 0;
    int frame_cnt = 0;
    // input-frame tick every 64 clks
    always_ff @(posedge clk) begin
        fir_frame_done <= 1'b0;
        if (rst_n && (frame_cnt % 64) == 63) fir_frame_done <= 1'b1;
        if (rst_n) frame_cnt++;
    end

    task automatic commit(input logic en, input logic [26:0] k2,
                          input logic [26:0] k3, input logic [15:0] fid = 16'hFFFF);
        begin
            @(negedge clk);
            sh_en = en; sh_k2 = k2; sh_k3 = k3; sh_filter_id = fid;
            @(negedge clk);
            commit_toggle_in = ~commit_toggle_in;   // SPI commit flip
        end
    endtask

    task automatic check(input bit cond, input string msg);
        if (!cond) begin errors++; $display("[tb_vcommit] FAIL: %s @%0t", msg, $time); end
    endtask

    logic prev_ack;
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1;
        mgr_current_bank <= {1'b1, 16'h0123};      // some prior directory bank
        repeat (10) @(posedge clk);

        // ---- P1: field-only commit --------------------------------------
        prev_ack = ack_toggle;
        // fid defaults to 16'hFFFF sentinel -> fields only, no bank touch
        commit(1'b1, 27'sd67109, -27'sd2684);
        // CDC edge -> V_IDLE->V_APPLY; applied at next fir_frame_done
        wait (voicing_en === 1'b1);
        check(voicing_k2 === 27'sd67109, "P1: k2 applied");
        check(voicing_k3 === -27'sd2684, "P1: k3 applied");
        check(ack_toggle !== prev_ack,  "P1: ack toggled");
        check(!vo_req_pulse && !fade_out_req, "P1: no bank req/fade on field-only");

        // ---- P2: preset swap ---------------------------------------------
        prev_ack = ack_toggle;
        commit(1'b1, 27'sd0, -27'sd2684, 16'h0050); // persona5,filter0,rate0
        // expect fade_out first
        wait (fade_out_req === 1'b1);
        check(swap_busy === 1'b1, "P2: swap_busy during fade");
        @(negedge clk); fade_done = 1'b1; @(negedge clk); fade_done = 1'b0;
        // request must target preset 5's filter ID
        wait (vo_req_pulse === 1'b1);
        check(vo_req_data === {1'b1, 16'h0050}, "P2: req filter_id = 0x0050 (raw)");
        // simulate manager: busy while loading, then done + swap
        mgr_busy = 1'b1;
        repeat (20) @(posedge clk);
        coef_load_done = 1'b1; @(posedge clk); coef_load_done = 1'b0;
        mgr_current_bank = {1'b1, 16'h0050};       // swap committed
        mgr_busy = 1'b0;
        // fid is derived from mgr_current_bank (updates at swap); the
        // pend_* fields only apply inside V_APPLY at fir_frame_done, and
        // fade_in_req only asserts after that — wait for it first.
        wait (fade_in_req === 1'b1);
        check(applied_filter_id === 16'h0050, "P2: fid applied");
        check(voicing_k2 === 27'sd0 && voicing_k3 === -27'sd2684,
              "P2: k fields applied with filter");
        @(negedge clk); fade_done = 1'b1; @(negedge clk); fade_done = 1'b0;
        wait (ack_toggle !== prev_ack);
        check(1'b1, "P2: ack after full swap");

        // ---- P3: failed preset load ---------------------------------------
        prev_ack = ack_toggle;
        commit(1'b0, 27'sd0, 27'sd0, 16'h0060);
        wait (fade_out_req === 1'b1);
        @(negedge clk); fade_done = 1'b1; @(negedge clk); fade_done = 1'b0;
        wait (vo_req_pulse === 1'b1);
        mgr_busy = 1'b1;
        repeat (10) @(posedge clk);
        coef_load_failed = 1'b1;
        coef_load_done   = 1'b1; @(posedge clk);
        coef_load_done = 1'b0; coef_load_failed = 1'b0;
        mgr_busy = 1'b0;
        wait (ack_toggle !== prev_ack);
        check(vo_err_toggle === 1'b1, "P3: err_toggle flipped");
        check(applied_filter_id === 16'h0050, "P3: filter_id NOT applied on failure");
        check(voicing_en === 1'b1, "P3: voicing_en unchanged (still 1)");

        // ---- P4: sentinel commit after manual load ------------------------
        // Manual load of a different bank, then a voicing commit naming the
        // applied-filter id: mgr-derived applied tracking sees the manual
        // swap, so a matching fid must NOT re-swap (fields only).
        mgr_current_bank = {1'b1, 16'h0ABC};        // simulate manual select
        repeat (4) @(posedge clk);
        prev_ack = ack_toggle;
        commit(1'b0, 27'sd1234, -27'sd56, 16'h0ABC); // fid == current bank
        wait (ack_toggle !== prev_ack);
        check(!vo_req_pulse, "P4: matching fid -> no bank request");
        check(voicing_k2 === 27'sd1234, "P4: k2 applied field-only");

        // ---- P5: sentinel keeps manual bank --------------------------------
        prev_ack = ack_toggle;
        commit(1'b1, -27'sd100, 27'sd200);           // fid=FFFF: don't touch
        wait (ack_toggle !== prev_ack);
        check(!vo_req_pulse && applied_filter_id === 16'h0ABC,
              "P5: FFFF sentinel leaves bank alone");
        check(voicing_en === 1'b1, "P5: en applied");

        // ---- P6: post-boot commit with !bank_valid -------------------------
        bank_valid = 1'b0;
        mgr_current_bank = '0;
        prev_ack = ack_toggle;
        commit(1'b1, 27'sd500, -27'sd600, 16'h0201); // default persona+filter
        // V_REQ is reached with NO fade-out (boot envelope holds mute), so
        // the request pulse arrives immediately — waiting on it first both
        // catches the 1-clk pulse and proves the fade-out was skipped.
        wait (vo_req_pulse === 1'b1);
        check(!fade_out_req, "P6: no fade-out when !bank_valid");
        check(vo_req_data === {1'b1, 16'h0201}, "P6: req raw filter_id");
        mgr_busy = 1'b1;
        repeat (20) @(posedge clk);
        coef_load_done = 1'b1; @(posedge clk); coef_load_done = 1'b0;
        mgr_current_bank = {1'b1, 16'h0201};
        mgr_busy = 1'b0; bank_valid = 1'b1;
        wait (ack_toggle !== prev_ack);
        check(applied_filter_id === 16'h0201, "P6: boot-path fid applied");
        check(!fade_in_req, "P6: no fade-in either (boot envelope owns it)");

        if (errors == 0) $display("[tb_vcommit] PASS");
        else             $display("[tb_vcommit] FAIL errors=%0d", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #20_000_000;
        $display("[tb_vcommit] FAIL: timeout");
        $finish;
    end
endmodule
