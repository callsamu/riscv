# Tools
IVERILOG = iverilog -g2012
VVP      = vvp -n

# Project files (testbench included in the same source)
SRC   = src/riscvsingle_p1.sv
TOP   = testbench
BUILD = build
BIN   = $(BUILD)/$(TOP).vvp

.PHONY: all sim clean

all: sim

$(BIN): $(SRC) riscvtest.txt
	@mkdir -p $(BUILD)
	$(IVERILOG) -o $(BIN) -s $(TOP) $(SRC)

# riscvtest.txt is loaded with $readmemh, so run from the project root
sim: $(BIN)
	$(VVP) $(BIN)

clean:
	rm -rf $(BUILD)
