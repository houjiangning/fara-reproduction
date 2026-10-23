`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// aes256_sbox —— AES S-box 查表（FIPS-197 图 7）
//
// 为什么单独做成模块而不是模块内的 function：
//   AES-256 全流水需要 14 轮 × 16 字节 = 224 个 S-box（另加密钥扩展 4 个）。
//   若写成模块内 function，Vivado 的 elaborator 会把 256 项 case **内联 228 次**，
//   表达式树规模爆炸，xelab 直接 EXCEPTION_ACCESS_VIOLATION（已实测复现）。
//   做成独立模块后：一份 ROM 定义，228 个实例，elaborator 只处理一次表体。
//
// 实现：ROM 由 initial 块初始化。Vivado 会推断成分布式 ROM；
//       多个实例可被综合工具共享或按需复制以优化时序。
//=============================================================================
module aes256_sbox (
  input  wire [7:0] x,
  output wire [7:0] y
);

  (* rom_style = "distributed" *)
  reg [7:0] SB [0:255];

  initial begin
    SB[8'h00]=8'h63; SB[8'h01]=8'h7C; SB[8'h02]=8'h77; SB[8'h03]=8'h7B; SB[8'h04]=8'hF2; SB[8'h05]=8'h6B; SB[8'h06]=8'h6F; SB[8'h07]=8'hC5;
    SB[8'h08]=8'h30; SB[8'h09]=8'h01; SB[8'h0A]=8'h67; SB[8'h0B]=8'h2B; SB[8'h0C]=8'hFE; SB[8'h0D]=8'hD7; SB[8'h0E]=8'hAB; SB[8'h0F]=8'h76;
    SB[8'h10]=8'hCA; SB[8'h11]=8'h82; SB[8'h12]=8'hC9; SB[8'h13]=8'h7D; SB[8'h14]=8'hFA; SB[8'h15]=8'h59; SB[8'h16]=8'h47; SB[8'h17]=8'hF0;
    SB[8'h18]=8'hAD; SB[8'h19]=8'hD4; SB[8'h1A]=8'hA2; SB[8'h1B]=8'hAF; SB[8'h1C]=8'h9C; SB[8'h1D]=8'hA4; SB[8'h1E]=8'h72; SB[8'h1F]=8'hC0;
    SB[8'h20]=8'hB7; SB[8'h21]=8'hFD; SB[8'h22]=8'h93; SB[8'h23]=8'h26; SB[8'h24]=8'h36; SB[8'h25]=8'h3F; SB[8'h26]=8'hF7; SB[8'h27]=8'hCC;
    SB[8'h28]=8'h34; SB[8'h29]=8'hA5; SB[8'h2A]=8'hE5; SB[8'h2B]=8'hF1; SB[8'h2C]=8'h71; SB[8'h2D]=8'hD8; SB[8'h2E]=8'h31; SB[8'h2F]=8'h15;
    SB[8'h30]=8'h04; SB[8'h31]=8'hC7; SB[8'h32]=8'h23; SB[8'h33]=8'hC3; SB[8'h34]=8'h18; SB[8'h35]=8'h96; SB[8'h36]=8'h05; SB[8'h37]=8'h9A;
    SB[8'h38]=8'h07; SB[8'h39]=8'h12; SB[8'h3A]=8'h80; SB[8'h3B]=8'hE2; SB[8'h3C]=8'hEB; SB[8'h3D]=8'h27; SB[8'h3E]=8'hB2; SB[8'h3F]=8'h75;
    SB[8'h40]=8'h09; SB[8'h41]=8'h83; SB[8'h42]=8'h2C; SB[8'h43]=8'h1A; SB[8'h44]=8'h1B; SB[8'h45]=8'h6E; SB[8'h46]=8'h5A; SB[8'h47]=8'hA0;
    SB[8'h48]=8'h52; SB[8'h49]=8'h3B; SB[8'h4A]=8'hD6; SB[8'h4B]=8'hB3; SB[8'h4C]=8'h29; SB[8'h4D]=8'hE3; SB[8'h4E]=8'h2F; SB[8'h4F]=8'h84;
    SB[8'h50]=8'h53; SB[8'h51]=8'hD1; SB[8'h52]=8'h00; SB[8'h53]=8'hED; SB[8'h54]=8'h20; SB[8'h55]=8'hFC; SB[8'h56]=8'hB1; SB[8'h57]=8'h5B;
    SB[8'h58]=8'h6A; SB[8'h59]=8'hCB; SB[8'h5A]=8'hBE; SB[8'h5B]=8'h39; SB[8'h5C]=8'h4A; SB[8'h5D]=8'h4C; SB[8'h5E]=8'h58; SB[8'h5F]=8'hCF;
    SB[8'h60]=8'hD0; SB[8'h61]=8'hEF; SB[8'h62]=8'hAA; SB[8'h63]=8'hFB; SB[8'h64]=8'h43; SB[8'h65]=8'h4D; SB[8'h66]=8'h33; SB[8'h67]=8'h85;
    SB[8'h68]=8'h45; SB[8'h69]=8'hF9; SB[8'h6A]=8'h02; SB[8'h6B]=8'h7F; SB[8'h6C]=8'h50; SB[8'h6D]=8'h3C; SB[8'h6E]=8'h9F; SB[8'h6F]=8'hA8;
    SB[8'h70]=8'h51; SB[8'h71]=8'hA3; SB[8'h72]=8'h40; SB[8'h73]=8'h8F; SB[8'h74]=8'h92; SB[8'h75]=8'h9D; SB[8'h76]=8'h38; SB[8'h77]=8'hF5;
    SB[8'h78]=8'hBC; SB[8'h79]=8'hB6; SB[8'h7A]=8'hDA; SB[8'h7B]=8'h21; SB[8'h7C]=8'h10; SB[8'h7D]=8'hFF; SB[8'h7E]=8'hF3; SB[8'h7F]=8'hD2;
    SB[8'h80]=8'hCD; SB[8'h81]=8'h0C; SB[8'h82]=8'h13; SB[8'h83]=8'hEC; SB[8'h84]=8'h5F; SB[8'h85]=8'h97; SB[8'h86]=8'h44; SB[8'h87]=8'h17;
    SB[8'h88]=8'hC4; SB[8'h89]=8'hA7; SB[8'h8A]=8'h7E; SB[8'h8B]=8'h3D; SB[8'h8C]=8'h64; SB[8'h8D]=8'h5D; SB[8'h8E]=8'h19; SB[8'h8F]=8'h73;
    SB[8'h90]=8'h60; SB[8'h91]=8'h81; SB[8'h92]=8'h4F; SB[8'h93]=8'hDC; SB[8'h94]=8'h22; SB[8'h95]=8'h2A; SB[8'h96]=8'h90; SB[8'h97]=8'h88;
    SB[8'h98]=8'h46; SB[8'h99]=8'hEE; SB[8'h9A]=8'hB8; SB[8'h9B]=8'h14; SB[8'h9C]=8'hDE; SB[8'h9D]=8'h5E; SB[8'h9E]=8'h0B; SB[8'h9F]=8'hDB;
    SB[8'hA0]=8'hE0; SB[8'hA1]=8'h32; SB[8'hA2]=8'h3A; SB[8'hA3]=8'h0A; SB[8'hA4]=8'h49; SB[8'hA5]=8'h06; SB[8'hA6]=8'h24; SB[8'hA7]=8'h5C;
    SB[8'hA8]=8'hC2; SB[8'hA9]=8'hD3; SB[8'hAA]=8'hAC; SB[8'hAB]=8'h62; SB[8'hAC]=8'h91; SB[8'hAD]=8'h95; SB[8'hAE]=8'hE4; SB[8'hAF]=8'h79;
    SB[8'hB0]=8'hE7; SB[8'hB1]=8'hC8; SB[8'hB2]=8'h37; SB[8'hB3]=8'h6D; SB[8'hB4]=8'h8D; SB[8'hB5]=8'hD5; SB[8'hB6]=8'h4E; SB[8'hB7]=8'hA9;
    SB[8'hB8]=8'h6C; SB[8'hB9]=8'h56; SB[8'hBA]=8'hF4; SB[8'hBB]=8'hEA; SB[8'hBC]=8'h65; SB[8'hBD]=8'h7A; SB[8'hBE]=8'hAE; SB[8'hBF]=8'h08;
    SB[8'hC0]=8'hBA; SB[8'hC1]=8'h78; SB[8'hC2]=8'h25; SB[8'hC3]=8'h2E; SB[8'hC4]=8'h1C; SB[8'hC5]=8'hA6; SB[8'hC6]=8'hB4; SB[8'hC7]=8'hC6;
    SB[8'hC8]=8'hE8; SB[8'hC9]=8'hDD; SB[8'hCA]=8'h74; SB[8'hCB]=8'h1F; SB[8'hCC]=8'h4B; SB[8'hCD]=8'hBD; SB[8'hCE]=8'h8B; SB[8'hCF]=8'h8A;
    SB[8'hD0]=8'h70; SB[8'hD1]=8'h3E; SB[8'hD2]=8'hB5; SB[8'hD3]=8'h66; SB[8'hD4]=8'h48; SB[8'hD5]=8'h03; SB[8'hD6]=8'hF6; SB[8'hD7]=8'h0E;
    SB[8'hD8]=8'h61; SB[8'hD9]=8'h35; SB[8'hDA]=8'h57; SB[8'hDB]=8'hB9; SB[8'hDC]=8'h86; SB[8'hDD]=8'hC1; SB[8'hDE]=8'h1D; SB[8'hDF]=8'h9E;
    SB[8'hE0]=8'hE1; SB[8'hE1]=8'hF8; SB[8'hE2]=8'h98; SB[8'hE3]=8'h11; SB[8'hE4]=8'h69; SB[8'hE5]=8'hD9; SB[8'hE6]=8'h8E; SB[8'hE7]=8'h94;
    SB[8'hE8]=8'h9B; SB[8'hE9]=8'h1E; SB[8'hEA]=8'h87; SB[8'hEB]=8'hE9; SB[8'hEC]=8'hCE; SB[8'hED]=8'h55; SB[8'hEE]=8'h28; SB[8'hEF]=8'hDF;
    SB[8'hF0]=8'h8C; SB[8'hF1]=8'hA1; SB[8'hF2]=8'h89; SB[8'hF3]=8'h0D; SB[8'hF4]=8'hBF; SB[8'hF5]=8'hE6; SB[8'hF6]=8'h42; SB[8'hF7]=8'h68;
    SB[8'hF8]=8'h41; SB[8'hF9]=8'h99; SB[8'hFA]=8'h2D; SB[8'hFB]=8'h0F; SB[8'hFC]=8'hB0; SB[8'hFD]=8'h54; SB[8'hFE]=8'hBB; SB[8'hFF]=8'h16;
  end

  assign y = SB[x];

endmodule

`default_nettype wire