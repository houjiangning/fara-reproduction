#!/bin/sh
# cold_sample.sh -- one true-cold-boot sample (M=31) into the COLD log,
#                   plus on-the-spot selected-bit HD vs the M31 reference.
# usage: sudo sh cold_sample.sh
LOG=/opt/fara/puf/puf_samples_cold.txt
REF=15000150400300004440011450001082
MASK_HEXPFX=   # unused placeholder
sudo /usr/local/bin/puf_sample --m 31 --append $LOG --quiet 2>/dev/null
# print last response line
tail -1 $LOG
