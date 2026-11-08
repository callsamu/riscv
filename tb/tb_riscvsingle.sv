//==============================================================================
// tb_riscvsingle.sv -- TESTBENCH do processador RISC-V monociclo (Parte 1)
//
// Gera clock e reset, instancia o processador (top) e observa as escritas em
// memória. O programa de teste (embutido na imem, ver riscvtest.s) termina
// escrevendo 25 no endereço 100.
//
// Resultado esperado: "Simulation succeeded"
//==============================================================================
`timescale 1ns/1ps

module testbench();

  logic        clk;
  logic        reset;

  logic [31:0] WriteData, DataAdr;
  logic        MemWrite;

  // instancia o dispositivo sob teste (processador + memórias)
  top dut(clk, reset, WriteData, DataAdr, MemWrite);

  // dump de formas de onda para o GTKWave
  initial begin
    $dumpfile("tb_riscvsingle.vcd");
    $dumpvars(0, testbench);
  end

  // inicialização: reset ativo por 22 unidades de tempo, depois desativa
  initial
    begin
      reset <= 1; # 22; reset <= 0;
    end

  // gera o clock (período de 10 unidades de tempo)
  always
    begin
      clk <= 1; # 5; clk <= 0; # 5;
    end

  // verifica os resultados na borda de descida do clock
  always @(negedge clk)
    begin
      if(MemWrite) begin
        // sucesso: escreveu 25 no endereço 100
        if(DataAdr === 100 & WriteData === 25) begin
          $display("Simulation succeeded");
          $finish;
        // qualquer outra escrita que não seja no endereço 96 é erro
        // (o programa faz uma escrita "intermediária" de 7 em 96, que é válida)
        end else if (DataAdr !== 96) begin
          $display("Simulation failed");
          $finish;
        end
      end
    end
endmodule
