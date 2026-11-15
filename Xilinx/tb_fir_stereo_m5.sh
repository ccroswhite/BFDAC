# 1. Verify Stage 1A Python packer round-trip, 2^41 DC gain, and directory headers
python3 stage1a_coef_packer.py --self-test

# (Optional) Generate an 5.24M-tap packed bank + 32B directory entry for DDR4/flash:
python3 stage1a_coef_packer.py \
  --num-macs 128 --taps-per-phase 256 --rate-shift 0 --family 48k \
  --profile wta --filter-id 1 --ddr4-addr 0x00000000 \
  --out-bin bank1_wta_5m.bin --out-dir-entry bank1_wta_5m.dir

# 2. Run Milestone 5 Two-Stage (x2 -> x8) bit-exact RTL simulation
xvlog -sv -d SIM \
  polyphase_mac_engine.sv \
  polyphase_adder_tree.sv \
  fir_stage1b_interp8.sv \
  fir_polyphase_interpolator.sv \
  fir_polyphase_stereo.sv \
  tb_fir_stereo_m5.sv && \
xelab tb_fir_stereo_m5 -s sim_stereo_m5 && \
xsim sim_stereo_m5 -R