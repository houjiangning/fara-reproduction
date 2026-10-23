#!/bin/sh
# soft_rst then retest M ladder (read-only, no log write)
sudo busybox devmem 0xA0030000 32 2
sleep 0.1
p=/usr/local/bin/puf_sample
for m in 9 15 31; do
  out=$(sudo $p --m $m --read-only 2>&1 | grep STATUS | head -1)
  echo "M=$m -> $out"
done
