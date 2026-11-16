# GPS L1 acquisition core - simulation and synthesis
#   make vectors   regenerate ROM images + test vectors from the Python model
#   make sim       FFT unit test + directed system test (T1-T8) + IRQ test + regression
#   make syn       Yosys synthesis for Xilinx 7-series (resource estimate)
#   make clean
# Run from this directory (hw/).  Needs: python3 + numpy, iverilog >= 12, yosys.

PY     ?= python3
RTL    := rtl/sdf_stage.sv rtl/fft_sdf.sv rtl/acq_core.sv rtl/gps_acq_axi.sv
BUILD  := sim/build
NREG   ?= 24

.PHONY: all vectors sim sim_fft sim_directed sim_irq sim_regress syn clean

all: sim

vectors:
	$(PY) ../model/gen_vectors.py --regress $(NREG)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/tb_fft.vvp: rtl/sdf_stage.sv rtl/fft_sdf.sv tb/tb_fft.sv | $(BUILD)
	iverilog -g2012 -o $@ $^

$(BUILD)/tb_gps_acq.vvp: $(RTL) tb/tb_gps_acq.sv | $(BUILD)
	iverilog -g2012 -o $@ $^

sim_fft: $(BUILD)/tb_fft.vvp
	vvp -n $< | tee sim/log_fft.txt | grep -E "PASS|FAIL|latency"

sim_directed: $(BUILD)/tb_gps_acq.vvp
	vvp -n $< +VEC=sim/vectors/directed +CSV=sim/results_directed.csv | grep -v WARNING | tee sim/log_directed.txt

sim_irq: $(BUILD)/tb_gps_acq.vvp
	vvp -n $< +VEC=sim/vectors/directed +CSV=$(BUILD)/irq.csv +IRQ | grep -E "TB_GPS_ACQ"

sim_regress: $(BUILD)/tb_gps_acq.vvp
	vvp -n $< +VEC=sim/vectors/regress +CSV=sim/results_regress.csv +TRUTH_STAT | grep -v WARNING | tee sim/log_regress.txt | tail -6

sim: sim_fft sim_directed sim_irq sim_regress

syn:
	yosys -q -l syn/yosys.log syn/synth_xc7.ys
	@grep -A60 "=== gps_acq_axi ===" syn/yosys.log | grep -E "Number of cells|LUT|FD|DSP48|RAMB|SRL|CARRY|MUX" || true

clean:
	rm -rf $(BUILD) sim/log_*.txt sim/results_*.csv syn/yosys.log syn/*.json
