ROOT := ../..
SRCS := stubs.v tb_msu.sv \
	$(ROOT)/target/pocket/msu_apf.sv \
	$(ROOT)/target/pocket/core_bridge_cmd.v \
	$(ROOT)/platform/pocket/common.v \
	$(ROOT)/rtl/mister_top/msu_pocket.sv \
	$(ROOT)/rtl/upstream/chip/MSU1/MSU.sv \
	$(ROOT)/rtl/upstream/chip/MSU1/msu_audio.v \
	$(ROOT)/rtl/upstream/chip/MSU1/msu_fifo.v

CASES := le_msu be_msu le_nomsu le_swap be_swap le_stream be_stream srb
le_msu_P   := -GLITTLE=1 -GHAVE_MSU=1
be_msu_P   := -GLITTLE=0 -GHAVE_MSU=1
le_nomsu_P := -GLITTLE=1 -GHAVE_MSU=0
le_swap_P  := -GLITTLE=1 -GHAVE_MSU=1 -GSTRUCT_SWAP=1
be_swap_P  := -GLITTLE=0 -GHAVE_MSU=1 -GSTRUCT_SWAP=1
le_stream_P := -GLITTLE=1 -GHAVE_MSU=1 -GSTREAM=1
be_stream_P := -GLITTLE=0 -GHAVE_MSU=1 -GSTREAM=1
srb_P       := -GLITTLE=0 -GHAVE_MSU=1 -GSTREAM=1 -GSRB=1 -DSRB_SIM

# Upstream and Analogue sources rely on Quartus leniency (use before declaration,
# procedural assignment to output wires), hence Verilator and these waivers.
VFLAGS := --binary --timing -j 0 --top-module tb_msu -Wno-fatal -Wno-PROCASSWIRE \
	-Wno-WIDTH -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-TIMESCALEMOD \
	-Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNUSED -Wno-DECLFILENAME -Wno-LATCH

all: $(CASES)

$(CASES): %: build/%/Vtb_msu
	$< | tee build/$@.log | grep -E "PASS|FAIL|checked|played|looped|probe|streamed|SRB"
	@grep -q "^PASS" build/$@.log

build/%/Vtb_msu: $(SRCS) | build
	verilator $(VFLAGS) $($*_P) --Mdir build/$* $(SRCS) > build/$*.verilator.log 2>&1 || (tail -40 build/$*.verilator.log; false)

build:
	mkdir -p build

clean:
	rm -rf build *.vcd

.PHONY: all clean $(CASES)
