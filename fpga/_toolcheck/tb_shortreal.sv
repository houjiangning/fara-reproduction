// Tool check: does xsim round shortreal arithmetic to IEEE-754 binary32?
module tb_shortreal;
  int fd;
  int n, bad;
  logic [7:0]  op;
  logic [31:0] a, b, r;
  logic [31:0] got;
  shortreal ra, rb, rr;

  initial begin
    fd = $fopen("vec.txt", "r");
    if (fd == 0) begin $display("FAIL: cannot open vec.txt"); $finish; end
    n = 0; bad = 0;
    while (!$feof(fd)) begin
      if ($fscanf(fd, "%c %h %h %h\n", op, a, b, r) != 4) break;
      ra = $bitstoshortreal(a);
      rb = $bitstoshortreal(b);
      if (op == "M") rr = ra * rb; else rr = ra + rb;
      got = $shortrealtobits(rr);
      if (got !== r) begin
        bad = bad + 1;
        if (bad <= 10)
          $display("MISMATCH op=%c a=%08h b=%08h got=%08h exp=%08h", op, a, b, got, r);
      end
      n = n + 1;
    end
    $fclose(fd);
    $display("checked %0d ops, %0d mismatches -> %s", n, bad, (bad == 0) ? "SHORTREAL IS IEEE-EXACT" : "NOT EXACT");
    $finish;
  end
endmodule
