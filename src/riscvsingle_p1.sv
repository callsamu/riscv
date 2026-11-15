//COMPILE:  iverilog -g2012 -o build/testbench.vvp -s testbench src/riscvsingle_p1.sv
//SIMULATE: vvp -n build/testbench.vvp   (a partir da raiz do projeto, pois a imem
//          carrega o programa de riscvtest.txt via $readmemh)
//          Ou simplesmente: make sim
//
// Versão PIPELINE de 5 estágios (IF, ID, EX, MEM, WB) do riscvsingle,
// seguindo o datapath do SLIDE 66 (Patterson & Hennessy, Fig. 4.61):
//
//  - Hazards de dados entre instruções da ALU: Forwarding unit no estágio EX
//    (EX/MEM -> EX e MEM/WB -> EX), slides 45-55.
//  - Hazard de carga-uso (lw seguido de uso): Hazard detection unit em ID.
//    Congela PC e IF/ID (PCWrite = IFIDWrite = 0) e o mux "0" zera os sinais
//    de controle que entram em ID/EX, criando uma bolha (slides 57-60).
//  - Hazards de controle (beq/jal): o desvio é resolvido JÁ NO ESTÁGIO ID,
//    com o comparador "=" e o somador de alvo em ID. Se o desvio é tomado,
//    o sinal IF.Flush descarta a instrução buscada em IF (custo: 1 bolha
//    só quando tomado; não tomado não custa nada) - slides 63-66.
//  - Hazards de dados para o beq (o "=" em ID precisa dos operandos antes
//    do resto do pipeline): a Hazard detection unit também para o beq em ID
//    quando o operando ainda está sendo calculado (slides 67-69), e o valor
//    que está em EX/MEM é encaminhado para o comparador.
//
// Convenção de nomes: sufixo F=IF, D=ID, E=EX, M=MEM, W=WB indica o estágio
// em que o sinal é usado. Equivalências com os nomes do livro/slides:
//   Rs1D, Rs2D        = IF/ID.RegisterRs1, IF/ID.RegisterRs2
//   RdE, RegWriteE    = ID/EX.RegisterRd,  ID/EX.RegWrite
//   MemReadE          = ID/EX.MemRead
//   RdM, RegWriteM    = EX/MEM.RegisterRd, EX/MEM.RegWrite
//   RdW, RegWriteW    = MEM/WB.RegisterRd, MEM/WB.RegWrite

// =======================================================================
//  TESTBENCH (fornecido pelo professor, sem alterações de lógica)
// =======================================================================
// Gera o clock (período de 10 unidades) e o reset, e observa as escritas
// na memória de dados. O programa riscvtest.s deve terminar escrevendo 25
// no endereço 100. Escritas no endereço 96 são permitidas (é o sw
// intermediário do programa); qualquer outra escrita indica erro.
// Como as saídas de top são as do estágio MEM, o teste funciona igual no
// monociclo e no pipeline: só muda em qual ciclo a escrita acontece.
module testbench();

  logic        clk;
  logic        reset;

  logic [31:0] WriteData, DataAdr;
  logic        MemWrite;

  // instantiate device to be tested
  top dut(clk, reset, WriteData, DataAdr, MemWrite);

  // initialize test
  initial
    begin
      reset <= 1; # 22; reset <= 0;
    end

  // generate clock to sequence tests
  always
    begin
      clk <= 1; # 5; clk <= 0; # 5;
    end

  // check results
  always @(negedge clk)
    begin
      if(MemWrite) begin
        if(DataAdr === 100 & WriteData === 25) begin
          $display("Simulation succeeded");
          $stop;
        end else if (DataAdr !== 96) begin
          $display("Simulation failed");
          $stop;
        end
      end
    end
endmodule

// =======================================================================
//  TOP: processador + memória de instruções + memória de dados
// =======================================================================
// Memórias separadas para instruções e dados (como no slide 66): a imem é
// lida no estágio IF e a dmem é acessada no estágio MEM, então as duas
// podem ser usadas no mesmo ciclo sem hazard estrutural.
module top(input  logic        clk, reset,
           output logic [31:0] WriteData, DataAdr,
           output logic        MemWrite);

  logic [31:0] PC, Instr, ReadData;

  // instantiate processor and memories
  // ALTERADO: processador agora é o riscvpipelined; as saídas
  // DataAdr/WriteData/MemWrite são as do estágio MEM
  riscvpipelined rvpipe(clk, reset, PC, Instr, MemWrite, DataAdr,
                        WriteData, ReadData);
  imem imem(PC, Instr);
  dmem dmem(clk, MemWrite, DataAdr, WriteData, ReadData);
endmodule

// =======================================================================
//  PROCESSADOR PIPELINE: unidade de controle + datapath
// =======================================================================
// Interface igual à do monociclo (riscvsingle):
//   PC        -> endereço buscado na imem (estágio IF)
//   Instr     <- instrução lida da imem (estágio IF)
//   MemWrite, ALUResult (endereço), WriteData -> dmem (estágio MEM)
//   ReadData  <- dado lido da dmem (estágio MEM)
module riscvpipelined(input  logic        clk, reset,
                      output logic [31:0] PC,
                      input  logic [31:0] Instr,
                      output logic        MemWrite,
                      output logic [31:0] ALUResult, WriteData,
                      input  logic [31:0] ReadData);

  // sinais de controle gerados no estágio ID (sufixo D)
  logic       ALUSrcD, RegWriteD, JumpD, BranchD, MemWriteD;
  logic [1:0] ResultSrcD, ImmSrcD;
  logic [2:0] ALUControlD;
  // campos da instrução em ID, enviados ao controlador
  logic [6:0] opD;
  logic [2:0] funct3D;
  logic       funct7b5D;

  // O controlador ("Control" no slide 66) opera sobre a instrução que está
  // no estágio ID. Não recebe mais Zero: no slide 66 a decisão do beq é
  // feita pelo comparador "=" dentro do datapath, no próprio estágio ID.
  controller c(opD, funct3D, funct7b5D,
               ResultSrcD, MemWriteD, BranchD,
               ALUSrcD, RegWriteD, JumpD,
               ImmSrcD, ALUControlD);
  datapath dp(clk, reset,
              PC, Instr,
              opD, funct3D, funct7b5D,
              RegWriteD, ResultSrcD, MemWriteD, JumpD, BranchD,
              ALUControlD, ALUSrcD, ImmSrcD,
              MemWrite, ALUResult, WriteData, ReadData);
endmodule

// =======================================================================
//  CONTROLLER ("Control", a elipse azul no slide 66)
// =======================================================================
// Decodifica a instrução que está em ID e gera os sinais de controle. No
// pipeline esses sinais não são usados todos de uma vez: cada um viaja
// pelos registradores de pipeline junto com a sua instrução e é usado no
// estágio certo (ImmSrc/Branch/Jump em ID; ALUSrc/ALUControl em EX;
// MemWrite em MEM; RegWrite/ResultSrc em WB).
// É dividido, como no monociclo, em decodificador principal (maindec) e
// decodificador da ALU (aludec).
// ALTERADO: removidos Zero, PCSrc e a lógica de desvio; agora em ID (datapath)
module controller(input  logic [6:0] op,
                  input  logic [2:0] funct3,
                  input  logic       funct7b5,
                  output logic [1:0] ResultSrc,
                  output logic       MemWrite,
                  output logic       Branch, ALUSrc,
                  output logic       RegWrite, Jump,
                  output logic [1:0] ImmSrc,
                  output logic [2:0] ALUControl);

  logic [1:0] ALUOp;

  maindec md(op, ResultSrc, MemWrite, Branch,
             ALUSrc, RegWrite, Jump, ImmSrc, ALUOp);
  aludec  ad(op[5], funct3, funct7b5, ALUOp, ALUControl);
endmodule

// -----------------------------------------------------------------------
//  Decodificador principal: gera os sinais de controle a partir do opcode
// -----------------------------------------------------------------------
//   RegWrite  : 1 = a instrução escreve em rd                     (usado em WB)
//   ImmSrc    : formato do imediato: 00 I, 01 S, 10 B, 11 J        (usado em ID)
//   ALUSrc    : 2º operando da ALU: 0 = rs2, 1 = imediato          (usado em EX)
//   MemWrite  : 1 = escreve na memória de dados (sw)               (usado em MEM)
//   ResultSrc : valor escrito em rd: 00 = ALU, 01 = memória (lw),
//               10 = PC+4 (jal)                                    (usado em WB)
//   Branch    : 1 = beq; decidido pelo comparador "=" em ID         (usado em ID)
//   ALUOp     : 00 = soma (endereço de lw/sw), 01 = subtração (beq),
//               10 = operação definida por funct3/funct7 (aludec)   (usado em ID)
//   Jump      : 1 = jal; sempre tomado, decidido em ID              (usado em ID)
// Obs.: no pipeline o beq não usa mais a ALU (a comparação é feita pelo
// "=" em ID); o ALUOp = 01 do beq ficou só por compatibilidade.
module maindec(input  logic [6:0] op,
               output logic [1:0] ResultSrc,
               output logic       MemWrite,
               output logic       Branch, ALUSrc,
               output logic       RegWrite, Jump,
               output logic [1:0] ImmSrc,
               output logic [1:0] ALUOp);

  logic [10:0] controls;

  assign {RegWrite, ImmSrc, ALUSrc, MemWrite,
          ResultSrc, Branch, ALUOp, Jump} = controls;

  always_comb
    case(op)
    // RegWrite_ImmSrc_ALUSrc_MemWrite_ResultSrc_Branch_ALUOp_Jump
      7'b0000011: controls = 11'b1_00_1_0_01_0_00_0; // lw
      7'b0100011: controls = 11'b0_01_1_1_00_0_00_0; // sw
      7'b0110011: controls = 11'b1_xx_0_0_00_0_10_0; // R-type
      7'b0010011: controls = 11'b1_00_1_0_00_0_10_0; // I-type
      7'b1100011: controls = 11'b0_10_0_0_00_1_01_0; // beq
      7'b1101111: controls = 11'b1_11_0_0_10_0_xx_1; // jal
      default:    controls = 11'bx_xx_x_x_xx_x_xx_x; // non-implemented instruction
    endcase
endmodule

// -----------------------------------------------------------------------
//  Decodificador da ALU: escolhe a operação (ALUControl) da ALU
// -----------------------------------------------------------------------
//   ALUOp = 00 -> soma (cálculo de endereço de lw/sw)
//   ALUOp = 01 -> subtração (beq)
//   ALUOp = 10 -> R-type ou I-type: a operação vem de funct3; para
//                 funct3 = 000, funct7[5] separa add (0) de sub (1).
// opb5 (bit 5 do opcode) diferencia R-type (1) de I-type (0): no addi o
// bit 30 faz parte do imediato e não pode ser lido como "sub".
// Códigos de ALUControl: 000 add, 001 sub, 010 and, 011 or, 101 slt.
module aludec(input  logic       opb5,
              input  logic [2:0] funct3,
              input  logic       funct7b5,
              input  logic [1:0] ALUOp,
              output logic [2:0] ALUControl);

  logic  RtypeSub;
  assign RtypeSub = funct7b5 & opb5;  // 1 somente para o sub do tipo R

  always_comb
    case(ALUOp)
      2'b00:                ALUControl = 3'b000; // addition
      2'b01:                ALUControl = 3'b001; // subtraction
      default: case(funct3) // R-type or I-type ALU
                 3'b000:  if (RtypeSub)
                            ALUControl = 3'b001; // sub
                          else
                            ALUControl = 3'b000; // add, addi
                 3'b010:    ALUControl = 3'b101; // slt, slti
                 3'b110:    ALUControl = 3'b011; // or, ori
                 3'b111:    ALUControl = 3'b010; // and, andi
                 default:   ALUControl = 3'bxxx; // ???
               endcase
    endcase
endmodule

// ALTERADO: datapath reescrito em 5 estágios, com registradores de
// pipeline, Hazard detection unit, IF.Flush e desvio resolvido em ID
// (slide 66). Sufixos: F=IF, D=ID, E=EX, M=MEM, W=WB
module datapath(input  logic        clk, reset,
                // IF
                output logic [31:0] PCF,
                input  logic [31:0] InstrF,
                // ID <-> controlador
                output logic [6:0]  opD,
                output logic [2:0]  funct3D,
                output logic        funct7b5D,
                input  logic        RegWriteD,
                input  logic [1:0]  ResultSrcD,
                input  logic        MemWriteD, JumpD, BranchD,
                input  logic [2:0]  ALUControlD,
                input  logic        ALUSrcD,
                input  logic [1:0]  ImmSrcD,
                // MEM <-> memória de dados
                output logic        MemWriteM,
                output logic [31:0] ALUResultM, WriteDataM,
                input  logic [31:0] ReadDataM);

  // ---------------- declarações ----------------
  // IF
  logic [31:0] PCNextF, PCPlus4F;
  // ID
  logic [31:0] InstrD, PCD, PCPlus4D, RD1D, RD2D, ImmExtD;
  logic [4:0]  Rs1D, Rs2D, RdD;
  logic [31:0] PCTargetD;            // saída do somador de alvo em ID
  logic [31:0] CmpAD, CmpBD;         // entradas do comparador "="
  logic        ForwardAD, ForwardBD; // encaminhamento EX/MEM -> "="
  logic        EqualD;               // saída do comparador "="
  logic        PCSrcD;               // 1 = desvio/jal tomado: PC <- PCTargetD
  logic [7:0]  CtrlD, CtrlIDEX;      // sinais de controle antes/depois do mux "0"
  // EX
  logic        RegWriteE, MemWriteE, ALUSrcE, MemReadE;
  logic [1:0]  ResultSrcE;
  logic [2:0]  ALUControlE;
  logic [31:0] RD1E, RD2E, ImmExtE, PCPlus4E;
  logic [4:0]  Rs1E, Rs2E, RdE;
  logic [31:0] SrcAE, SrcBE, WriteDataE, ALUResultE;
  logic        ZeroE;                // não usado: o beq é decidido em ID
  // MEM
  logic        RegWriteM, MemReadM;
  logic [1:0]  ResultSrcM;
  logic [31:0] PCPlus4M, FwdValueM;
  logic [4:0]  RdM;
  // WB
  logic        RegWriteW;
  logic [1:0]  ResultSrcW;
  logic [31:0] ALUResultW, ReadDataW, PCPlus4W, ResultW;
  logic [4:0]  RdW;
  // hazards
  logic [1:0]  ForwardAE, ForwardBE; // Forwarding unit (EX)
  logic        PCWrite, IFIDWrite;   // Hazard detection unit -> PC e IF/ID
  logic        CtrlMuxSel;           // Hazard detection unit -> mux "0"
  logic        IFFlush;              // IF.Flush -> IF/ID

  // MemRead não é um sinal separado no nosso maindec: a única instrução que
  // lê a memória de dados é o lw, que é identificado por ResultSrc = 01
  // (resultado vem da memória). Então MemRead == (ResultSrc == 01).
  assign MemReadE = (ResultSrcE == 2'b01);   // ID/EX.MemRead
  assign MemReadM = (ResultSrcM == 2'b01);   // EX/MEM.MemRead

  // =====================================================================
  //  HAZARD DETECTION UNIT  (caixa azul no topo do slide 66)
  // =====================================================================
  // Observa a instrução em ID (IF/ID.RegisterRs1/Rs2) e as instruções à
  // frente dela (ID/EX e EX/MEM). Se a instrução em ID precisa de um valor
  // que ainda não pode ser obtido nem por forwarding, ela gera o stall:
  //   PCWrite   = 0 -> PC não muda (a próxima instrução é buscada de novo)
  //   IFIDWrite = 0 -> IF/ID não muda (a instrução em ID é decodificada de novo)
  //   CtrlMuxSel= 1 -> o mux "0" zera o controle de ID/EX (bolha / nop em EX)
  hazard_detection_unit hdu(Rs1D, Rs2D, BranchD,
                            RdE, MemReadE, RegWriteE,
                            RdM, MemReadM,
                            PCWrite, IFIDWrite, CtrlMuxSel);

  // =====================================================================
  //  FORWARDING UNIT  (caixa azul embaixo, estágio EX, no slide 66)
  // =====================================================================
  // Slides 47-55. Para cada operando da ALU:
  //   10 = encaminha de EX/MEM (resultado da ALU anterior)
  //   01 = encaminha de MEM/WB (dado da memória ou ALU de 2 instruções antes)
  //   00 = usa o valor lido do banco de registradores
  // EX/MEM tem prioridade sobre MEM/WB (risco de dados duplo, slide 54-55).
  always_comb begin
    ForwardAE = 2'b00;
    ForwardBE = 2'b00;
    if      ((Rs1E != 0) & (Rs1E == RdM) & RegWriteM) ForwardAE = 2'b10;
    else if ((Rs1E != 0) & (Rs1E == RdW) & RegWriteW) ForwardAE = 2'b01;
    if      ((Rs2E != 0) & (Rs2E == RdM) & RegWriteM) ForwardBE = 2'b10;
    else if ((Rs2E != 0) & (Rs2E == RdW) & RegWriteW) ForwardBE = 2'b01;
  end

  // =====================================================================
  //  IF - busca da instrução
  // =====================================================================
  // PC: só é atualizado quando PCWrite = 1 (sem stall da Hazard detection
  // unit). O mux à esquerda do PC (slide 66) escolhe entre PC+4 e o alvo
  // do desvio calculado em ID.
  flopenrc #(32) pcreg(clk, reset, PCWrite, 1'b0, PCNextF, PCF);
  adder          pcadd4(PCF, 32'd4, PCPlus4F);
  mux2 #(32)     pcmux(PCPlus4F, PCTargetD, PCSrcD, PCNextF);

  // =====================================================================
  //  IF/ID - registrador de pipeline
  // =====================================================================
  //  - enable  = IFIDWrite (Hazard detection unit): em stall, mantém a
  //    instrução para que ela seja decodificada de novo no próximo ciclo.
  //  - clear   = IF.Flush: quando o desvio em ID é tomado, a instrução que
  //    acabou de ser buscada (PC+4 do desvio) é descartada e vira uma bolha.
  //    Usamos nop = addi x0,x0,0 (0x00000013) como "instrução zerada": com
  //    32'b0 o opcode seria inválido e o maindec geraria controles 'x'.
  flopenrc #(32, 32'h00000013) ifid_instr(clk, reset, IFIDWrite, IFFlush, InstrF, InstrD);
  flopenrc #(64)               ifid_pc(clk, reset, IFIDWrite, IFFlush,
                                       {PCF, PCPlus4F}, {PCD, PCPlus4D});

  // =====================================================================
  //  ID - decodificação, leitura de registradores e DECISÃO DO DESVIO
  // =====================================================================
  assign opD       = InstrD[6:0];
  assign funct3D   = InstrD[14:12];
  assign funct7b5D = InstrD[30];
  assign Rs1D      = InstrD[19:15];
  assign Rs2D      = InstrD[24:20];
  assign RdD       = InstrD[11:7];

  regfile rf(clk, RegWriteW, Rs1D, Rs2D, RdW, ResultW, RD1D, RD2D);
  extend  ext(InstrD[31:7], ImmSrcD, ImmExtD);

  // Somador de alvo em ID (o "+" acima de Registers no slide 66).
  // No slide aparece um "Shift left 1" antes do somador; aqui ele já está
  // embutido no extend, que monta o imediato do tipo B/J com o bit 0 = 0.
  adder pcaddbranch(PCD, ImmExtD, PCTargetD);

  // Comparador "=" em ID (entre as saídas de Registers no slide 66).
  // Como ele trabalha 2 estágios antes da ALU, também precisa de
  // forwarding (slide 67): se a instrução em EX/MEM escreve o registrador
  // que o beq lê, usamos o valor de EX/MEM em vez do valor do banco.
  // (Se o produtor estiver em WB, o próprio regfile entrega o valor novo,
  // pois escreve e lê no mesmo ciclo - ver regfile.)
  // Para jal em MEM o valor escrito é PC+4, não o resultado da ALU.
  assign FwdValueM = (ResultSrcM == 2'b10) ? PCPlus4M : ALUResultM;
  assign ForwardAD = RegWriteM & (RdM != 0) & (RdM == Rs1D);
  assign ForwardBD = RegWriteM & (RdM != 0) & (RdM == Rs2D);
  mux2 #(32) cmpamux(RD1D, FwdValueM, ForwardAD, CmpAD);
  mux2 #(32) cmpbmux(RD2D, FwdValueM, ForwardBD, CmpBD);
  assign EqualD = (CmpAD == CmpBD);

  // Decisão do desvio: beq com operandos iguais, ou jal (sempre tomado).
  // Só vale se a instrução em ID não estiver parada pela Hazard detection
  // unit (IFIDWrite = 1); em stall os operandos ainda não são confiáveis,
  // e o beq será reavaliado no próximo ciclo.
  assign PCSrcD  = ((BranchD & EqualD) | JumpD) & IFIDWrite;

  // IF.Flush (sinal azul à esquerda no slide 66): se o desvio é tomado, a
  // instrução que está sendo buscada em IF neste ciclo está errada e é
  // descartada na próxima borda (IF/ID <- nop). É a "Bubble (nop)" que
  // aparece no estágio ID no "Clock 4" do slide 66.
  assign IFFlush = PCSrcD;

  // Mux "0" entre Control e ID/EX (slide 66): em stall, os sinais de
  // controle que entram em ID/EX são zerados (RegWrite = MemWrite = 0),
  // então a instrução que segue para EX é uma bolha que não altera nada.
  // Agrupamento como no slide:  WB = {RegWrite, ResultSrc}
  //                             M  = {MemWrite}   (MemRead = ResultSrc==01)
  //                             EX = {ALUControl, ALUSrc}
  assign CtrlD = {RegWriteD, ResultSrcD, MemWriteD, ALUControlD, ALUSrcD};
  mux2 #(8) ctrlmux(CtrlD, 8'b0, CtrlMuxSel, CtrlIDEX);

  // =====================================================================
  //  ID/EX - registrador de pipeline
  // =====================================================================
  // Branch/Jump/PC não precisam mais seguir para EX: o desvio já foi
  // resolvido em ID. PC+4 segue até WB porque é o valor escrito pelo jal.
  flopenrc #(8) idex_ctrl(clk, reset, 1'b1, 1'b0, CtrlIDEX,
                          {RegWriteE, ResultSrcE, MemWriteE, ALUControlE, ALUSrcE});
  flopenrc #(143) idex_data(clk, reset, 1'b1, 1'b0,
                            {RD1D, RD2D, ImmExtD, PCPlus4D, Rs1D, Rs2D, RdD},
                            {RD1E, RD2E, ImmExtE, PCPlus4E, Rs1E, Rs2E, RdE});

  // =====================================================================
  //  EX - execução
  // =====================================================================
  // forwarding: 00 = regfile, 01 = ResultW (MEM/WB), 10 = ALUResultM (EX/MEM)
  mux3 #(32) fwdamux(RD1E, ResultW, ALUResultM, ForwardAE, SrcAE);
  mux3 #(32) fwdbmux(RD2E, ResultW, ALUResultM, ForwardBE, WriteDataE); // também é o dado do sw
  mux2 #(32) srcbmux(WriteDataE, ImmExtE, ALUSrcE, SrcBE);
  alu        alu(SrcAE, SrcBE, ALUControlE, ALUResultE, ZeroE);

  // =====================================================================
  //  EX/MEM - registrador de pipeline
  // =====================================================================
  flopenrc #(4) exmem_ctrl(clk, reset, 1'b1, 1'b0,
                           {RegWriteE, ResultSrcE, MemWriteE},
                           {RegWriteM, ResultSrcM, MemWriteM});
  flopenrc #(101) exmem_data(clk, reset, 1'b1, 1'b0,
                             {ALUResultE, WriteDataE, PCPlus4E, RdE},
                             {ALUResultM, WriteDataM, PCPlus4M, RdM});

  // =====================================================================
  //  MEM/WB - registrador de pipeline
  // =====================================================================
  flopenrc #(3) memwb_ctrl(clk, reset, 1'b1, 1'b0,
                           {RegWriteM, ResultSrcM},
                           {RegWriteW, ResultSrcW});
  flopenrc #(101) memwb_data(clk, reset, 1'b1, 1'b0,
                             {ALUResultM, ReadDataM, PCPlus4M, RdM},
                             {ALUResultW, ReadDataW, PCPlus4W, RdW});

  // =====================================================================
  //  WB - escrita no banco de registradores
  // =====================================================================
  mux3 #(32) resultmux(ALUResultW, ReadDataW, PCPlus4W, ResultSrcW, ResultW);
endmodule

// =======================================================================
//  HAZARD DETECTION UNIT  (slide 66, caixa "Hazard detection unit")
// =======================================================================
// Decide, olhando a instrução que está em ID, se ela pode avançar para EX
// neste ciclo. Se não puder, gera um stall de 1 ciclo:
//   PCWrite    = 0  (fio azul que vai da unidade até o PC)
//   IFIDWrite  = 0  (fio azul que vai da unidade até IF/ID)
//   CtrlMuxSel = 1  (fio que vai da unidade até o mux "0" antes de ID/EX)
//
// Casos de stall:
//  (1) Carga-uso (slide 58):
//        ID/EX.MemRead and
//        ((ID/EX.RegisterRd = IF/ID.RegisterRs1) or
//         (ID/EX.RegisterRd = IF/ID.RegisterRs2))
//      O lw só terá o dado no fim do estágio MEM; a instrução em ID espera 1
//      ciclo e depois recebe o dado pela Forwarding unit (MEM/WB -> EX).
//
//  (2) beq depende da instrução IMEDIATAMENTE anterior (slide 68), que está
//      em EX: o resultado da ALU ainda não existe quando o "=" (em ID) precisa
//      dele. 1 stall; no ciclo seguinte o valor está em EX/MEM e é encaminhado
//      para o comparador. (Se essa instrução for um lw, o caso (1) também
//      dispara, e o caso (3) faz o segundo stall.)
//
//  (3) beq depende de um lw que está em MEM (slide 69, segundo stall): o
//      dado da memória só fica pronto no fim do ciclo, tarde demais para o
//      "=" em ID. Mais 1 stall; no ciclo seguinte o lw está em WB e o
//      regfile entrega o valor. Total: 2 stalls para lw imediatamente antes
//      de um beq que usa o registrador carregado.
//
// O teste "!= 0" evita stalls falsos com x0 (que nunca é escrito).
module hazard_detection_unit(input  logic [4:0] Rs1D, Rs2D, // IF/ID.RegisterRs1, IF/ID.RegisterRs2
                             input  logic       BranchD,    // instrução em ID é beq
                             input  logic [4:0] RdE,        // ID/EX.RegisterRd
                             input  logic       MemReadE,   // ID/EX.MemRead
                             input  logic       RegWriteE,  // ID/EX.RegWrite
                             input  logic [4:0] RdM,        // EX/MEM.RegisterRd
                             input  logic       MemReadM,   // EX/MEM.MemRead
                             output logic       PCWrite,    // 0 = congela o PC
                             output logic       IFIDWrite,  // 0 = congela IF/ID
                             output logic       CtrlMuxSel);// 1 = bolha em ID/EX

  logic useE, useM;          // instrução em ID lê o Rd de EX / de MEM?
  logic loadUseStall;        // caso (1)
  logic branchStallE;        // caso (2)
  logic branchStallM;        // caso (3)
  logic stall;

  assign useE = (RdE != 0) & ((RdE == Rs1D) | (RdE == Rs2D));
  assign useM = (RdM != 0) & ((RdM == Rs1D) | (RdM == Rs2D));

  assign loadUseStall = MemReadE & useE;
  assign branchStallE = BranchD  & RegWriteE & useE;
  assign branchStallM = BranchD  & MemReadM  & useM;

  assign stall = loadUseStall | branchStallE | branchStallM;

  assign PCWrite    = ~stall;
  assign IFIDWrite  = ~stall;
  assign CtrlMuxSel =  stall;
endmodule

// =======================================================================
//  BANCO DE REGISTRADORES ("Registers" no slide 66)
// =======================================================================
// 32 registradores de 32 bits, com 3 portas:
//   - 2 portas de leitura combinacionais (a1 -> rd1, a2 -> rd2), usadas
//     pela instrução em ID (rs1 e rs2);
//   - 1 porta de escrita na borda de subida (a3, wd3, we3), usada pela
//     instrução em WB (rd, ResultW, RegWriteW).
// O registrador x0 sempre lê 0.
module regfile(input  logic        clk,
               input  logic        we3,
               input  logic [ 4:0] a1, a2, a3,
               input  logic [31:0] wd3,
               output logic [31:0] rd1, rd2);

  logic [31:0] rf[31:0];

  always_ff @(posedge clk)
    if (we3) rf[a3] <= wd3;

  // ALTERADO: bypass WB->ID. No livro o banco escreve na 1a metade do ciclo
  // e lê na 2a metade; como aqui a escrita é na borda de subida, uma
  // instrução em ID que lê o registrador sendo escrito por WB no mesmo ciclo
  // veria o valor antigo. O bypass entrega wd3 diretamente (mesmo efeito).
  assign rd1 = (a1 != 0) ? ((we3 & (a1 == a3)) ? wd3 : rf[a1]) : 0;
  assign rd2 = (a2 != 0) ? ((we3 & (a2 == a3)) ? wd3 : rf[a2]) : 0;
endmodule

// Somador de 32 bits: usado para PC+4 (IF) e para o alvo PC+imediato (ID).
module adder(input  [31:0] a, b,
             output [31:0] y);

  assign y = a + b;
endmodule

// =======================================================================
//  GERADOR DE IMEDIATO ("Imm Gen" no slide 66)
// =======================================================================
// Monta o imediato de 32 bits com extensão de sinal (instr[31] é sempre o
// bit de sinal). Cada formato espalha os bits do imediato de um jeito
// diferente na instrução, por isso o ImmSrc escolhe a montagem.
// Nos tipos B e J o bit 0 do deslocamento é sempre 0 (instruções têm
// endereço par), e por isso não é guardado na instrução: aqui ele é
// recolocado com o 1'b0 no fim. Isso faz o papel do "Shift left 1" que
// aparece antes do somador de desvio no slide 66.
module extend(input  logic [31:7] instr,
              input  logic [1:0]  immsrc,
              output logic [31:0] immext);

  always_comb
    case(immsrc)
      // Tipo I (addi, lw): imm[11:0] = instr[31:20]
      2'b00:   immext = {{20{instr[31]}}, instr[31:20]};
      // Tipo S (sw): imm[11:5] = instr[31:25], imm[4:0] = instr[11:7]
      2'b01:   immext = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      // Tipo B (beq): imm[12|10:5|4:1|11], bit 0 = 0
      2'b10:   immext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
      // Tipo J (jal): imm[20|10:1|11|19:12], bit 0 = 0
      2'b11:   immext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
      default: immext = 32'bx; // formato não definido
    endcase
endmodule

// ALTERADO: registrador de pipeline com reset assíncrono, enable (en) e
// clear síncrono (clear). Em stall (en=0) mantém o valor; em flush
// (clear=1) carrega RESETVAL (bolha). en tem prioridade sobre clear.
module flopenrc #(parameter WIDTH = 8, parameter [WIDTH-1:0] RESETVAL = 0)
                 (input  logic             clk, reset, en, clear,
                  input  logic [WIDTH-1:0] d,
                  output logic [WIDTH-1:0] q);

  always_ff @(posedge clk, posedge reset)
    if (reset)      q <= RESETVAL;
    else if (en) begin
      if (clear)    q <= RESETVAL;
      else          q <= d;
    end
endmodule

// Multiplexador 2:1 parametrizável: s = 0 -> d0, s = 1 -> d1.
// Usado no mux do PC, no ALUSrc, no mux "0" de controle e nas entradas
// do comparador "=".
module mux2 #(parameter WIDTH = 8)
             (input  logic [WIDTH-1:0] d0, d1,
              input  logic             s,
              output logic [WIDTH-1:0] y);

  assign y = s ? d1 : d0;
endmodule

// Multiplexador 3:1 parametrizável: s = 00 -> d0, 01 -> d1, 1x -> d2.
// Usado nos muxes de forwarding de EX (ForwardA/ForwardB) e no mux de
// resultado de WB (ALU / memória / PC+4).
module mux3 #(parameter WIDTH = 8)
             (input  logic [WIDTH-1:0] d0, d1, d2,
              input  logic [1:0]       s,
              output logic [WIDTH-1:0] y);

  assign y = s[1] ? d2 : (s[0] ? d1 : d0);
endmodule

// =======================================================================
//  MEMÓRIA DE INSTRUÇÕES ("Instruction memory" no slide 66)
// =======================================================================
// 64 palavras de 32 bits, carregadas do arquivo riscvtest.txt (hexa).
// Leitura combinacional: a instrução do endereço PC sai no mesmo ciclo.
// a[31:2] converte endereço em bytes para índice de palavra (alinhado).
module imem(input  logic [31:0] a,
            output logic [31:0] rd);

  logic [31:0] RAM[63:0];

  initial
      $readmemh("riscvtest.txt",RAM);

  assign rd = RAM[a[31:2]]; // acesso alinhado em palavra
endmodule

// =======================================================================
//  MEMÓRIA DE DADOS ("Data memory" no slide 66)
// =======================================================================
// 64 palavras de 32 bits. Leitura combinacional (lw recebe o dado ainda no
// estágio MEM) e escrita na borda de subida quando we = 1 (sw).
module dmem(input  logic        clk, we,
            input  logic [31:0] a, wd,
            output logic [31:0] rd);

  logic [31:0] RAM[63:0];

  assign rd = RAM[a[31:2]]; // acesso alinhado em palavra

  always_ff @(posedge clk)
    if (we) RAM[a[31:2]] <= wd;
endmodule

// =======================================================================
//  ALU ("ALU" no estágio EX do slide 66)
// =======================================================================
// Operações (alucontrol): 000 add, 001 sub, 010 and, 011 or, 100 xor,
// 101 slt, 110 sll, 111 srl.
// Soma e subtração usam o mesmo somador: na subtração b é invertido e
// soma-se 1 (complemento de 2), ou seja, a - b = a + ~b + 1.
// slt: a < b se o sinal de (a - b) for 1, corrigido pelo overflow (v).
// zero = 1 quando o resultado é 0 (não é mais usado pelo beq, que agora
// compara em ID, mas foi mantido do monociclo).
module alu(input  logic [31:0] a, b,
           input  logic [2:0]  alucontrol,
           output logic [31:0] result,
           output logic        zero);

  logic [31:0] condinvb, sum;
  logic        v;              // overflow da soma/subtração
  logic        isAddSub;       // 1 quando a operação é add ou sub

  assign condinvb = alucontrol[0] ? ~b : b;      // inverte b na subtração
  assign sum = a + condinvb + alucontrol[0];     // +1 completa o complemento de 2
  assign isAddSub = ~alucontrol[2] & ~alucontrol[1] |
                    ~alucontrol[1] & alucontrol[0];

  always_comb
    case (alucontrol)
      3'b000:  result = sum;         // add
      3'b001:  result = sum;         // subtract
      3'b010:  result = a & b;       // and
      3'b011:  result = a | b;       // or
      3'b100:  result = a ^ b;       // xor
      3'b101:  result = sum[31] ^ v; // slt
      3'b110:  result = a << b[4:0]; // sll
      3'b111:  result = a >> b[4:0]; // srl
      default: result = 32'bx;
    endcase

  assign zero = (result == 32'b0);
  assign v = ~(alucontrol[0] ^ a[31] ^ b[31]) & (a[31] ^ sum[31]) & isAddSub;

endmodule
