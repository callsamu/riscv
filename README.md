# sv_project

Processador RISC-V **monociclo** (Parte 1) em SystemVerilog, com testbench
auto-verificável, compilado com [Icarus Verilog](https://steveicarus.github.io/iverilog/).

Instruções suportadas: `lw`, `sw`, `add`, `sub`, `and`, `or`, `slt`, `addi`, `beq`, `jal`.

## Estrutura

```
.
├── Makefile              # compilar / simular / limpar
├── riscvtest.s           # programa de teste em assembly (referência)
├── riscvtest.txt         # mesmo programa em hexadecimal, carregado pela imem
└── src/
    └── riscvsingle_p1.sv # testbench + processador + memórias (arquivo único)
```

## Uso

```sh
make sim    # compila e executa a simulação
make clean  # remove os artefatos de build
```

Comandos manuais equivalentes (a partir da raiz do projeto):

```sh
iverilog -g2012 -o build/testbench.vvp -s testbench src/riscvsingle_p1.sv
vvp -n build/testbench.vvp
```

## Resultado esperado

O programa de teste termina escrevendo o valor **25** no endereço **100** da
memória de dados. O testbench verifica essa escrita e imprime:

```
Simulation succeeded
```

## Notas

- A `imem` carrega o programa com `$readmemh("riscvtest.txt", RAM)`. O caminho é
  relativo ao diretório de execução, então rode o `vvp` a partir da raiz do
  projeto (o Makefile já faz isso).
- `-g2012` habilita o suporte a SystemVerilog-2012 do Icarus (`logic`,
  `always_ff`, `always_comb`, etc.).
- `vvp -n` executa em modo não interativo, fazendo o `$stop` do testbench
  encerrar a simulação em vez de abrir um prompt.
- Os avisos `sorry: constant selects in always_* processes...` do Icarus são
  informativos e não afetam o resultado da simulação.
