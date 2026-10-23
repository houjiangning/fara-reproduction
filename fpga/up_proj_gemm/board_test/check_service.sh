#!/bin/sh
echo '=== current instance ==='
systemctl status fara-weights.service --no-pager | grep -E 'Active:|Main PID:|CGroup'
echo
echo '=== current instance output lines ==='
systemctl status fara-weights.service --no-pager | grep -E '警告|源目录|缓冲|sha256|常驻'
echo
echo '=== dmesg check with fixed pattern ==='
dmesg | grep -iE 'EXT4-fs error|EXT4-fs.*aborted|aborted journal|I/O error' | tail -5
echo '--- end of dmesg match list ---'
