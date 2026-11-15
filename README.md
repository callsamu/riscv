# sv_project

Processador RISC-V **pipeline de 5 estágios** (Parte 2) em SystemVerilog, com
testbench auto-verificável, compilado com [Icarus Verilog](https://steveicarus.github.io/iverilog/).
Implementa o datapath do **slide 66** da aula de pipeline (Patterson & Hennessy,
Fig. 4.61), a partir do monociclo da Parte 1.

Instruções suportadas: `lw`, `sw`, `add`, `sub`, `and`, `or`, `slt`, `addi`, `beq`, `jal`.

## Arquitetura (slide 66)

| Elemento da figura | No código |
|---|---|
| Registradores IF/ID, ID/EX, EX/MEM, MEM/WB | `flopenrc` (com enable para stall e clear para flush) |
| Control | `controller` (`maindec` + `aludec`), opera sobre a instrução em ID |
| Mux "0" antes de ID/EX | `ctrlmux`: zera os sinais de controle para criar uma bolha |
| Hazard detection unit | `hazard_detection_unit`: gera `PCWrite`, `IFIDWrite` e o seletor do mux "0" |
| Comparador "=" e somador de alvo em ID | `EqualD` e `pcaddbranch`: `beq`/`jal` decididos em ID |
| IF.Flush | `IFFlush`: desvio tomado descarta a instrução buscada (IF/ID vira nop) |
| Forwarding unit | bloco `always_comb` em EX: `ForwardAE`/`ForwardBE` (EX/MEM e MEM/WB) |

Custo dos hazards:

- Dependência entre instruções da ALU: 0 ciclos (forwarding).
- Carga-uso (`lw` seguido de uso): 1 stall.
- `beq` logo após uma instrução da ALU que escreve o registrador comparado: 1 stall.
- `beq` logo após um `lw` do registrador comparado: 2 stalls.
- Desvio tomado ou `jal`: 1 bolha (IF.Flush). Desvio não tomado: 0 ciclos.

## Estrutura

```
.
├── Makefile              # compilar / simular / limpar
├── riscvtest.s           # programa de teste em assembly (referência)
├── riscvtest.txt         # mesmo programa em hexadecimal, carregado pela imem
└── src/
    └── riscvsingle_p1.sv # testbench + processador pipeline + memórias (arquivo único)
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
