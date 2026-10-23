#!/bin/sh
# 汇总 fara-weights 常驻 + 开机自加载的验证证据
{
  echo "# fara-weights 权重常驻 + 开机自加载 验证证据"
  echo "board date : $(date)"
  echo "uptime     : $(uptime -p)"
  echo
  echo "## 1. 服务状态"
  printf 'is-enabled : '; systemctl is-enabled fara-weights.service
  printf 'is-active  : '; systemctl is-active fara-weights.service
  systemctl status fara-weights.service --no-pager | grep -E 'Active:|Main PID:'
  echo
  echo "## 2. 地址表 /run/fara-resident.json"
  cat /run/fara-resident.json
  echo
  echo "## 3. 权重源文件 /opt/fara/models"
  ls -la /opt/fara/models/
  sha256sum /opt/fara/models/board_*
  echo
  echo "## 4. 独立回读常驻缓冲 /proc/<pid>/mem"
  sh /tmp/verify_resident.sh
} 2>&1
