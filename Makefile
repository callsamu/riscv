# Tools
IVERILOG = iverilog -g2012
VVP      = vvp

# Project files
SRC   = src/riscvsingle_p1.sv
TB    = tb/tb_riscvsingle.sv
TOP   = testbench
BUILD = build
BIN   = $(BUILD)/$(TOP).vvp
VCD   = tb_riscvsingle.vcd

.PHONY: all sim wave clean

all: sim

$(BIN): $(SRC) $(TB)
	@mkdir -p $(BUILD)
	$(IVERILOG) -o $(BIN) -s $(TOP) $(SRC) $(TB)

sim: $(BIN)
	$(VVP) $(BIN)

wave: sim
	gtkwave $(VCD) &

clean:
	rm -rf $(BUILD) $(VCD)
