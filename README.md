# sv_project

Processador RISC-V **monociclo** (Parte 1) em SystemVerilog, com testbench
auto-verificável, compilado com [Icarus Verilog](https://steveicarus.github.io/iverilog/).

Instruções suportadas: `lw`, `sw`, `add`, `sub`, `and`, `or`, `slt`, `addi`, `beq`, `jal`.

## Structure

```
.
├── Makefile               # build / simulate / view waves / clean
├── riscvtest.s            # referência em assembly do programa de teste
├── src/
│   └── riscvsingle_p1.sv  # design: processador + memórias (programa embutido na imem)
└── tb/
    └── tb_riscvsingle.sv  # testbench auto-verificável (módulo `testbench`)
```

O programa de teste (o mesmo de `riscvtest.s`) já está embutido na `imem`,
então a simulação não precisa de arquivos externos.

## Usage

```sh
make sim    # compile and run the testbench
make wave   # run simulation and open the VCD waveform in GTKWave
make clean  # remove build artifacts
```

Equivalent manual commands:

```sh
iverilog -g2012 -o build/testbench.vvp -s testbench src/riscvsingle_p1.sv tb/tb_riscvsingle.sv
vvp build/testbench.vvp
```

## Expected result

O programa escreve o valor **25** no endereço **100** da memória de dados.
O testbench imprime:

```
Simulation succeeded
```

## Notes

- `iverilog -g2012` enables Icarus Verilog's SystemVerilog-2012 support
  (`logic`, `always_ff`, etc.). The "sorry: constant selects" messages during
  compilation are harmless warnings from Icarus, not errors.
- The testbench dumps `tb_riscvsingle.vcd` (via `$dumpfile`/`$dumpvars`),
  viewable with GTKWave.
