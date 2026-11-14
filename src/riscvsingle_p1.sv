//COMPILE:  iverilog -g2012 -o build/testbench.vvp -s testbench src/riscvpipelined.sv
//SIMULATE: vvp -n build/testbench.vvp   (a partir da raiz do projeto, pois a imem
//          carrega o programa de riscvtest.txt via $readmemh)
//
// Versão PIPELINE de 5 estágios (IF, ID, EX, MEM, WB) do riscvsingle.
//  - Hazards de dados: forwarding (MEM->EX e WB->EX)
//  - Hazard de load (lw): forwarding + 1 stall
//  - Hazards de controle (beq/jal): resolvidos no estágio EX; o pipeline
//    para assim que o desvio é decodificado (2 bolhas, sempre, tomado ou não)
//  - Escrita do regfile em posedge, com bypass interno WB->ID

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

  // ALTERADO: o controlador agora opera sobre a instrução do estágio ID
  // e não possui mais Zero/PCSrc (o desvio é resolvido em EX, no datapath)
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

// ALTERADO: removidos Zero, PCSrc e a lógica de desvio; agora em EX
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

module aludec(input  logic       opb5,
              input  logic [2:0] funct3,
              input  logic       funct7b5, 
              input  logic [1:0] ALUOp,
              output logic [2:0] ALUControl);

  logic  RtypeSub;
  assign RtypeSub = funct7b5 & opb5;  // TRUE for R-type subtract instruction

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
// pipeline e unidade de hazards. Sufixos: F=IF, D=ID, E=EX, M=MEM, W=WB
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
  // EX
  logic        RegWriteE, MemWriteE, JumpE, BranchE, ALUSrcE;
  logic [1:0]  ResultSrcE;
  logic [2:0]  ALUControlE;
  logic [31:0] RD1E, RD2E, PCE, ImmExtE, PCPlus4E;
  logic [4:0]  Rs1E, Rs2E, RdE;
  logic [31:0] SrcAE, SrcBE, WriteDataE, ALUResultE, PCTargetE;
  logic        ZeroE, PCSrcE;
  // MEM
  logic        RegWriteM;
  logic [1:0]  ResultSrcM;
  logic [31:0] PCPlus4M;
  logic [4:0]  RdM;
  // WB
  logic        RegWriteW;
  logic [1:0]  ResultSrcW;
  logic [31:0] ALUResultW, ReadDataW, PCPlus4W, ResultW;
  logic [4:0]  RdW;
  // hazards
  logic [1:0]  ForwardAE, ForwardBE;
  logic        lwStall, ctrlHazD, ctrlHazE;
  logic        StallF, StallD, FlushD, FlushE;

  // ---------------- unidade de hazards ----------------
  // Forwarding: MEM->EX (10) tem prioridade sobre WB->EX (01)
  always_comb begin
    ForwardAE = 2'b00;
    ForwardBE = 2'b00;
    if      ((Rs1E != 0) & (Rs1E == RdM) & RegWriteM) ForwardAE = 2'b10;
    else if ((Rs1E != 0) & (Rs1E == RdW) & RegWriteW) ForwardAE = 2'b01;
    if      ((Rs2E != 0) & (Rs2E == RdM) & RegWriteM) ForwardBE = 2'b10;
    else if ((Rs2E != 0) & (Rs2E == RdW) & RegWriteW) ForwardBE = 2'b01;
  end

  // Load-use: lw em EX (ResultSrc=01) e instrução em ID usa o seu rd.
  // Para PC e IF/ID por 1 ciclo e injeta bolha em ID/EX. Depois do stall
  // o dado do lw é encaminhado a partir de WB.
  assign lwStall = (ResultSrcE == 2'b01) & ((Rs1D == RdE) | (Rs2D == RdE));

  // Desvios: ao decodificar beq/jal (ID), para a busca e descarta o que
  // foi buscado. Mantém o stall enquanto o desvio estiver em EX, onde é
  // resolvido (PCSrcE). Custo fixo de 2 bolhas, tomado ou não.
  assign ctrlHazD = BranchD | JumpD;
  assign ctrlHazE = BranchE | JumpE;

  assign StallF = lwStall | ctrlHazD | ctrlHazE;
  assign StallD = lwStall;               // lwStall tem prioridade sobre o flush de IF/ID
  assign FlushD = ctrlHazD | ctrlHazE;
  assign FlushE = lwStall;

  // ---------------- IF ----------------
  // PC só avança se não houver stall; se o desvio em EX é tomado
  // (PCSrcE), o PC carrega o alvo. Se não é tomado, o PC fica parado
  // em branch+4, que é a próxima busca correta.
  flopenrc #(32) pcreg(clk, reset, ~StallF | PCSrcE, 1'b0, PCNextF, PCF);
  adder          pcadd4(PCF, 32'd4, PCPlus4F);
  mux2 #(32)     pcmux(PCPlus4F, PCTargetE, PCSrcE, PCNextF);

  // ---------------- IF/ID ----------------
  // bolha = nop (addi x0,x0,0)
  flopenrc #(32, 32'h00000013) ifid_instr(clk, reset, ~StallD, FlushD, InstrF, InstrD);
  flopenrc #(64)               ifid_pc(clk, reset, ~StallD, FlushD,
                                       {PCF, PCPlus4F}, {PCD, PCPlus4D});

  // ---------------- ID ----------------
  assign opD       = InstrD[6:0];
  assign funct3D   = InstrD[14:12];
  assign funct7b5D = InstrD[30];
  assign Rs1D      = InstrD[19:15];
  assign Rs2D      = InstrD[24:20];
  assign RdD       = InstrD[11:7];

  regfile rf(clk, RegWriteW, Rs1D, Rs2D, RdW, ResultW, RD1D, RD2D);
  extend  ext(InstrD[31:7], ImmSrcD, ImmExtD);

  // ---------------- ID/EX ----------------
  flopenrc #(10) idex_ctrl(clk, reset, 1'b1, FlushE,
                           {RegWriteD, ResultSrcD, MemWriteD, JumpD, BranchD, ALUControlD, ALUSrcD},
                           {RegWriteE, ResultSrcE, MemWriteE, JumpE, BranchE, ALUControlE, ALUSrcE});
  flopenrc #(175) idex_data(clk, reset, 1'b1, FlushE,
                            {RD1D, RD2D, PCD, ImmExtD, PCPlus4D, Rs1D, Rs2D, RdD},
                            {RD1E, RD2E, PCE, ImmExtE, PCPlus4E, Rs1E, Rs2E, RdE});

  // ---------------- EX ----------------
  // forwarding: 00 = regfile, 01 = ResultW (WB), 10 = ALUResultM (MEM)
  mux3 #(32) fwdamux(RD1E, ResultW, ALUResultM, ForwardAE, SrcAE);
  mux3 #(32) fwdbmux(RD2E, ResultW, ALUResultM, ForwardBE, WriteDataE); // também é o dado do sw
  mux2 #(32) srcbmux(WriteDataE, ImmExtE, ALUSrcE, SrcBE);
  alu        alu(SrcAE, SrcBE, ALUControlE, ALUResultE, ZeroE);

  // resolução de desvios/jal em EX
  adder      pcaddbranch(PCE, ImmExtE, PCTargetE);
  assign PCSrcE = (BranchE & ZeroE) | JumpE;

  // ---------------- EX/MEM ----------------
  flopenrc #(4) exmem_ctrl(clk, reset, 1'b1, 1'b0,
                           {RegWriteE, ResultSrcE, MemWriteE},
                           {RegWriteM, ResultSrcM, MemWriteM});
  flopenrc #(101) exmem_data(clk, reset, 1'b1, 1'b0,
                             {ALUResultE, WriteDataE, PCPlus4E, RdE},
                             {ALUResultM, WriteDataM, PCPlus4M, RdM});

  // ---------------- MEM/WB ----------------
  flopenrc #(3) memwb_ctrl(clk, reset, 1'b1, 1'b0,
                           {RegWriteM, ResultSrcM},
                           {RegWriteW, ResultSrcW});
  flopenrc #(101) memwb_data(clk, reset, 1'b1, 1'b0,
                             {ALUResultM, ReadDataM, PCPlus4M, RdM},
                             {ALUResultW, ReadDataW, PCPlus4W, RdW});

  // ---------------- WB ----------------
  mux3 #(32) resultmux(ALUResultW, ReadDataW, PCPlus4W, ResultSrcW, ResultW);
endmodule

module regfile(input  logic        clk, 
               input  logic        we3, 
               input  logic [ 4:0] a1, a2, a3, 
               input  logic [31:0] wd3, 
               output logic [31:0] rd1, rd2);

  logic [31:0] rf[31:0];

  // three ported register file
  // read two ports combinationally (A1/RD1, A2/RD2)
  // write third port on rising edge of clock (A3/WD3/WE3)
  // register 0 hardwired to 0

  always_ff @(posedge clk)
    if (we3) rf[a3] <= wd3;	

  // ALTERADO: bypass WB->ID. Como a escrita é em posedge, uma instrução em
  // ID que lê o registrador sendo escrito por WB no mesmo ciclo veria o
  // valor antigo; o bypass entrega wd3 diretamente.
  assign rd1 = (a1 != 0) ? ((we3 & (a1 == a3)) ? wd3 : rf[a1]) : 0;
  assign rd2 = (a2 != 0) ? ((we3 & (a2 == a3)) ? wd3 : rf[a2]) : 0;
endmodule

module adder(input  [31:0] a, b,
             output [31:0] y);

  assign y = a + b;
endmodule

module extend(input  logic [31:7] instr,
              input  logic [1:0]  immsrc,
              output logic [31:0] immext);
 
  always_comb
    case(immsrc) 
      // Type I
      2'b00:   immext = {{20{instr[31]}}, instr[31:20]};
      // Type S 
      2'b01:   immext = {{20{instr[31]}}, instr[31:25], instr[11:7]}; 
      // Type B
      2'b10:   immext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
      // Type J
      2'b11:   immext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0}; 
      default: immext = 32'bx; // undefined
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

module mux2 #(parameter WIDTH = 8)
             (input  logic [WIDTH-1:0] d0, d1, 
              input  logic             s, 
              output logic [WIDTH-1:0] y);

  assign y = s ? d1 : d0; 
endmodule

module mux3 #(parameter WIDTH = 8)
             (input  logic [WIDTH-1:0] d0, d1, d2,
              input  logic [1:0]       s, 
              output logic [WIDTH-1:0] y);

  assign y = s[1] ? d2 : (s[0] ? d1 : d0); 
endmodule

module imem(input  logic [31:0] a,
            output logic [31:0] rd);

  logic [31:0] RAM[63:0];

  initial
      $readmemh("riscvtest.txt",RAM);

  assign rd = RAM[a[31:2]]; // word aligned
endmodule

module dmem(input  logic        clk, we,
            input  logic [31:0] a, wd,
            output logic [31:0] rd);

  logic [31:0] RAM[63:0];

  assign rd = RAM[a[31:2]]; // word aligned

  always_ff @(posedge clk)
    if (we) RAM[a[31:2]] <= wd;
endmodule

module alu(input  logic [31:0] a, b,
           input  logic [2:0]  alucontrol,
           output logic [31:0] result,
           output logic        zero);

  logic [31:0] condinvb, sum;
  logic        v;              // overflow
  logic        isAddSub;       // true when is add or subtract operation

  assign condinvb = alucontrol[0] ? ~b : b;
  assign sum = a + condinvb + alucontrol[0];
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